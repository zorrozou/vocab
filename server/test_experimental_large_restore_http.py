#!/usr/bin/env python3
"""Staged restore, fencing and receipt recovery against a disposable fixture."""
import base64, hashlib, json, os, time, urllib.error, urllib.request, uuid
from concurrent.futures import ThreadPoolExecutor
BASE=os.environ.get('VOCAB_TEST_BASE','http://127.0.0.1:18765').rstrip('/')
def call(path,method='GET',body=None,token=None):
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    req=urllib.request.Request(BASE+path,None if body is None else json.dumps(body,separators=(',',':')).encode(),headers,method=method)
    with urllib.request.urlopen(req,timeout=90) as result:return json.load(result)
def reject(code,path,method='GET',body=None,token=None):
    try: call(path,method,body,token)
    except urllib.error.HTTPError as error: assert error.code==code,(path,error.code,code,error.read())
    else: raise AssertionError(f'{path} unexpectedly succeeded')
def snapshot(token):
    manifest=call('/api/v1/me/state/snapshots?representation=stored','POST',{},token)
    chunks=[base64.b64decode(call(f"/api/v1/me/state/snapshots/{manifest['snapshot_id']}?page={i}",token=token)['data'],validate=True) for i in range(manifest['page_count'])]
    raw=b''.join(chunks);assert len(raw)==manifest['byte_length'] and hashlib.sha256(raw).hexdigest()==manifest['sha256']
    state=json.loads(raw)['state'];return manifest,state
def stage(token,manifest,state,first_only=False):
    payload=json.dumps(state,ensure_ascii=False,separators=(',',':')).encode();assert 8*1024*1024<len(payload)<14*1024*1024
    batch=uuid.uuid4().hex;size=256*1024;count=(len(payload)+size-1)//size
    body={'batch_id':batch,'generation':manifest['generation'],'base_revision':manifest['state_revision'],'restore_epoch':manifest['restore_epoch'],'byte_length':len(payload),'part_count':count,'sha256':hashlib.sha256(payload).hexdigest()}
    call('/api/v1/me/state/delta-stages','POST',body,token)
    def part(i):call(f'/api/v1/me/state/delta-stages/{batch}/parts/{i}','PUT',{'data':base64.b64encode(payload[i*size:(i+1)*size]).decode()},token)
    part(0)
    if not first_only:
        for i in range(1,count):part(i)
    return batch,count,part,body

def restore(batch):return f'/api/v1/me/state/delta-stages/{batch}/experimental-large-restore'
def receipt(batch):return f'/api/v1/me/state/experimental-large-restore-receipts/{batch}'
seed=call('/api/v1/__ui_fixture/recovery-case','POST',{});other=call('/api/v1/__ui_fixture/recovery-case','POST',{})['token'];token=seed['token']
call('/api/v1/__ui_fixture/oversize-stored-state','POST',{'token':token,'size':8*1024*1024+65536})
assert call('/api/v1/me/state/delta-capabilities',token=token)['experimental_large_restore_v1'] is False
reject(404,restore(uuid.uuid4().hex),'POST',{},token)
call('/api/v1/__ui_fixture/experimental-large-deltas','POST',{'enabled':True})
assert call('/api/v1/me/state/delta-capabilities',token=token)['experimental_large_restore_v1'] is True
other_head=call('/api/v1/me/state',token=other);bad_payload=b'{"v":1,"v":2,"cards":{},"log":[],"pendingNew":[],"settings":{}}';bad_id=uuid.uuid4().hex
bad_manifest={'batch_id':bad_id,'generation':other_head['sync_generation'],'base_revision':other_head['state_revision'],'restore_epoch':0,'byte_length':len(bad_payload),'part_count':1,'sha256':hashlib.sha256(bad_payload).hexdigest()}
call('/api/v1/me/state/delta-stages','POST',bad_manifest,other);call(f'/api/v1/me/state/delta-stages/{bad_id}/parts/0','PUT',{'data':base64.b64encode(bad_payload).decode()},other)
reject(422,restore(bad_id),'POST',{},other);assert call('/api/v1/me/state',token=other)['state']==other_head['state']
# Replacing the stage after assembly must invalidate the old commit's nonce.
race_payload=json.dumps(other_head['state'],separators=(',',':')).encode();race_id=uuid.uuid4().hex
race_manifest={'batch_id':race_id,'generation':other_head['sync_generation'],'base_revision':other_head['state_revision'],'restore_epoch':0,'byte_length':len(race_payload),'part_count':1,'sha256':hashlib.sha256(race_payload).hexdigest()}
call('/api/v1/me/state/delta-stages','POST',race_manifest,other);call(f'/api/v1/me/state/delta-stages/{race_id}/parts/0','PUT',{'data':base64.b64encode(race_payload).decode()},other)
call('/api/v1/__ui_fixture/delta-stage-hold','POST',{'batch_id':race_id})
with ThreadPoolExecutor(max_workers=1) as pool:
    pending=pool.submit(call,restore(race_id),'POST',{},other)
    for _ in range(200):
        if call('/api/v1/__ui_fixture/delta-stage-hold')['started']:break
        time.sleep(.05)
    else:raise AssertionError('restore did not reach stage gate')
    call(f'/api/v1/me/state/delta-stages/{race_id}','DELETE',token=other)
    call('/api/v1/me/state/delta-stages','POST',race_manifest,other)
    call('/api/v1/__ui_fixture/delta-stage-release','POST',{})
    try:pending.result(timeout=30)
    except urllib.error.HTTPError as error:assert error.code==404
    else:raise AssertionError('replaced stage committed')
assert call('/api/v1/me/state',token=other)['state']==other_head['state']
manifest,original=snapshot(token);backup=json.loads(json.dumps(original));backup['cards']['restored']={'pos':42};backup['settings']['newPerDay']=15
stale,_,_,_=stage(token,manifest,backup)
change={'generation':manifest['generation'],'base_revision':manifest['state_revision'],'restore_epoch':manifest['restore_epoch'],'batch_id':uuid.uuid4().hex,'ops':[{'op':'set','path':['cards','server_new'],'value':{'pos':7}}]}
advanced=call('/api/v1/me/state/experimental-large-deltas','POST',change,token)
reject(409,restore(stale),'POST',{},token);assert call('/api/v1/me/state/backups',token=token)['backups']==[]
current,server=snapshot(token);assert current['state_revision']==advanced['state_revision'] and server['cards']['server_new']
batch,count,part,staged_manifest=stage(token,current,backup,True)
reject(404,restore(batch),'POST',{},other);reject(409,restore(batch),'POST',{},token)
for i in range(1,count):part(i)
call('/api/v1/__ui_fixture/state-changes-failure','POST',{'enabled':True});reject(500,restore(batch),'POST',{},token);call('/api/v1/__ui_fixture/state-changes-failure','POST',{'enabled':False})
assert call('/api/v1/me/state/backups',token=token)['backups']==[];reject(404,receipt(batch),token=token)
with ThreadPoolExecutor(max_workers=2) as pool:
    futures=[pool.submit(call,restore(batch),'POST',{},token) for _ in range(2)]
    restored,concurrent=[f.result(timeout=90) for f in futures]
assert restored==concurrent and restored['state_revision']==str(int(current['state_revision'])+1) and restored['restore_epoch']==current['restore_epoch']+1 and restored['payload_sha256']==staged_manifest['sha256']
assert call(restore(batch),'POST',{},token)==restored;assert call(receipt(batch),token=token)==restored;reject(404,receipt(batch),token=other)
listed=call('/api/v1/me/state/backups',token=token)['backups'];assert len(listed)==1
before=call('/api/v1/me/state/backups/'+str(listed[0]['id']),token=token)['state'];assert before['cards']['server_new'] and 'restored' not in before['cards']
latest,state=snapshot(token);assert latest['state_revision']==restored['state_revision'] and state['cards']['restored'] and 'server_new' not in state['cards'] and state['settings']['newPerDay']==15
reject(409,'/api/v1/me/state/experimental-large-deltas','POST',change,token)
later={'generation':restored['generation'],'base_revision':restored['state_revision'],'restore_epoch':restored['restore_epoch'],'batch_id':uuid.uuid4().hex,'ops':[{'op':'set','path':['cards','after_restore'],'value':{'pos':6}}]}
later_receipt=call('/api/v1/me/state/experimental-large-deltas','POST',later,token)
assert call(receipt(batch),token=token)==restored and call(restore(batch),'POST',{},token)==restored
head=call(f"/api/v1/me/state/changes?after={restored['state_revision']}&generation={restored['generation']}&compact=true",token=token)
assert head['head_revision']==later_receipt['state_revision'] and head['head_revision']!=restored['state_revision']
reused={'generation':restored['generation'],'base_revision':restored['state_revision'],'restore_epoch':restored['restore_epoch'],'batch_id':batch,'ops':[{'op':'set','path':['cards','late'],'value':{'pos':3}}]}
reject(409,'/api/v1/me/state/experimental-large-deltas','POST',reused,token)
assert call('/api/v1/__ui_fixture/restore-receipt-expire','POST',{'token':token,'batch_id':batch})['changed']==1
reject(404,receipt(batch),token=token);reject(409,restore(batch),'POST',{},token)
assert len(call('/api/v1/me/state/backups',token=token)['backups'])==1
assert call('/api/v1/__ui_fixture/restore-receipt-expire','POST',{'token':token,'batch_id':batch,'restore':True})['changed']==1
call(f'/api/v1/me/state/delta-stages/{batch}','DELETE',token=token);assert call(receipt(batch),token=token)==restored
call('/api/v1/__ui_fixture/reset-sync-generation','POST',{});reject(404,receipt(batch),token=token)
call('/api/v1/__ui_fixture/experimental-large-deltas','POST',{'enabled':False});reject(404,receipt(batch),token=token)
print('PASS staged large restore: atomic backup, stale fencing, receipt replay, account isolation and rollback')
