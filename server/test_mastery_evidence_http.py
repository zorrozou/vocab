"""Mastery context survives legacy clients, checkpoint and log truncation over HTTP."""
import copy, json, os, sys, urllib.request, uuid
from pathlib import Path
sys.path.insert(0, 'server')
from app.study_policy import is_mastered
BASE=os.environ.get('VOCAB_TEST_BASE','http://127.0.0.1:18765').rstrip('/')
def call(path, body=None, token=None, method=None):
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    request=urllib.request.Request(BASE+path,None if body is None else json.dumps(body).encode(),headers,method=method)
    with urllib.request.urlopen(request,timeout=30) as response:return json.load(response)
token=call('/api/v1/auth/register',{'username':'mastery_'+uuid.uuid4().hex[:10],'password':'fixture_password_123'})['token']
cases=json.loads((Path(__file__).parents[1]/'tests/study_policy_fixtures.json').read_text())
card=copy.deepcopy(next(c['card'] for c in cases if c['name']=='three spaced successes graduate'))
state={'v':1,'cards':{'apple':card},'settings':{},'log':[],'pendingNew':[]}
call('/api/v1/me/state',state,token,'PUT')
legacy=copy.deepcopy(state);legacy['cards']['apple'].pop('studyEvidence')
call('/api/v1/me/state',legacy,token,'PUT')
saved=call('/api/v1/me/state',token=token)
assert saved['state']['cards']['apple']['studyEvidence']==card['studyEvidence']
assert is_mastered(saved['state']['cards']['apple'])
compacted=call('/api/v1/me/state/checkpoint',{'expected_updated_at':saved['updated_at']},token)['state']
assert compacted['cards']['apple']['studyEvidence']==card['studyEvidence']
assert is_mastered(compacted['cards']['apple'])
updated=copy.deepcopy(compacted)
updated['cards']['apple']['studyEvidence']['events']['offline-again']={'at':'2026-04-01T08:00:00Z','day':'2026-04-01','rating':1,'kind':'review','verified':False}
call('/api/v1/me/state',updated,token,'PUT')
# A stale client from the same checkpoint cannot erase the independent evidence.
call('/api/v1/me/state',compacted,token,'PUT')
saved=call('/api/v1/me/state',token=token)['state']
assert not is_mastered(saved['cards']['apple'])
assert 'offline-again' in saved['cards']['apple']['studyEvidence']['events']
print('PASS mastery HTTP legacy merge, log independence, checkpoint and offline forgetting preservation')
