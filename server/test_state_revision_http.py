#!/usr/bin/env python3
"""Stored-state revisions advance atomically for each committed mutation."""
import copy, json, os, urllib.error, urllib.request, uuid
from concurrent.futures import ThreadPoolExecutor

BASE = os.environ.get('VOCAB_TEST_BASE', 'http://127.0.0.1:18765').rstrip('/')
def call(path, body=None, token=None, method=None):
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    req=urllib.request.Request(BASE+path, None if body is None else json.dumps(body).encode(), headers, method=method)
    with urllib.request.urlopen(req,timeout=40) as response: return json.load(response)
def reject(fn, code):
    try: fn()
    except urllib.error.HTTPError as exc: assert exc.code == code, exc.code
    else: raise AssertionError('expected request rejection')

a = call('/api/v1/auth/register', {'username':'rev_'+uuid.uuid4().hex[:10], 'password':'test_password_123'})
b = call('/api/v1/auth/register', {'username':'rev_'+uuid.uuid4().hex[:10], 'password':'test_password_123'})
token, other = a['token'], b['token']
assert call('/api/v1/me/state',token=token)['state_revision']=='0'
assert call('/api/v1/me/state',token=other)['state_revision']=='0'
base={'v':1,'calibrated':True,'frontier':1,'pointer':1,'probeCount':0,'cards':{},'log':[],'pendingNew':[],'settings':{}}
first=call('/api/v1/me/state',base,token,'PUT')
assert first['state_revision']=='1' and first['ok'] is True
assert call('/api/v1/me/state',token=token)['state_revision']=='1'
# Parallel legacy PUTs all receive distinct committed revisions; no cards are lost.
def write(i):
    branch=copy.deepcopy(base); branch['cards']={f'word{i}':{'pos':i+1}}
    return call('/api/v1/me/state',branch,token,'PUT')['state_revision']
with ThreadPoolExecutor(max_workers=6) as pool:
    revisions=list(pool.map(write,range(6)))
assert sorted(map(int,revisions))==list(range(2,8))
current=call('/api/v1/me/state',token=token)
assert current['state_revision']=='7' and len(current['state']['cards'])==6
assert call('/api/v1/me/state',token=other)['state_revision']=='0'
# Failed validation and stale restore leave revision unchanged.
bad=copy.deepcopy(current['state']); bad['settingsVersions']={'newPerDay':{'counter':-1,'device':'test'}}
reject(lambda:call('/api/v1/me/state',bad,token,'PUT'),422)
reject(lambda:call('/api/v1/me/state/restore',{'state':base,'expected_updated_at':current['updated_at']-1},token),409)
assert call('/api/v1/me/state',token=token)['state_revision']=='7'
checkpoint=call('/api/v1/me/state/checkpoint',{'expected_updated_at':current['updated_at']},token)
assert checkpoint['state_revision']=='8'
restored=call('/api/v1/me/state/restore',{'state':base,'expected_updated_at':checkpoint['updated_at']},token)
assert restored['state_revision']=='9' and restored['state']['restoreEpoch']==2
assert call('/api/v1/me/state',token=token)['state_revision']=='9'
# The first read that anchors old evidence is itself one committed revision.
legacy=copy.deepcopy(base); legacy['knowledge']={'apple':{'a':1,'b':1,'pos':1}}
put=call('/api/v1/me/state',legacy,other,'PUT'); assert put['state_revision']=='1'
with ThreadPoolExecutor(max_workers=5) as pool:
    reads=list(pool.map(lambda _:call('/api/v1/me/state',token=other),range(5)))
assert {r['state_revision'] for r in reads}=={'2'}
assert all(r['state']['knowledgeEvidence']['apple']['baseId']==reads[0]['state']['knowledgeEvidence']['apple']['baseId'] for r in reads)
# Decimal strings preserve exact revisions beyond JavaScript's integer range.
high=2**53+1
call('/api/v1/__ui_fixture/revision-set',{'token':token,'revision':str(high)})
latest=call('/api/v1/me/state',token=token)
assert latest['state_revision']==str(high)
assert call('/api/v1/me/state',latest['state'],token,'PUT')['state_revision']==str(high+1)
# Overflow must roll back both the state and any checkpoint/restore backups.
maximum=2**63-1
call('/api/v1/__ui_fixture/revision-set',{'token':token,'revision':str(maximum)})
latest=call('/api/v1/me/state',token=token)
backups=call('/api/v1/me/state/backups',token=token)['backups']
reject(lambda:call('/api/v1/me/state',latest['state'],token,'PUT'),409)
reject(lambda:call('/api/v1/me/state/checkpoint',{'expected_updated_at':latest['updated_at']},token),409)
reject(lambda:call('/api/v1/me/state/restore',{'state':base,'expected_updated_at':latest['updated_at']},token),409)
after=call('/api/v1/me/state',token=token)
assert after['state_revision']==str(maximum) and after['state']==latest['state']
assert call('/api/v1/me/state/backups',token=token)['backups']==backups
print('PASS committed stored-state revisions, concurrent PUT and anchoring, restore, checkpoint, rollback and integer limits')
