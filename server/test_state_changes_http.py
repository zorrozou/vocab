#!/usr/bin/env python3
"""Journal rows reconstruct actual committed writes, or fence a restore."""
import base64, copy, hashlib, json, os, urllib.error, urllib.request, uuid
from concurrent.futures import ThreadPoolExecutor

BASE = os.environ.get('VOCAB_TEST_BASE', 'http://127.0.0.1:18765').rstrip('/')
def call(path, method='GET', body=None, token=None):
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    req=urllib.request.Request(BASE+path, None if body is None else json.dumps(body,ensure_ascii=False).encode(),headers,method=method)
    with urllib.request.urlopen(req,timeout=45) as response: return json.load(response)
def register():
    return call('/api/v1/auth/register','POST',{'username':'journal_'+uuid.uuid4().hex[:8],'password':'test_password_123'})['token']
def history(token): return call('/api/v1/__ui_fixture/state-changes','POST',{'token':token})['changes']
def apply(state, row):
    payload=base64.b64decode(row['payload'],validate=True)
    assert hashlib.sha256(payload).hexdigest()==row['sha256']
    assert not row['reset']
    for op in json.loads(payload)['ops']:
        path=op['path']
        if not path:
            assert op['op']=='set'; state=copy.deepcopy(op['value']); continue
        target=state
        for name in path[:-1]: target=target[name]
        if op['op']=='remove': del target[path[-1]]
        else: target[path[-1]]=copy.deepcopy(op['value'])
    return state

owner, other=register(),register()
state={'v':1,'cards':{'apple':{'pos':1,'extra':'词🙂'*30000}},'log':[],'pendingNew':[],'settings':{}}
call('/api/v1/me/state','PUT',state,owner)
with ThreadPoolExecutor(max_workers=4) as pool:
    def write(i):
        s=copy.deepcopy(state);s['cards'][f'word{i}']={'pos':i+2}
        return call('/api/v1/me/state','PUT',s,owner)
    list(pool.map(write,range(4)))
current=call('/api/v1/me/state',token=owner)
generation=call('/api/v1/me/state/snapshots?representation=stored','POST',{},owner)['generation']
def feed_path(after,page=0): return f'/api/v1/me/state/changes?after={after}&page={page}&generation={generation}'
rows=history(owner); assert len(rows)==int(current['state_revision'])
replayed=None
for i,row in enumerate(rows,1):
    assert row['revision']==str(i) and row['base_revision']==str(i-1)
    replayed=apply(replayed,row)
    first=call(feed_path(i-1),token=owner)['change']
    pages=[first]+[call(feed_path(i-1,page),token=owner)['change'] for page in range(1,first['page_count'])]
    assert all(p['revision']==str(i) and p['sha256']==row['sha256'] and p['page']==n for n,p in enumerate(pages))
    assert b''.join(base64.b64decode(p['data'],validate=True) for p in pages)==base64.b64decode(row['payload'])
    if i==1: assert first['page_count']>1
assert replayed==current['state']
assert history(other)==[]
assert call(feed_path(0),token=other)['change'] is None
legacy=register()
legacy_state={'v':1,'cards':{},'log':[],'pendingNew':[],'settings':{},'streak':2,'lastDay':'2026-10-26'}
call('/api/v1/me/state','PUT',legacy_state,legacy)
anchored=call('/api/v1/me/state',token=legacy)
legacy_rows=history(legacy)
assert len(legacy_rows)==2 and anchored['state_revision']=='2'
assert apply(apply(None,legacy_rows[0]),legacy_rows[1])==anchored['state']
assert call(feed_path(current['state_revision']),token=owner)['change'] is None
wrong_generation=('0' if generation[0]!='0' else '1')+generation[1:]
for path, code in [(feed_path('00'),422),(feed_path(999),409),(feed_path(0,999),416),('/api/v1/me/state/changes?after=0',422),(feed_path(0).replace(generation,wrong_generation),409)]:
    try: call(path,token=owner)
    except urllib.error.HTTPError as error:
        assert error.code==code, (path,error.code)
        assert error.headers.get('Cache-Control')=='no-store'
    else: raise AssertionError(f'{path} unexpectedly succeeded')
checkpoint=call('/api/v1/me/state/checkpoint','POST',{'expected_updated_at':current['updated_at']},owner)
last=history(owner)[-1]
assert last['reset'] and last['epoch']==1 and last['revision']==checkpoint['state_revision']
try: call(feed_path(current['state_revision']),token=owner)
except urllib.error.HTTPError as error: assert error.code==409
else: raise AssertionError('checkpoint change did not fence the old cursor')
try: call('/api/v1/me/state','PUT',state,owner)
except urllib.error.HTTPError as error: assert error.code==409
else: raise AssertionError('stale pre-checkpoint write accepted')
assert history(owner)[-1]==last
call('/api/v1/me/state/restore','POST',{'state':state,'expected_updated_at':checkpoint['updated_at']},owner)
assert history(owner)[-1]['reset'] and history(owner)[-1]['epoch']==2
# Bounded retention prunes old revisions, never renumbers the surviving rows.
current=call('/api/v1/me/state',token=owner)['state']
for _ in range(35): call('/api/v1/me/state','PUT',current,owner)
rows=history(owner); assert len(rows)==32
assert int(rows[0]['revision']) > 1 and all(int(b['revision'])==int(a['revision'])+1 for a,b in zip(rows,rows[1:]))
try: call(feed_path(0),token=owner)
except urllib.error.HTTPError as error:
    assert error.code==410
    assert error.headers.get('Cache-Control')=='no-store'
else: raise AssertionError('pruned history did not require a fresh snapshot')
before=call('/api/v1/me/state',token=owner)
prior=history(owner)
call('/api/v1/__ui_fixture/state-changes-failure','POST',{'enabled':True})
changed=copy.deepcopy(before['state']); changed['cards']['rollback']={'pos':99}
try: call('/api/v1/me/state','PUT',changed,owner)
except urllib.error.HTTPError as error: assert error.code==500
else: raise AssertionError('journal write failure unexpectedly committed')
call('/api/v1/__ui_fixture/state-changes-failure','POST',{'enabled':False})
assert call('/api/v1/me/state',token=owner)==before and history(owner)==prior
# Large legacy journal entries may be evicted while compact history stays usable.
large_user=register()
large_state={'v':1,'cards':{},'log':[{'eventId':f'{i:032x}','d':'2026-10-27','word':f'word{i:04d}','kind':'review','rating':3} for i in range(500)],'pendingNew':[],'settings':{}}
call('/api/v1/me/state','PUT',large_state,large_user)
large_before=call('/api/v1/me/state',token=large_user)
large_gen=large_before['sync_generation']; large_rev=int(large_before['state_revision'])
call('/api/v1/__ui_fixture/state-changes-byte-limit','POST',{'limit':1800})
for i in range(3):
    event={'eventId':f'{1000+i:032x}','d':'2099-01-01','word':f'new{i}','kind':'review','rating':4}
    batch={'generation':large_gen,'base_revision':str(large_rev+i),'restore_epoch':0,'batch_id':uuid.uuid4().hex,
           'ops':[{'op':'append_log','path':['log'],'value':[event]}]}
    call('/api/v1/me/state/deltas','POST',batch,large_user)
for i in range(3):
    path=f'/api/v1/me/state/changes?after={large_rev+i}&generation={large_gen}'
    try: call(path,token=large_user)
    except urllib.error.HTTPError as error: assert error.code==410
    else: raise AssertionError('legacy journal should have expired')
    part=call(path+'&compact=true',token=large_user)['change']
    data=base64.b64decode(part['data'],validate=True)
    assert hashlib.sha256(data).hexdigest()==part['sha256']
    assert any(op['op']=='append_log' for op in json.loads(data)['ops'])
call('/api/v1/__ui_fixture/state-changes-byte-limit','POST',{'limit':16*1024*1024})
print('PASS paginated transactional state-change journal, concurrent writes, account isolation, reset fencing, retention and write rollback')
