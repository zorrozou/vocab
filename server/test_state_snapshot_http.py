#!/usr/bin/env python3
"""Immutable, owner-scoped snapshot pages against a disposable HTTP server."""
import base64, copy, hashlib, json, os, urllib.error, urllib.parse, urllib.request, uuid
from concurrent.futures import ThreadPoolExecutor

BASE=os.environ.get('VOCAB_TEST_BASE','http://127.0.0.1:18765').rstrip('/')
def request(path, method='GET', body=None, token=None):
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    data=None if body is None else json.dumps(body,ensure_ascii=False).encode()
    req=urllib.request.Request(BASE+path,data,headers,method=method)
    with urllib.request.urlopen(req,timeout=45) as r:
        return json.load(r),r.headers

def call(path, method='GET', body=None, token=None): return request(path,method,body,token)[0]
def rejects(code, path, method='GET', body=None, token=None):
    try: call(path,method,body,token)
    except urllib.error.HTTPError as e: assert e.code==code, (path,e.code,code)
    else: raise AssertionError(f'{path} unexpectedly succeeded')
def register():
    return call('/api/v1/auth/register','POST',{'username':'snap_'+uuid.uuid4().hex[:10],'password':'test_password_123'})['token']
def make(token): return call('/api/v1/me/state/snapshots','POST',{},token)
def page(token,snapshot,n):
    data,headers=request(f'/api/v1/me/state/snapshots/{snapshot}?page={n}',token=token)
    assert headers.get('Cache-Control')=='no-store' and data['page']==n and data['snapshot_id']==snapshot
    return base64.b64decode(data['data'],validate=True)
def unpack(token, manifest):
    chunks=[page(token,manifest['snapshot_id'],i) for i in range(manifest['page_count'])]
    assert all(len(x)==manifest['page_bytes'] for x in chunks[:-1])
    payload=b''.join(chunks)
    assert len(payload)==manifest['byte_length']
    assert hashlib.sha256(payload).hexdigest()==manifest['sha256']
    return json.loads(payload)

owner, other=register(),register()
rejects(401,'/api/v1/me/state/snapshots','POST',{})
empty=make(owner)
assert empty['state_revision']=='0' and unpack(owner,empty)['state'] is None
sid=empty['snapshot_id']
rejects(404,f'/api/v1/me/state/snapshots/{sid}?page=0',token=other)
rejects(404,f'/api/v1/me/state/snapshots/{sid}','DELETE',token=other)
rejects(416,f'/api/v1/me/state/snapshots/{sid}?page=1',token=owner)
assert call(f'/api/v1/me/state/snapshots/{sid}','DELETE',token=owner)['ok']
rejects(404,f'/api/v1/me/state/snapshots/{sid}?page=0',token=owner)

state={'v':1,'calibrated':True,'frontier':1,'pointer':1,'probeCount':0,'cards':{'apple':{'pos':1,'extra':'词汇🙂'*90000}},'log':[],'pendingNew':[],'settings':{}}
put=call('/api/v1/me/state','PUT',state,owner)
old=make(owner); assert old['page_count']>1 and old['state_revision']==put['state_revision']
# Mutating between pages cannot mix different stored versions.
first=page(owner,old['snapshot_id'],0)
new=copy.deepcopy(state);new['cards']['banana']={'pos':2}
call('/api/v1/me/state','PUT',new,owner)
parts=[first]+[page(owner,old['snapshot_id'],i) for i in range(1,old['page_count'])]
payload=b''.join(parts)
assert hashlib.sha256(payload).hexdigest()==old['sha256']
assert set(json.loads(payload)['state']['cards'])=={'apple'}
assert set(call('/api/v1/me/state',token=owner)['state']['cards'])=={'apple','banana'}
current=call('/api/v1/me/state',token=owner)
checkpoint=call('/api/v1/me/state/checkpoint','POST',{'expected_updated_at':current['updated_at']},owner)
rejects(409,f"/api/v1/me/state/snapshots/{old['snapshot_id']}?page=0",token=owner)
next_snap=make(owner); assert next_snap['restore_epoch']==1
restore=call('/api/v1/me/state/restore','POST',{'state':state,'expected_updated_at':checkpoint['updated_at']},owner)
assert restore['state']['restoreEpoch']==2
rejects(409,f"/api/v1/me/state/snapshots/{next_snap['snapshot_id']}?page=0",token=owner)

# Three live snapshots per account; concurrent creation cannot bypass the limit.
with ThreadPoolExecutor(max_workers=4) as pool:
    futures=[pool.submit(make,other) for _ in range(4)]
    success=[]; failures=[]
    for future in futures:
        try: success.append(future.result())
        except urllib.error.HTTPError as error: failures.append(error.code)
assert len(success)==3 and failures==[429], (len(success),failures)
expired=success[0]['snapshot_id']
call('/api/v1/__ui_fixture/snapshot-expire','POST',{'token':other,'snapshot_id':expired})
rejects(404,f'/api/v1/me/state/snapshots/{expired}?page=0',token=other)
replacement=make(other); assert replacement['snapshot_id']!=expired

# Enriched scheduler data is frozen in the snapshot even if its separate DB changes.
scheduler_owner=register()
review=call('/api/v1/fsrs/review','POST',{'is_new':True,'rating':3,'deterministic':True},scheduler_owner)
key=review['scheduler_key']
state2={'v':1,'cards':{'apple':{'pos':1,'fsrsHistory':{'base':{'is_new':True,'state':1,'stability':0,'difficulty':0,'rating':3},'events':[{'id':'snapshot-event','at':'2026-10-27T00:00:00Z','rating':3,'schedulerKey':key}]}}},'log':[],'pendingNew':[],'settings':{}}
call('/api/v1/me/state','PUT',state2,scheduler_owner)
enriched=call('/api/v1/me/state',token=scheduler_owner)
assert key in enriched['state']['fsrsSchedulers']
frozen=make(scheduler_owner)
assert call('/api/v1/__ui_fixture/scheduler-delete','POST',{'token':scheduler_owner,'key':key})['deleted']==1
changed=call('/api/v1/me/state',token=scheduler_owner)
assert changed['state_revision']==enriched['state_revision'] and key not in (changed['state'].get('fsrsSchedulers') or {})
assert key in unpack(scheduler_owner,frozen)['state']['fsrsSchedulers']
print('PASS immutable paged snapshot, auth, quota, expiry, restore fencing and frozen scheduler enrichment')
