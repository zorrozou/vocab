#!/usr/bin/env python3
"""Database generation fences stale cursors even when revisions are equal."""
import json, os, urllib.error, urllib.request, uuid
BASE=os.environ.get('VOCAB_TEST_BASE','http://127.0.0.1:18765').rstrip('/')
def call(path,method='GET',body=None,token=None):
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    req=urllib.request.Request(BASE+path,None if body is None else json.dumps(body).encode(),headers,method=method)
    with urllib.request.urlopen(req,timeout=45) as response: return json.load(response)
def reject(code,path,token=None):
    try: call(path,token=token)
    except urllib.error.HTTPError as error: assert error.code==code, (error.code,code)
    else: raise AssertionError('request unexpectedly succeeded')
auth=call('/api/v1/auth/register','POST',{'username':'gen_'+uuid.uuid4().hex[:10],'password':'test_password_123'})
token=auth['token']; state={'v':1,'cards':{'apple':{'pos':1}},'log':[],'pendingNew':[],'settings':{}}
call('/api/v1/me/state','PUT',state,token)
snapshot=call('/api/v1/me/state/snapshots?representation=stored','POST',{},token)
old=snapshot['generation']; revision=snapshot['state_revision']
assert len(old)==32
assert call(f'/api/v1/me/state/changes?after={revision}&generation={old}',token=token)['change'] is None
rotated=call('/api/v1/__ui_fixture/reset-sync-generation','POST',{})['generation']
assert rotated!=old
reject(409,f'/api/v1/me/state/changes?after={revision}&generation={old}',token)
reject(404,'/api/v1/me/state/snapshots/'+snapshot['snapshot_id']+'?page=0',token)
new=call('/api/v1/me/state/snapshots?representation=stored','POST',{},token)
assert new['generation']==rotated and new['state_revision']==revision
assert call('/api/v1/me/state',token=token)['state']['cards']['apple']['pos']==1
assert call(f'/api/v1/me/state/changes?after={revision}&generation={rotated}',token=token)['change'] is None
reject(410,f'/api/v1/me/state/changes?after=0&generation={rotated}',token)
print('PASS generation rotation fences equal revisions, old snapshots and retained state')
