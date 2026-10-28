#!/usr/bin/env python3
"""Experimental bounded large-state commits; all requests target an isolated fixture."""
import base64, hashlib, json, os, urllib.error, urllib.request, uuid
BASE=os.environ.get('VOCAB_TEST_BASE','http://127.0.0.1:18765').rstrip('/')
def call(path,method='GET',body=None,token=None):
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    req=urllib.request.Request(BASE,None if body is None else json.dumps(body,separators=(',',':')).encode(),headers,method=method)
    req.full_url=BASE+path
    with urllib.request.urlopen(req,timeout=90) as r:return json.load(r)
def reject(status,path,method='GET',body=None,token=None):
    try: call(path,method,body,token)
    except urllib.error.HTTPError as e: assert e.code==status,(path,e.code,status,e.read())
    else: raise AssertionError(f'{path} unexpectedly succeeded')
def batch(gen,rev,ops,epoch=0):return {'generation':gen,'base_revision':str(rev),'restore_epoch':epoch,'batch_id':uuid.uuid4().hex,'ops':ops}
user=call('/api/v1/auth/register','POST',{'username':'large_'+uuid.uuid4().hex[:8],'password':'test_password_123'})
token=user['token'];head=call('/api/v1/me/state',token=token);gen=head['sync_generation']
endpoint='/api/v1/me/state/experimental-large-deltas'
small={'v':1,'cards':{'apple':{'pos':1,'extra':'a'*(7*1024*1024)}},'log':[],'pendingNew':[],'settings':{}}
probe=batch(gen,0,[{'op':'set','path':[],'value':small}])
reject(404,endpoint,'POST',probe,token)
assert call('/api/v1/me/state/delta-capabilities',token=token)['experimental_large_delta_v1'] is False
call('/api/v1/__ui_fixture/experimental-large-deltas','POST',{'enabled':True})
assert call('/api/v1/me/state/delta-capabilities',token=token)['experimental_large_delta_v1'] is True
reject(401,endpoint,'POST',probe)
reject(422,endpoint,'POST',probe,token)
missing=batch(gen,0,[{'op':'set','path':['cards','pear'],'value':{'pos':2}}])
reject(409,endpoint,'POST',missing,token)
first=call('/api/v1/me/state','PUT',small,token)
state=call('/api/v1/me/state',token=token);rev=int(state['state_revision']); assert rev>=int(first['state_revision'])
receipt=None
for i in range(7):
    op={'op':'set','path':['cards',f'extra{i}'],'value':{'pos':i+2,'extra':chr(98+i)*(900*1024)}}
    update=batch(gen,rev,[op]);receipt=call(endpoint,'POST',update,token)
    assert receipt['state_revision']==str(rev+1) and call(endpoint,'POST',update,token)==receipt
    reject(409,'/api/v1/me/state/deltas','POST',update,token)
    rev+=1
assert receipt and rev>=8
reject(413,'/api/v1/me/state',token=token)
reject(413,'/api/v1/me/state','PUT',{'v':1,'cards':{},'log':[],'pendingNew':[],'settings':{}},token)
reject(413,'/api/v1/me/state/deltas','POST',batch(gen,rev,[{'op':'remove','path':['cards','extra0']}]),token)
reject(413,'/api/v1/me/state/checkpoint','POST',{'expected_updated_at':receipt['updated_at']},token)
reject(413,'/api/v1/me/state/restore','POST',{'state':{'v':1,'cards':{},'log':[],'pendingNew':[],'settings':{}},'expected_updated_at':receipt['updated_at']},token)
reject(409,endpoint,'POST',batch(gen,rev-1,[{'op':'set','path':['cards','late'],'value':{'pos':55}}]),token)
reject(409,endpoint,'POST',batch(gen,rev,[{'op':'set','path':['cards','late'],'value':{'pos':55}}],epoch=1),token)
too_big=batch(gen,rev,[{'op':'set','path':['cards','overflow'],'value':{'pos':99,'extra':'z'*(1900*1024)}}])
reject(413,endpoint,'POST',too_big,token)
retry=batch(gen,rev,[{'op':'set','path':['cards','rollback'],'value':{'pos':99}}])
call('/api/v1/__ui_fixture/state-changes-failure','POST',{'enabled':True})
reject(500,endpoint,'POST',retry,token)
call('/api/v1/__ui_fixture/state-changes-failure','POST',{'enabled':False})
receipt=call(endpoint,'POST',retry,token); rev+=1
assert receipt['state_revision']==str(rev) and call(endpoint,'POST',retry,token)==receipt
manifest=call('/api/v1/me/state/snapshots?representation=stored','POST',{},token)
assert manifest['state_revision']==str(rev) and 8*1024*1024 < manifest['byte_length'] < 16*1024*1024
parts=[]
for i in range(manifest['page_count']):
    page=call(f"/api/v1/me/state/snapshots/{manifest['snapshot_id']}?page={i}",token=token)
    assert page['snapshot_id']==manifest['snapshot_id'] and page['page']==i
    parts.append(base64.b64decode(page['data'],validate=True))
payload=b''.join(parts);assert len(payload)==manifest['byte_length'] and hashlib.sha256(payload).hexdigest()==manifest['sha256']
view=json.loads(payload)['state'];assert len(view['cards'])==9 and view['cards']['rollback']['pos']==99 and len(view['cards']['apple']['extra'])==7*1024*1024
for i in range(7): assert len(view['cards'][f'extra{i}']['extra'])==900*1024
staged_user=call('/api/v1/auth/register','POST',{'username':'staged_'+uuid.uuid4().hex[:8],'password':'test_password_123'})['token']
staged_first=call('/api/v1/me/state','PUT',small,staged_user)
ops=[{'op':'set','path':['cards','big'],'value':{'pos':200,'extra':'s'*(2100*1024)}}]
raw=json.dumps(ops,separators=(',',':')).encode(); batch_id=uuid.uuid4().hex; part_size=256*1024
stage={'batch_id':batch_id,'generation':gen,'base_revision':staged_first['state_revision'],'restore_epoch':0,
       'byte_length':len(raw),'part_count':(len(raw)+part_size-1)//part_size,'sha256':hashlib.sha256(raw).hexdigest()}
call('/api/v1/me/state/delta-stages','POST',stage,staged_user)
for i in range(stage['part_count']):
    call(f'/api/v1/me/state/delta-stages/{batch_id}/parts/{i}','PUT',{'data':base64.b64encode(raw[i*part_size:(i+1)*part_size]).decode()},staged_user)
legacy_commit=f'/api/v1/me/state/delta-stages/{batch_id}/commit'
large_commit=f'/api/v1/me/state/delta-stages/{batch_id}/experimental-large-commit'
reject(413,legacy_commit,'POST',{},staged_user)
staged_result=call(large_commit,'POST',{},staged_user)
assert staged_result['state_revision']==str(int(staged_first['state_revision'])+1) and call(large_commit,'POST',{},staged_user)==staged_result
reject(409,legacy_commit,'POST',{},staged_user)
reject(413,'/api/v1/me/state',token=staged_user)
staged_snapshot=call('/api/v1/me/state/snapshots?representation=stored','POST',{},staged_user)
assert staged_snapshot['state_revision']==staged_result['state_revision'] and staged_snapshot['byte_length']>8*1024*1024
staged_pages=[]
for i in range(staged_snapshot['page_count']):
    page=call(f"/api/v1/me/state/snapshots/{staged_snapshot['snapshot_id']}?page={i}",token=staged_user)
    assert page['snapshot_id']==staged_snapshot['snapshot_id'] and page['page']==i
    staged_pages.append(base64.b64decode(page['data'],validate=True))
staged_payload=b''.join(staged_pages)
assert len(staged_payload)==staged_snapshot['byte_length'] and hashlib.sha256(staged_payload).hexdigest()==staged_snapshot['sha256']
assert json.loads(staged_payload)['state']['cards']['big']['extra']=='s'*(2100*1024)
call('/api/v1/__ui_fixture/experimental-large-deltas','POST',{'enabled':False})
reject(404,endpoint,'POST',batch(gen,rev,[{'op':'set','path':['cards','last'],'value':{'pos':101}}]),token)
reject(404,large_commit,'POST',{},staged_user)
print('PASS experimental bounded large delta: explicit opt-in, transactional growth, idempotency, old-client fencing and verified paged snapshot')
