#!/usr/bin/env python3
"""HTTP tests for staged, atomic and account-scoped delta uploads."""
import base64, copy, hashlib, json, os, time, urllib.error, urllib.request, uuid
from concurrent.futures import ThreadPoolExecutor
BASE=os.environ.get('VOCAB_TEST_BASE','http://127.0.0.1:18765').rstrip('/')
PART=256*1024

def call(path,method='GET',body=None,token=None):
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    req=urllib.request.Request(BASE+path,None if body is None else json.dumps(body,ensure_ascii=False).encode(),headers,method=method)
    with urllib.request.urlopen(req,timeout=60) as response:
        if 'delta-stages' in path: assert response.headers.get('Cache-Control')=='no-store'
        return json.load(response)
def reject(code,path,method='GET',body=None,token=None):
    try: call(path,method,body,token)
    except urllib.error.HTTPError as e: assert e.code==code,(e.code,code,e.read())
    else: raise AssertionError(f'{path} unexpectedly succeeded')
def reg(): return call('/api/v1/auth/register','POST',{'username':'stage_'+uuid.uuid4().hex[:8],'password':'test_password_123'})['token']
def manifest(generation,revision,epoch,ops,batch=None):
    payload=json.dumps(ops,ensure_ascii=False,separators=(',',':'),allow_nan=False).encode()
    body={'batch_id':batch or uuid.uuid4().hex,'generation':generation,'base_revision':str(revision),'restore_epoch':epoch,
          'byte_length':len(payload),'part_count':(len(payload)+PART-1)//PART,'sha256':hashlib.sha256(payload).hexdigest()}
    return body,payload
def create(token,m): return call('/api/v1/me/state/delta-stages','POST',m,token)
def part(token,m,payload,n):
    return call(f"/api/v1/me/state/delta-stages/{m['batch_id']}/parts/{n}",'PUT',{'data':base64.b64encode(payload[n*PART:(n+1)*PART]).decode()},token)
def commit(token,m): return call(f"/api/v1/me/state/delta-stages/{m['batch_id']}/commit",'POST',{},token)

owner,other=reg(),reg()
head=call('/api/v1/me/state',token=owner);gen=head['sync_generation']
state={'v':1,'cards':{'apple':{'pos':1}},'log':[],'pendingNew':[],'settings':{},'notes':'x'*(2300*1024)}
ops=[{'op':'set','path':[],'value':state}]
m,payload=manifest(gen,0,0,ops)
reject(413,'/api/v1/me/state/deltas','POST',{'generation':gen,'base_revision':'0','restore_epoch':0,'batch_id':m['batch_id'],'ops':ops},owner)
created=create(owner,m);assert created==create(owner,m) and created['part_bytes']==PART
reject(409,'/api/v1/me/state/delta-stages','POST',{**m,'sha256':'0'*64},owner)
reject(404,f"/api/v1/me/state/delta-stages/{m['batch_id']}/parts/0",'PUT',{'data':base64.b64encode(payload[:PART]).decode()},other)
reject(409,f"/api/v1/me/state/delta-stages/{m['batch_id']}/commit",'POST',{},owner)
assert call('/api/v1/me/state',token=owner)['state'] is None
for i in reversed(range(m['part_count'])): assert part(owner,m,payload,i)['part']==i
assert part(owner,m,payload,0)['ok']
reject(409,f"/api/v1/me/state/delta-stages/{m['batch_id']}/parts/0",'PUT',{'data':base64.b64encode(b'z'*PART).decode()},owner)
reject(416,f"/api/v1/me/state/delta-stages/{m['batch_id']}/parts/{m['part_count']}",'PUT',{'data':'eA=='},owner)
with ThreadPoolExecutor(max_workers=3) as pool: receipts=list(pool.map(lambda _:commit(owner,m),range(3)))
assert all(r==receipts[0] for r in receipts) and receipts[0]['state_revision']=='1'
assert create(owner,m)==created and commit(owner,m)==receipts[0]
assert call('/api/v1/me/state',token=owner)['state']['notes']==state['notes']
# Stale stages never replace a newer committed state.
stale_ops=[{'op':'set','path':['cards','pear'],'value':{'pos':3}}]
stale,raw=manifest(gen,1,0,stale_ops);create(owner,stale);part(owner,stale,raw,0)
legacy=copy.deepcopy(state);legacy['cards']['banana']={'pos':2}
call('/api/v1/me/state','PUT',legacy,owner)
reject(409,f"/api/v1/me/state/delta-stages/{stale['batch_id']}/commit",'POST',{},owner)
assert set(call('/api/v1/me/state',token=owner)['state']['cards'])=={'apple','banana'}
# Invalid cross-part semantics, digest mismatch, expiry and account quotas do not write state.
invalid,raw=manifest(gen,2,0,[{'op':'set','path':['cards','x'],'value':{'pos':1}},{'op':'set','path':['cards','x'],'value':{'pos':2}}]);create(owner,invalid);part(owner,invalid,raw,0)
reject(422,f"/api/v1/me/state/delta-stages/{invalid['batch_id']}/commit",'POST',{},owner)
wrong,raw=manifest(gen,2,0,[{'op':'set','path':['cards','y'],'value':{'pos':4}}]);wrong['sha256']='0'*64
# Three active stages already reserve this account's quota.
reject(429,'/api/v1/me/state/delta-stages','POST',wrong,owner)
assert call('/api/v1/__ui_fixture/delta-stage-expire','POST',{'token':owner,'batch_id':stale['batch_id']})['changed']==1
reject(410,f"/api/v1/me/state/delta-stages/{stale['batch_id']}/commit",'POST',{},owner)
create(owner,wrong);part(owner,wrong,raw,0)
reject(409,f"/api/v1/me/state/delta-stages/{wrong['batch_id']}/commit",'POST',{},owner)
assert set(call('/api/v1/me/state',token=owner)['state']['cards'])=={'apple','banana'}
# Acknowledged stages can be released without changing learning state.
reject(404,f"/api/v1/me/state/delta-stages/{m['batch_id']}",'DELETE',None,other)
assert call(f"/api/v1/me/state/delta-stages/{m['batch_id']}",'DELETE',None,owner)['ok']
reject(404,f"/api/v1/me/state/delta-stages/{m['batch_id']}/commit",'POST',{},owner)
assert set(call('/api/v1/me/state',token=owner)['state']['cards'])=={'apple','banana'}
# A restore epoch change rejects a fully uploaded old stage.
old_epoch,old_raw=manifest(gen,2,0,[{'op':'set','path':['cards','old'],'value':{'pos':7}}]);create(owner,old_epoch);part(owner,old_epoch,old_raw,0)
current=call('/api/v1/me/state',token=owner)
call('/api/v1/me/state/checkpoint','POST',{'expected_updated_at':current['updated_at']},owner)
reject(409,f"/api/v1/me/state/delta-stages/{old_epoch['batch_id']}/commit",'POST',{},owner)
assert 'old' not in call('/api/v1/me/state',token=owner)['state']['cards']
# Database generation rotation removes transient parts and fences old retries.
call('/api/v1/__ui_fixture/reset-sync-generation','POST',{})
reject(404,f"/api/v1/me/state/delta-stages/{wrong['batch_id']}/commit",'POST',{},owner)
reject(409,'/api/v1/me/state/delta-stages','POST',m,owner)
reject(401,'/api/v1/me/state/delta-stages','POST',m)
newgen=call('/api/v1/me/state',token=other)['sync_generation']
small_state={'v':1,'cards':{'apple':{'pos':1}},'log':[],'pendingNew':[],'settings':{}}
retry,raw=manifest(newgen,0,0,[{'op':'set','path':[],'value':small_state}]);create(other,retry);part(other,retry,raw,0)
call('/api/v1/__ui_fixture/state-changes-failure','POST',{'enabled':True})
reject(500,f"/api/v1/me/state/delta-stages/{retry['batch_id']}/commit",'POST',{},other)
assert call('/api/v1/me/state',token=other)['state'] is None
call('/api/v1/__ui_fixture/state-changes-failure','POST',{'enabled':False})
assert commit(other,retry)['state_revision']=='1'
# Deleting and recreating a stage while commit waits must not let the old
# assembled bytes commit under the new staging instance.
race,raw=manifest(newgen,1,0,[{'op':'set','path':['cards','late'],'value':{'pos':9}}]);create(other,race);part(other,race,raw,0)
call('/api/v1/__ui_fixture/delta-stage-hold','POST',{'batch_id':race['batch_id']})
with ThreadPoolExecutor(max_workers=1) as pool:
    pending=pool.submit(commit,other,race)
    for _ in range(200):
        if call('/api/v1/__ui_fixture/delta-stage-hold')['started']: break
        time.sleep(.05)
    else: raise AssertionError('stage commit did not reach gate')
    call(f"/api/v1/me/state/delta-stages/{race['batch_id']}",'DELETE',None,other)
    create(other,race)
    call('/api/v1/__ui_fixture/delta-stage-release','POST',{})
    try: pending.result(timeout=20)
    except urllib.error.HTTPError as error: assert error.code==404
    else: raise AssertionError('deleted stage committed')
assert 'late' not in call('/api/v1/me/state',token=other)['state']['cards']
call(f"/api/v1/me/state/delta-stages/{race['batch_id']}",'DELETE',None,other)
# Staging cannot bypass the current 8 MiB stored-state limit.
too_big,raw=manifest(newgen,1,0,[{'op':'set','path':['notes'],'value':'x'*(8*1024*1024)}]);create(other,too_big)
for index in range(too_big['part_count']): part(other,too_big,raw,index)
reject(413,f"/api/v1/me/state/delta-stages/{too_big['batch_id']}/commit",'POST',{},other)
assert call('/api/v1/me/state',token=other)['state']==small_state
call(f"/api/v1/me/state/delta-stages/{too_big['batch_id']}",'DELETE',None,other)
# More than 2048 distinct operations are atomic through staging, while the
# legacy single-request endpoint retains its old safety bound.
bulk_ops=[{'op':'set','path':['cards',f'bulk_{i:04d}'],'value':{'pos':i+2}} for i in range(2500)]
bulk,raw=manifest(newgen,1,0,bulk_ops)
reject(422,'/api/v1/me/state/deltas','POST',{'generation':newgen,'base_revision':'1','restore_epoch':0,'batch_id':bulk['batch_id'],'ops':bulk_ops},other)
create(other,bulk)
for i in range(bulk['part_count']):part(other,bulk,raw,i)
assert commit(other,bulk)['state_revision']=='2'
assert len(call('/api/v1/me/state',token=other)['state']['cards'])==2501
feed=call(f'/api/v1/me/state/changes?after=1&generation={newgen}',token=other);assert feed['change']['revision']=='2'
excess_ops=[{'op':'set','path':['cards',f'excess_{i:05d}'],'value':{'pos':i}} for i in range(8193)]
excess,raw=manifest(newgen,2,0,excess_ops);create(other,excess)
for i in range(excess['part_count']):part(other,excess,raw,i)
reject(422,f"/api/v1/me/state/delta-stages/{excess['batch_id']}/commit",'POST',{},other)
assert len(call('/api/v1/me/state',token=other)['state']['cards'])==2501
print('PASS staged delta uploads: atomic retry, integrity, quota, expiry and version fences')
