#!/usr/bin/env python3
"""Restore cancellation fences staged and in-flight commits without data loss."""
import base64,hashlib,json,os,time,urllib.error,urllib.request,uuid
from concurrent.futures import ThreadPoolExecutor
BASE=os.environ.get('VOCAB_TEST_BASE','http://127.0.0.1:18765').rstrip('/')
def call(path,method='GET',body=None,token=None):
    headers={'Content-Type':'application/json'}
    if token:headers['Authorization']='Bearer '+token
    req=urllib.request.Request(BASE+path,None if body is None else json.dumps(body,separators=(',',':')).encode(),headers,method=method)
    with urllib.request.urlopen(req,timeout=90) as response:return json.load(response)
def reject(code,path,method='GET',body=None,token=None):
    try:call(path,method,body,token)
    except urllib.error.HTTPError as error:assert error.code==code,(path,error.code,code,error.read())
    else:raise AssertionError(f'{path} unexpectedly succeeded')
def seed():
    entry=call('/api/v1/__ui_fixture/recovery-case','POST',{});token=entry['token'];call('/api/v1/__ui_fixture/oversize-stored-state','POST',{'token':token,'size':8*1024*1024+65536})
    head=call('/api/v1/me/state/snapshots?representation=stored','POST',{},token)
    payload=json.dumps({'v':1,'cards':{'restored':{'pos':5}},'log':[],'pendingNew':[],'settings':{}},separators=(',',':')).encode()
    manifest={'batch_id':uuid.uuid4().hex,'generation':head['generation'],'base_revision':head['state_revision'],'restore_epoch':head['restore_epoch'],'byte_length':len(payload),'part_count':1,'sha256':hashlib.sha256(payload).hexdigest()}
    call('/api/v1/me/state/delta-stages','POST',manifest,token);call(f"/api/v1/me/state/delta-stages/{manifest['batch_id']}/parts/0",'PUT',{'data':base64.b64encode(payload).decode()},token)
    body={k:manifest[k] for k in ('batch_id','generation','base_revision','restore_epoch')};body['payload_sha256']=manifest['sha256']
    return token,head,manifest,payload,body
cancel='/api/v1/me/state/experimental-large-restore-cancel'
def commit(batch):return f'/api/v1/me/state/delta-stages/{batch}/experimental-large-restore'
call('/api/v1/__ui_fixture/experimental-large-deltas','POST',{'enabled':True});token,head,manifest,payload,body=seed()
reject(409,cancel,'POST',{**body,'payload_sha256':'0'*64},token)
call('/api/v1/__ui_fixture/state-changes-failure','POST',{'enabled':True});reject(500,cancel,'POST',body,token);call('/api/v1/__ui_fixture/state-changes-failure','POST',{'enabled':False})
# The failed transaction retained the original stage and state.
call(f"/api/v1/me/state/delta-stages/{body['batch_id']}/parts/0",'PUT',{'data':base64.b64encode(payload).decode()},token)
assert call('/api/v1/me/state/snapshots?representation=stored','POST',{},token)['state_revision']==head['state_revision']
result=call(cancel,'POST',body,token);assert result['cancelled'] and result['payload_sha256']==body['payload_sha256'] and result['head_revision']==str(int(body['base_revision'])+1)
assert call(cancel,'POST',body,token)==result
reject(404,commit(body['batch_id']),'POST',{},token);reject(409,'/api/v1/me/state/delta-stages','POST',manifest,token)
assert call('/api/v1/me/state/backups',token=token)['backups']==[]
# A previously assembled commit is invalidated by deleting the exact stage.
token2,head2,manifest2,payload2,body2=seed();call('/api/v1/__ui_fixture/delta-stage-hold','POST',{'batch_id':body2['batch_id']})
with ThreadPoolExecutor(max_workers=1) as pool:
    pending=pool.submit(call,commit(body2['batch_id']),'POST',{},token2)
    for _ in range(200):
        if call('/api/v1/__ui_fixture/delta-stage-hold')['started']:break
        time.sleep(.05)
    else:raise AssertionError('restore did not reach stage gate')
    cancelled=call(cancel,'POST',body2,token2);call('/api/v1/__ui_fixture/delta-stage-release','POST',{})
    try:pending.result(timeout=30)
    except urllib.error.HTTPError as error:assert error.code==404
    else:raise AssertionError('assembled restore committed after cancellation')
assert cancelled['head_revision']==str(int(body2['base_revision'])+1)
# A committed restore cannot be cancelled, even if the original response is lost.
token3,head3,manifest3,payload3,body3=seed();committed=call(commit(body3['batch_id']),'POST',{},token3)
reject(409,cancel,'POST',body3,token3)
assert call('/api/v1/me/state/snapshots?representation=stored','POST',{},token3)['state_revision']==committed['state_revision']
print('PASS restore cancellation removes exact staging, fences delayed commits and preserves data')
