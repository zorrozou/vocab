#!/usr/bin/env python3
"""Transactional, account-scoped delta uploads over the real HTTP API."""
import base64, copy, hashlib, json, os, urllib.error, urllib.request, uuid
from concurrent.futures import ThreadPoolExecutor
BASE=os.environ.get('VOCAB_TEST_BASE','http://127.0.0.1:18765').rstrip('/')
def call(path,method='GET',body=None,token=None):
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    req=urllib.request.Request(BASE+path,None if body is None else json.dumps(body,ensure_ascii=False).encode(),headers,method=method)
    with urllib.request.urlopen(req,timeout=45) as response:
        if path.endswith('/deltas'): assert response.headers.get('Cache-Control')=='no-store'
        return json.load(response)
def reject(code,path,method='GET',body=None,token=None):
    try: call(path,method,body,token)
    except urllib.error.HTTPError as error: assert error.code==code, (error.code,code,error.read())
    else: raise AssertionError('request unexpectedly succeeded')
def register(): return call('/api/v1/auth/register','POST',{'username':'delta_'+uuid.uuid4().hex[:8],'password':'test_password_123'})['token']
def submit(token,batch): return call('/api/v1/me/state/deltas','POST',batch,token)
def make(gen,base,ops,epoch=0,batch=None):
    return {'generation':gen,'base_revision':str(base),'restore_epoch':epoch,'batch_id':batch or uuid.uuid4().hex,'ops':ops}
def add(word,pos): return {'op':'set','path':['cards',word],'value':{'pos':pos}}

owner,other=register(),register()
reject(401,'/api/v1/me/state/delta-capabilities')
assert call('/api/v1/me/state/delta-capabilities',token=owner)['append_log_v1'] is True
snapshot=call('/api/v1/me/state/snapshots?representation=stored','POST',{},owner)
generation=snapshot['generation']; assert snapshot['state_revision']=='0'
state={'v':1,'cards':{'apple':{'pos':1}},'log':[{'eventId':'aaaaaaaaaaaaaaaa','d':'2026-10-26','word':'apple','rating':3,'kind':'review'}],'pendingNew':[],'settings':{}}
initial=make(generation,0,[{'op':'set','path':[],'value':state}])
first=submit(owner,initial); assert first['state_revision']=='1' and submit(owner,initial)==first
assert call('/api/v1/me/state',token=owner)['state']['cards']==state['cards']
other_receipt=submit(other,initial); assert other_receipt['state_revision']=='1'  # IDs are account-scoped.
other_batch=make(generation,1,[add('pear',3)])
legacy=copy.deepcopy(state); legacy['cards']['kiwi']={'pos':2}
call('/api/v1/me/state','PUT',legacy,other)
reject(409,'/api/v1/me/state/deltas','POST',other_batch,other)
assert set(call('/api/v1/me/state',token=other)['state']['cards'])=={'apple','kiwi'}
rebased=make(generation,2,[add('pear',3)])
assert submit(other,rebased)['state_revision']=='3'
assert set(call('/api/v1/me/state',token=other)['state']['cards'])=={'apple','kiwi','pear'}
event={'eventId':uuid.uuid4().hex,'d':'2026-10-27','word':'apple','rating':4,'kind':'review'}
append=make(generation,3,[{'op':'append_log','path':['log'],'value':[event]}])
assert submit(other,append)['state_revision']=='4' and submit(other,append)['state_revision']=='4'
legacy_change=call(f'/api/v1/me/state/changes?after=3&generation={generation}',token=other)['change']
compact_change=call(f'/api/v1/me/state/changes?after=3&generation={generation}&compact=true',token=other)['change']
def change_ops(change):
    raw=base64.b64decode(change['data'],validate=True)
    assert len(raw)==change['byte_length'] and hashlib.sha256(raw).hexdigest()==change['sha256']
    return json.loads(raw)['ops']
assert any(o['op']=='set' and o['path']==['log'] for o in change_ops(legacy_change))
assert any(o['op']=='append_log' and o['value']==[event] for o in change_ops(compact_change))
assert legacy_change['revision']==compact_change['revision']=='4'
same=make(generation,4,[{'op':'append_log','path':['log'],'value':[event]}])
assert submit(other,same)['state_revision']=='5'
assert len([e for e in call('/api/v1/me/state',token=other)['state']['log'] if e.get('eventId')==event['eventId']])==1
conflict={**event,'word':'different'}
for ops in ([{'op':'append_log','path':['log'],'value':[conflict]}],
            [{'op':'append_log','path':['cards'],'value':[event]}],
            [{'op':'append_log','path':['log'],'value':[event,event]}],
            [{'op':'append_log','path':['log'],'value':[{}]}],
            [{'op':'append_log','path':['log'],'value':[event]}, {'op':'set','path':['log'],'value':[]} ]):
    reject(422,'/api/v1/me/state/deltas','POST',make(generation,5,ops),other)
call('/api/v1/__ui_fixture/delta-receipt-limit','POST',{'limit':2})
retained=[]
for index in range(3):
    item=make(generation,5+index,[add('bounded'+str(index),10+index)])
    receipt=submit(other,item); retained.append((item,receipt))
assert submit(other,retained[-1][0])==retained[-1][1]
reject(409,'/api/v1/me/state/deltas','POST',retained[0][0],other)
call('/api/v1/__ui_fixture/delta-receipt-limit','POST',{'limit':256})
guarded=copy.deepcopy(legacy);guarded['cards']['melon']={'pos':20}
guard_event=uuid.uuid4().hex
guarded['log']=[{'eventId':guard_event,'d':'2026-10-27','word':'apple','rating':4,'kind':'review'}]
guard_body={'generation':generation,'restore_epoch':0,'state':guarded}
assert call('/api/v1/me/state/guarded-merge','POST',guard_body,other)['generation']==generation
assert call('/api/v1/me/state/guarded-merge','POST',guard_body,other)['generation']==generation
guard_result=call('/api/v1/me/state',token=other)['state']
assert {'apple','kiwi','pear','melon'} <= set(guard_result['cards'])
assert len([entry for entry in guard_result['log'] if entry.get('eventId')==guard_event])==1
wrong=('0' if generation[0]!='0' else '1')+generation[1:]
reject(409,'/api/v1/me/state/guarded-merge','POST',{**guard_body,'generation':wrong},other)
reject(409,'/api/v1/me/state/guarded-merge','POST',{**guard_body,'restore_epoch':1},other)
changed=copy.deepcopy(initial);changed['ops'][0]['value']['cards']['bad']={'pos':99}
reject(409,'/api/v1/me/state/deltas','POST',changed,owner)

batch=make(generation,1,[add('banana',2)])
with ThreadPoolExecutor(max_workers=5) as pool: receipts=list(pool.map(lambda _:submit(owner,batch),range(5)))
assert all(r==receipts[0] for r in receipts) and receipts[0]['state_revision']=='2'
assert set(call('/api/v1/me/state',token=owner)['state']['cards'])=={'apple','banana'}
assert submit(owner,initial)==first  # Retrying an acknowledged older batch cannot write again.
competing=[make(generation,2,[add('cherry',3)]),make(generation,2,[add('date',4)])]
def race(item):
    try: return submit(owner,item)
    except urllib.error.HTTPError as error: return error.code
with ThreadPoolExecutor(max_workers=2) as pool: result=list(pool.map(race,competing))
assert len([r for r in result if isinstance(r,dict)])==1 and 409 in result
current=call('/api/v1/me/state',token=owner); assert current['state_revision']=='3'
assert len(current['state']['cards'])==3
feed=call(f'/api/v1/me/state/changes?after=2&generation={generation}',token=owner)
assert feed['change']['revision']=='3' and feed['change']['base_revision']=='2'
assert feed['change']['updated_at']==current['updated_at']

bad_batches=[
    make(generation,3,[]),
    make(generation,3,[add('x',4),add('x',5)]),
    make(generation,3,[{'op':'set','path':['cards'],'value':{}},add('x',4)]),
    make(generation,3,[{'op':'remove','path':['cards','missing']}]),
    make(generation,3,[{'op':'set','path':['__proto__'],'value':{}}]),
    make(generation,3,[{'op':'set','path':['cards','x','nested'],'value':1}]),
    make(generation,3,[{'op':'set','path':['restoreEpoch'],'value':True}]),
]
for item in bad_batches:
    expected=409 if item['ops'] and item['ops'][0]['path']==['restoreEpoch'] else 422
    reject(expected,'/api/v1/me/state/deltas','POST',item,owner)
huge=make(generation,3,[{'op':'set','path':['extra'],'value':'x'*(2*1024*1024)}])
reject(413,'/api/v1/me/state/deltas','POST',huge,owner)
reject(401,'/api/v1/me/state/deltas','POST',make(generation,3,[add('x',4)]))
assert call('/api/v1/me/state',token=owner)==current

# If journaling fails, neither state nor receipt commits; the same batch can retry.
retry=make(generation,3,[add('retry',5)])
call('/api/v1/__ui_fixture/state-changes-failure','POST',{'enabled':True})
reject(500,'/api/v1/me/state/deltas','POST',retry,owner)
call('/api/v1/__ui_fixture/state-changes-failure','POST',{'enabled':False})
assert call('/api/v1/me/state',token=owner)==current
assert submit(owner,retry)['state_revision']=='4' and submit(owner,retry)['state_revision']=='4'
assert call('/api/v1/__ui_fixture/delta-receipt-expire','POST',{'token':owner,'batch_id':retry['batch_id']})['changed']==1
reject(409,'/api/v1/me/state/deltas','POST',retry,owner)  # Expired receipts never replay even without cleanup.
current=call('/api/v1/me/state',token=owner)
checkpoint=call('/api/v1/me/state/checkpoint','POST',{'expected_updated_at':current['updated_at']},owner)
reject(409,'/api/v1/me/state/deltas','POST',retry,owner)  # Receipt cannot cross a restore epoch.
new_batch=make(generation,checkpoint['state_revision'],[add('after',6)],epoch=1)
assert submit(owner,new_batch)['restore_epoch']==1
new_generation=call('/api/v1/__ui_fixture/reset-sync-generation','POST',{})['generation']
assert new_generation!=generation
reject(409,'/api/v1/me/state/deltas','POST',new_batch,owner)
print('PASS delta uploads: atomic merge, concurrent CAS, idempotency, validation, failure rollback, epoch and generation fencing')
