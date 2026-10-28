#!/usr/bin/env python3
"""Create two independent FSRS branches and merge them on an isolated server."""
import json, os, sys, urllib.request, uuid
url = os.getenv('VOCAB_TEST_BASE', 'http://127.0.0.1:18765')
output = sys.argv[1]

def request(path, data=None, token=None, method=None):
    headers = {'Content-Type': 'application/json'}
    if token: headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(url + path, json.dumps(data).encode() if data is not None else None, headers, method=method)
    with urllib.request.urlopen(req, timeout=15) as res: return json.load(res)

user = request('/api/v1/auth/register', {'username': 'fork_' + uuid.uuid4().hex[:8], 'password': 'testing123456'})
token = user['token']
base = {'is_new': True, 'state': 1, 'stability': 0, 'difficulty': 0, 'rating': 3}
events = [{'id':'device-a-1', 'rating':3, 'at':'2026-10-20T00:00:00Z'},
          {'id':'device-b-1', 'rating':1, 'at':'2026-10-21T00:00:00Z'}]
def replay(events):
    body = dict(base); key = None
    for e in events:
        result = request('/api/v1/fsrs/review', {**body, 'rating':e['rating'], 'now':e['at'], 'deterministic':True, 'scheduler_key':key}, token)
        key = result['scheduler_key']
        body = {k:result[k] for k in ('state','stability','difficulty','due','step','last_review')}
    return result

def branch(event):
    r = replay([event]); fsrs = {k:r[k] for k in ('state','stability','difficulty','due','step','scheduled_days')}
    fsrs['lastReview'] = r['last_review']
    return {'v':1, 'cards':{'apple':{'fsrs':fsrs,'due':fsrs['due'],'appliedFsrs':[event['id']],
            'fsrsHistory':{'base':base,'events':[event],'schedulerKey':r['scheduler_key']}}},
            'log':[], 'pendingNew':[], 'settings':{}, 'pointer':1, 'frontier':0}

for e in events: request('/api/v1/me/state', branch(e), token, 'PUT')
state = request('/api/v1/me/state', token=token)['state']
assert [e['id'] for e in state['cards']['apple']['pendingFsrs']['events']] == [e['id'] for e in events]
expected = replay(events)
with open(output, 'w') as f: json.dump({'token':token,'state':state,'expected':expected}, f)
os.chmod(output, 0o600)
print('PASS HTTP isolated account merges two independent rating histories')
