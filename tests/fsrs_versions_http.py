#!/usr/bin/env python3
"""Build a mixed-parameter fork using an isolated running server and isolated data directory."""
import json, os, sys, urllib.request, uuid
from pathlib import Path
from fsrs import Scheduler
url = os.getenv('VOCAB_TEST_BASE', 'http://127.0.0.1:18765')
out, test_data = Path(sys.argv[1]), Path(sys.argv[2]).resolve()

def request(path, data=None, token=None, method=None):
    headers = {'Content-Type':'application/json'}
    if token: headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(url+path, json.dumps(data).encode() if data is not None else None, headers, method=method)
    with urllib.request.urlopen(req, timeout=15) as response: return json.load(response)

user = request('/api/v1/auth/register', {'username':'vers_'+uuid.uuid4().hex[:8], 'password':'testing123456'})
token, uid = user['token'], user['user']['id']
optimizer = test_data / f"fsrs_optimal_account_{user['user']['account_id']}.json"
if optimizer.exists(): raise RuntimeError('refusing to replace existing optimizer data')
base = {'is_new':True, 'state':1, 'stability':0, 'difficulty':0, 'rating':3}
events = [{'id':'device-a-1', 'rating':3, 'at':'2026-10-20T00:00:00Z'},
          {'id':'device-b-1', 'rating':3, 'at':'2026-10-25T00:00:00Z'}]

def review(body, event, key=None):
    return request('/api/v1/fsrs/review', {**body,'rating':event['rating'],'now':event['at'],
                   'deterministic':True,'scheduler_key':key}, token)

def branch(event, response):
    fsrs = {k:response[k] for k in ('state','stability','difficulty','due','step','scheduled_days')}
    fsrs['lastReview'] = response['last_review']
    return {'v':1, 'cards':{'apple':{'fsrs':fsrs,'due':fsrs['due'],'appliedFsrs':[event['id']],
            'fsrsHistory':{'base':base,'events':[event],'schedulerKey':response['scheduler_key']}}},
            'log':[], 'pendingNew':[], 'settings':{}, 'pointer':1, 'frontier':0}

try:
    first = review(base, events[0])
    optimizer.write_text(json.dumps({'parameters':list(Scheduler().parameters),'desired_retention':0.80}))
    second = review(base, events[1])
    assert first['scheduler_key'] != second['scheduler_key']
    for event, response in zip(events, (first,second)):
        request('/api/v1/me/state',branch(event,response),token,'PUT')
    state = request('/api/v1/me/state',token=token)['state']
    pending = state['cards']['apple']['pendingFsrs']['events']
    assert [e['schedulerKey'] for e in pending] == [first['scheduler_key'],second['scheduler_key']]
    body = dict(base)
    for event in pending:
        expected = review(body,event,event['schedulerKey'])
        body = {k:expected[k] for k in ('state','stability','difficulty','due','step','last_review')}
    with out.open('w') as f: json.dump({'token':token,'uid':uid,'accountId':user['user']['account_id'],'state':state,'expected':expected}, f)
    os.chmod(out,0o600)
finally:
    optimizer.unlink(missing_ok=True)
print('PASS HTTP mixed-version fork, recorded snapshots and safe optimizer removal')
