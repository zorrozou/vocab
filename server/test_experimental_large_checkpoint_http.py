#!/usr/bin/env python3
"""Transactional oversized checkpoint, retries, fencing, rollback and isolation."""
import base64, hashlib, json, os, urllib.error, urllib.request, uuid
from concurrent.futures import ThreadPoolExecutor
BASE=os.environ.get('VOCAB_TEST_BASE','http://127.0.0.1:18765').rstrip('/')
def call(path,method='GET',body=None,token=None):
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    req=urllib.request.Request(BASE+path,None if body is None else json.dumps(body,separators=(',',':')).encode(),headers,method=method)
    with urllib.request.urlopen(req,timeout=90) as result:return json.load(result)
def reject(code,path,method='GET',body=None,token=None):
    try:call(path,method,body,token)
    except urllib.error.HTTPError as error:assert error.code==code,(path,error.code,code,error.read())
    else:raise AssertionError(f'{path} unexpectedly succeeded')
def snapshot(token):
    manifest=call('/api/v1/me/state/snapshots?representation=stored','POST',{},token)
    chunks=[base64.b64decode(call(f"/api/v1/me/state/snapshots/{manifest['snapshot_id']}?page={i}",token=token)['data'],validate=True) for i in range(manifest['page_count'])]
    raw=b''.join(chunks);assert len(raw)==manifest['byte_length'] and hashlib.sha256(raw).hexdigest()==manifest['sha256']
    return manifest,json.loads(raw)['state']
seed=call('/api/v1/__ui_fixture/recovery-case','POST',{});other=call('/api/v1/__ui_fixture/recovery-case','POST',{})['token'];token=seed['token']
call('/api/v1/__ui_fixture/oversize-stored-state','POST',{'token':token,'size':8*1024*1024+65536})
path='/api/v1/me/state/experimental-large-checkpoint';batch=uuid.uuid4().hex
assert call('/api/v1/me/state/delta-capabilities',token=token)['experimental_large_checkpoint_v1'] is False
reject(404,path,'POST',{},token)
call('/api/v1/__ui_fixture/experimental-large-deltas','POST',{'enabled':True})
assert call('/api/v1/me/state/delta-capabilities',token=token)['experimental_large_checkpoint_v1'] is True
manifest,old=snapshot(token);assert manifest['byte_length']>8*1024*1024
body={'batch_id':batch,'generation':manifest['generation'],'base_revision':manifest['state_revision'],'restore_epoch':manifest['restore_epoch']}
preview='/api/v1/me/state/experimental-large-checkpoint-preview'
assert call(preview,'POST',{k:body[k] for k in ('generation','base_revision','restore_epoch')},token)['ok'] is True
other_before=call('/api/v1/me/state',token=other);pending=other_before['state'];pending['cards']['pending']={'pendingFsrs':{'base':{'is_new':True,'state':1,'stability':0,'difficulty':0,'rating':3},'events':[{'id':'event-p','rating':3,'at':'2026-10-27T12:00:00Z'}]}}
call('/api/v1/me/state','PUT',pending,other);other_head=call('/api/v1/me/state',token=other)
reject(409,preview,'POST',{'generation':other_head['sync_generation'],'base_revision':other_head['state_revision'],'restore_epoch':other_head['state'].get('restoreEpoch',0)},other)
assert call('/api/v1/me/state/backups',token=other)['backups']==[]
receipt_path=f'/api/v1/me/state/experimental-large-checkpoint-receipts/{batch}'
reject(404,receipt_path,token=token);reject(404,receipt_path,token=other)
reject(422,path,'POST',{**body,'restore_epoch':True},token)
reject(409,path,'POST',{**body,'base_revision':str(int(body['base_revision'])+1)},token)
call('/api/v1/__ui_fixture/state-changes-failure','POST',{'enabled':True});reject(500,path,'POST',body,token);call('/api/v1/__ui_fixture/state-changes-failure','POST',{'enabled':False})
assert call('/api/v1/me/state/backups',token=token)['backups']==[];reject(404,receipt_path,token=token)
with ThreadPoolExecutor(max_workers=2) as pool:
    responses=list(pool.map(lambda _:call(path,'POST',body,token),range(2)))
r=responses[0];assert responses[1]==r and r['state_revision']==str(int(body['base_revision'])+1) and r['restore_epoch']==body['restore_epoch']+1
assert call(path,'POST',body,token)==r and call(receipt_path,token=token)==r
reject(409,path,'POST',{**body,'base_revision':r['state_revision']},token);reject(404,receipt_path,token=other)
backups=call('/api/v1/me/state/backups',token=token)['backups'];assert len(backups)==1 and backups[0]['reason']=='before_checkpoint'
latest,new=snapshot(token);assert latest['state_revision']==r['state_revision'] and new['restoreEpoch']==r['restore_epoch']
assert new['cards']==old['cards'] and new['settings']==old['settings'] and new['fixtureLarge']==old['fixtureLarge']
old_write={'batch_id':uuid.uuid4().hex,'generation':body['generation'],'base_revision':body['base_revision'],'restore_epoch':body['restore_epoch'],'ops':[{'op':'set','path':['cards','fenced'],'value':{'pos':1}}]}
reject(409,'/api/v1/me/state/experimental-large-deltas','POST',old_write,token)
# A checkpoint batch cannot subsequently be reused for an incremental commit.
collision={**old_write,'batch_id':batch,'base_revision':r['state_revision'],'restore_epoch':r['restore_epoch']}
reject(409,'/api/v1/me/state/experimental-large-deltas','POST',collision,token)
print('PASS experimental large checkpoint is atomic, version fenced, idempotent and account isolated')
