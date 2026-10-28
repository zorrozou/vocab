#!/usr/bin/env python3
"""Cancellation fences delayed checkpoint requests without changing user data."""
import base64,json,os,urllib.error,urllib.request,uuid
from concurrent.futures import ThreadPoolExecutor
BASE=os.environ.get('VOCAB_TEST_BASE','http://127.0.0.1:18765').rstrip('/')
def call(path,method='GET',body=None,token=None):
    headers={'Content-Type':'application/json'}
    if token:headers['Authorization']='Bearer '+token
    req=urllib.request.Request(BASE+path,None if body is None else json.dumps(body,separators=(',',':')).encode(),headers,method=method)
    with urllib.request.urlopen(req,timeout=90) as response:return json.load(response)
def reject(code,path,method='GET',body=None,token=None):
    try:call(path,method,body,token)
    except urllib.error.HTTPError as error:assert error.code==code,(error.code,code,error.read())
    else:raise AssertionError(f'{path} unexpectedly succeeded')
def seed():
    entry=call('/api/v1/__ui_fixture/recovery-case','POST',{});token=entry['token']
    call('/api/v1/__ui_fixture/oversize-stored-state','POST',{'token':token,'size':8*1024*1024+65536})
    head=call('/api/v1/me/state/snapshots?representation=stored','POST',{},token)
    return token,head,{'batch_id':uuid.uuid4().hex,'generation':head['generation'],'base_revision':head['state_revision'],'restore_epoch':head['restore_epoch']}
checkpoint='/api/v1/me/state/experimental-large-checkpoint';cancel='/api/v1/me/state/experimental-large-checkpoint-cancel'
call('/api/v1/__ui_fixture/experimental-large-deltas','POST',{'enabled':True})
token,head,body=seed()
call('/api/v1/__ui_fixture/state-changes-failure','POST',{'enabled':True});reject(500,cancel,'POST',body,token);call('/api/v1/__ui_fixture/state-changes-failure','POST',{'enabled':False})
after_fail=call('/api/v1/me/state/snapshots?representation=stored','POST',{},token);assert after_fail['state_revision']==head['state_revision'] and after_fail['sha256']==head['sha256']
r=call(cancel,'POST',body,token);assert r['cancelled'] and r['head_revision']==str(int(body['base_revision'])+1)
assert call(cancel,'POST',body,token)==r;reject(409,checkpoint,'POST',body,token)
after=call('/api/v1/me/state/snapshots?representation=stored','POST',{},token);assert after['state_revision']==r['head_revision'] and after['restore_epoch']==body['restore_epoch']
change=call(f"/api/v1/me/state/changes?after={body['base_revision']}&generation={body['generation']}",token=token);assert change['head_revision']==r['head_revision'] and json.loads(base64.b64decode(change['change']['data']))['ops']==[]
assert call('/api/v1/me/state/backups',token=token)['backups']==[]
# If another device advanced the revision, cancellation does not overwrite it.
token2,head2,body2=seed();update={'batch_id':uuid.uuid4().hex,'generation':body2['generation'],'base_revision':body2['base_revision'],'restore_epoch':body2['restore_epoch'],'ops':[{'op':'set','path':['cards','other_device'],'value':{'pos':7}}]}
advanced=call('/api/v1/me/state/experimental-large-deltas','POST',update,token2)
r2=call(cancel,'POST',body2,token2);assert r2['head_revision']==advanced['state_revision'];reject(409,checkpoint,'POST',body2,token2)
# The database transaction decides which concurrent operation wins.
token3,head3,body3=seed()
def try_request(path):
    try:return (200,call(path,'POST',body3,token3))
    except urllib.error.HTTPError as error:return (error.code,None)
with ThreadPoolExecutor(max_workers=2) as pool:a,b=list(pool.map(try_request,[checkpoint,cancel]))
assert sorted([a[0],b[0]])==[200,409],(a,b)
latest=call('/api/v1/me/state/snapshots?representation=stored','POST',{},token3)
if a[0]==200:
    assert latest['restore_epoch']==body3['restore_epoch']+1;reject(409,cancel,'POST',body3,token3)
else:
    assert latest['restore_epoch']==body3['restore_epoch'];reject(409,checkpoint,'POST',body3,token3)
print('PASS checkpoint cancellation serializes with commit, fences delayed requests and preserves data')
