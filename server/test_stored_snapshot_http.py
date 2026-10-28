#!/usr/bin/env python3
"""Stored snapshot is a usable baseline for the stored-state change journal."""
import base64, copy, hashlib, json, os, urllib.error, urllib.request, uuid
from concurrent.futures import ThreadPoolExecutor

BASE=os.environ.get('VOCAB_TEST_BASE','http://127.0.0.1:18765').rstrip('/')
def call(path, method='GET', body=None, token=None, key=None):
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    if key: headers['Idempotency-Key']=key
    req=urllib.request.Request(BASE+path,None if body is None else json.dumps(body,ensure_ascii=False).encode(),headers,method=method)
    with urllib.request.urlopen(req,timeout=45) as response:
        assert response.headers.get('Cache-Control')=='no-store' if '/snapshots' in path or '/changes' in path else True
        return json.load(response)
def reject(status, *args, **kwargs):
    try: call(*args,**kwargs)
    except urllib.error.HTTPError as error: assert error.code==status, (error.code,status)
    else: raise AssertionError('request unexpectedly succeeded')
def register():
    return call('/api/v1/auth/register','POST',{'username':'stored_'+uuid.uuid4().hex[:8],'password':'test_password_123'})['token']
def make(token, representation='stored', key=None):
    return call('/api/v1/me/state/snapshots?representation='+representation,'POST',{},token,key)
def unpack(token, manifest):
    pieces=[]
    for page in range(manifest['page_count']):
        result=call('/api/v1/me/state/snapshots/'+manifest['snapshot_id']+'?page='+str(page),token=token)
        assert result['page']==page and result['snapshot_id']==manifest['snapshot_id']
        pieces.append(base64.b64decode(result['data'],validate=True))
    data=b''.join(pieces)
    assert len(data)==manifest['byte_length'] and hashlib.sha256(data).hexdigest()==manifest['sha256']
    return json.loads(data)
def change(token, after, generation):
    first=call('/api/v1/me/state/changes?after='+after+'&generation='+generation,token=token)['change']
    assert first and first['base_revision']==after
    pages=[first]+[call(f'/api/v1/me/state/changes?after={after}&page={page}&generation={generation}',token=token)['change'] for page in range(1,first['page_count'])]
    data=b''.join(base64.b64decode(p['data'],validate=True) for p in pages)
    assert len(data)==first['byte_length'] and hashlib.sha256(data).hexdigest()==first['sha256']
    return first['revision'],json.loads(data)['ops']
def apply(state,ops):
    state=copy.deepcopy(state)
    for op in ops:
        path=op['path']
        if not path: state=copy.deepcopy(op['value']); continue
        target=state
        for key in path[:-1]: target=target[key]
        if op['op']=='remove': del target[path[-1]]
        else: target[path[-1]]=copy.deepcopy(op['value'])
    return state

owner,other=register(),register()
empty=make(owner)
assert empty['representation']=='stored' and unpack(owner,empty)['state'] is None
call('/api/v1/me/state/snapshots/'+empty['snapshot_id'],'DELETE',token=owner)
review=call('/api/v1/fsrs/review','POST',{'is_new':True,'rating':3,'deterministic':True},owner)
key=review['scheduler_key']
state={'v':1,'cards':{'apple':{'pos':1,'extra':'词🙂'*30000,'appliedFsrs':['baseline-event'],'fsrsHistory':{'base':{'is_new':True,'state':1,'stability':0,'difficulty':0,'rating':3},'events':[{'id':'baseline-event','at':'2026-10-27T00:00:00Z','rating':3,'schedulerKey':key}]}}},'log':[],'pendingNew':[],'settings':{}}
call('/api/v1/me/state','PUT',state,owner)
enriched_state=call('/api/v1/me/state',token=owner)['state']
assert key in enriched_state['fsrsSchedulers']
request_key=uuid.uuid4().hex
baseline=make(owner,key=request_key)
assert make(owner,key=request_key)==baseline
reject(409,'/api/v1/me/state/snapshots?representation=enriched','POST',{},owner,request_key)
reject(422,'/api/v1/me/state/snapshots?representation=invalid','POST',{},owner)
stored=unpack(owner,baseline)
assert baseline['page_count']>1 and 'fsrsSchedulers' not in stored['state']
# Stored snapshots do not depend on enriching from the scheduler database.
call('/api/v1/__ui_fixture/scheduler-enrichment-failure','POST',{'enabled':True})
isolated=make(owner); assert isolated['state_revision']==baseline['state_revision']
assert unpack(owner,isolated)['state']==stored['state']
reject(500,'/api/v1/me/state',token=owner)
reject(500,'/api/v1/me/state/snapshots?representation=enriched','POST',{},owner)
call('/api/v1/__ui_fixture/scheduler-enrichment-failure','POST',{'enabled':False})
call('/api/v1/me/state/snapshots/'+isolated['snapshot_id'],'DELETE',token=owner)
reject(404,'/api/v1/me/state/snapshots/'+baseline['snapshot_id']+'?page=0',token=other)
changed=copy.deepcopy(enriched_state);changed['cards']['banana']={'pos':2}
try:
    call('/api/v1/me/state','PUT',changed,owner)
except urllib.error.HTTPError as error:
    raise AssertionError(error.read().decode()) from error
rev,ops=change(owner,baseline['state_revision'],baseline['generation'])
next_snap=make(owner)
next_state=unpack(owner,next_snap)
assert rev==next_snap['state_revision'] and apply(stored['state'],ops)==next_state['state']
# A raw snapshot can be the first reader of a legacy state: concurrent
# requests must anchor it once and agree on the same durable baseline.
anchor_owner=register()
legacy={'v':1,'cards':{},'log':[],'pendingNew':[],'settings':{},'knowledge':{'apple':{'a':1,'b':1,'pos':1}}}
assert call('/api/v1/me/state','PUT',legacy,anchor_owner)['state_revision']=='1'
with ThreadPoolExecutor(max_workers=3) as pool:
    anchored=list(pool.map(lambda _:make(anchor_owner),range(3)))
assert {item['state_revision'] for item in anchored}=={'2'}
anchors=[unpack(anchor_owner,item)['state']['knowledgeEvidence']['apple']['baseId'] for item in anchored]
assert len(set(anchors))==1
assert call('/api/v1/me/state',token=anchor_owner)['state_revision']=='2'
for item in anchored: call('/api/v1/me/state/snapshots/'+item['snapshot_id'],'DELETE',token=anchor_owner)
# One key used concurrently for different representations must never alias them.
race_key=uuid.uuid4().hex
def race(kind):
    try: return make(other,kind,race_key)['representation']
    except urllib.error.HTTPError as error: return error.code
with ThreadPoolExecutor(max_workers=2) as pool:
    outcomes=list(pool.map(race,['stored','enriched']))
assert 409 in outcomes and len([v for v in outcomes if v in ('stored','enriched')])==1, outcomes
current=call('/api/v1/me/state',token=owner)
restore={'v':1,'cards':{},'log':[],'pendingNew':[],'settings':{}}
call('/api/v1/me/state/restore','POST',{'state':restore,'expected_updated_at':current['updated_at']},owner)
reject(409,'/api/v1/me/state/snapshots/'+baseline['snapshot_id']+'?page=0',token=owner)
reject(409,'/api/v1/me/state/changes?after='+baseline['state_revision']+'&generation='+baseline['generation'],token=owner)
print('PASS stored snapshot baseline, scheduler separation, paged change replay, idempotency isolation and restore fencing')
