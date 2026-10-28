#!/usr/bin/env python3
"""Oversized pre-existing data remains readable via raw pages and fenced from old writers."""
import base64, hashlib, json, os, urllib.error, urllib.request, uuid
BASE=os.environ.get('VOCAB_TEST_BASE','http://127.0.0.1:18765').rstrip('/')
def call(path,method='GET',body=None,token=None):
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    req=urllib.request.Request(BASE+path,None if body is None else json.dumps(body).encode(),headers,method=method)
    with urllib.request.urlopen(req,timeout=60) as response:return json.load(response)
def reject(status,path,method='GET',body=None,token=None):
    try: call(path,method,body,token)
    except urllib.error.HTTPError as error: assert error.code==status,(error.code,status,error.read())
    else: raise AssertionError(f'{path} unexpectedly succeeded')
seed=call('/api/v1/__ui_fixture/recovery-case','POST',{});token=seed['token']
other=call('/api/v1/auth/register','POST',{'username':'large_'+uuid.uuid4().hex[:8],'password':'test_password_123'})['token']
size=8*1024*1024+65536
initial=call('/api/v1/me/state',token=token)
apple=dict(initial['state']['cards']['apple']);apple['fixtureMarker']='before-large'
earlier={'generation':initial['sync_generation'],'base_revision':initial['state_revision'],'restore_epoch':0,'batch_id':uuid.uuid4().hex,
         'ops':[{'op':'set','path':['cards','apple'],'value':apple}]}
earlier_receipt=call('/api/v1/me/state/deltas','POST',earlier,token)
revision=call('/api/v1/__ui_fixture/oversize-stored-state','POST',{'token':token,'size':size})['revision']
reject(413,'/api/v1/me/state',token=token)
enriched=call('/api/v1/me/state/snapshots?representation=enriched','POST',{},token)
assert enriched['byte_length']>8*1024*1024 and enriched['state_revision']==revision
enriched_pages=[]
for page in range(enriched['page_count']):
    result=call(f"/api/v1/me/state/snapshots/{enriched['snapshot_id']}?page={page}",token=token)
    enriched_pages.append(base64.b64decode(result['data'],validate=True))
enriched_payload=b''.join(enriched_pages)
assert len(enriched_payload)==enriched['byte_length'] and hashlib.sha256(enriched_payload).hexdigest()==enriched['sha256']
assert len(json.loads(enriched_payload)['state']['fixtureLarge'])==size
call(f"/api/v1/me/state/snapshots/{enriched['snapshot_id']}",'DELETE',None,token)
manifest=call('/api/v1/me/state/snapshots?representation=stored','POST',{},token)
assert manifest['state_revision']==revision and manifest['byte_length']>8*1024*1024
reject(404,f"/api/v1/me/state/snapshots/{manifest['snapshot_id']}?page=0",token=other)
pages=[]
for page in range(manifest['page_count']):
    result=call(f"/api/v1/me/state/snapshots/{manifest['snapshot_id']}?page={page}",token=token)
    assert result['page']==page and result['snapshot_id']==manifest['snapshot_id']
    pages.append(base64.b64decode(result['data'],validate=True))
payload=b''.join(pages)
assert len(payload)==manifest['byte_length'] and hashlib.sha256(payload).hexdigest()==manifest['sha256']
state=json.loads(payload)['state'];assert len(state['fixtureLarge'])==size and state['cards']['apple']
# Neither an old whole-state write nor a shrink patch may overwrite this baseline.
small={'v':1,'cards':{},'log':[],'pendingNew':[],'settings':{}}
reject(413,'/api/v1/me/state','PUT',small,token)
batch={'generation':manifest['generation'],'base_revision':revision,'restore_epoch':0,'batch_id':uuid.uuid4().hex,
       'ops':[{'op':'remove','path':['fixtureLarge']}]}
reject(413,'/api/v1/me/state/deltas','POST',batch,token)
# An already acknowledged earlier batch can still be replayed without writing.
assert call('/api/v1/me/state/deltas','POST',earlier,token)==earlier_receipt
# Staging cannot bypass the same protection for a shrinking patch.
staged_bytes=json.dumps(batch['ops'],separators=(',',':')).encode()
staged={'batch_id':batch['batch_id'],'generation':batch['generation'],'base_revision':revision,'restore_epoch':0,
        'byte_length':len(staged_bytes),'part_count':1,'sha256':hashlib.sha256(staged_bytes).hexdigest()}
call('/api/v1/me/state/delta-stages','POST',staged,token)
call(f"/api/v1/me/state/delta-stages/{batch['batch_id']}/parts/0",'PUT',{'data':base64.b64encode(staged_bytes).decode()},token)
reject(413,f"/api/v1/me/state/delta-stages/{batch['batch_id']}/commit",'POST',{},token)
after=call('/api/v1/me/state/snapshots?representation=stored','POST',{},token)
assert after['state_revision']==revision and after['sha256']==manifest['sha256']
# Legacy JSON may be physically larger than 8 MiB because non-ASCII text
# was escaped; its canonical UTF-8 state remains within the permitted limit.
escaped=call('/api/v1/__ui_fixture/recovery-case','POST',{});escaped_token=escaped['token']
raw=call('/api/v1/__ui_fixture/escaped-stored-state','POST',{'token':escaped_token})
assert raw['physical_bytes']>8*1024*1024
view=call('/api/v1/me/state',token=escaped_token)
assert len(view['state']['fixtureLarge'])==1_450_000 and view['state_revision']==raw['revision']
assert call('/api/v1/me/state','PUT',view['state'],escaped_token)['ok']
# The whole-state response is bounded after scheduler enrichment too; paged
# enriched snapshots remain available without truncating that response.
call('/api/v1/__ui_fixture/scheduler-enrichment-padding','POST',{'size':5*1024*1024})
reject(413,'/api/v1/me/state',token=escaped_token)
enriched_only=call('/api/v1/me/state/snapshots?representation=enriched','POST',{},escaped_token)
assert enriched_only['byte_length']>8*1024*1024
raw_only=call('/api/v1/me/state/snapshots?representation=stored','POST',{},escaped_token)
assert raw_only['byte_length']<8*1024*1024
call('/api/v1/__ui_fixture/scheduler-enrichment-padding','POST',{'size':0})
print('PASS pre-existing oversized state is paged intact and fenced from legacy writes')
