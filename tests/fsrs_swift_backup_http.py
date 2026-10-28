#!/usr/bin/env python3
"""Restore a real Swift-encoded backup and replay its mixed scheduler versions."""
import json, os, sys, urllib.request, uuid
url = os.getenv('VOCAB_TEST_BASE','http://127.0.0.1:18765')
state = json.load(open(sys.argv[1])); fixture = json.load(open(sys.argv[2]))

def request(path, data=None, token=None):
    headers = {'Content-Type':'application/json'}
    if token: headers['Authorization'] = 'Bearer '+token
    req = urllib.request.Request(url+path, json.dumps(data).encode() if data is not None else None, headers)
    with urllib.request.urlopen(req, timeout=15) as response: return json.load(response)

token = request('/api/v1/auth/register', {'username':'swift_'+uuid.uuid4().hex[:8], 'password':'testing123456'})['token']
restored = request('/api/v1/me/state/restore', {'state':state,'expected_updated_at':None}, token)['state']
pending = restored['cards']['apple']['pendingFsrs']; body = pending['base']
for event in pending['events']:
    result = request('/api/v1/fsrs/review', {**body, 'rating':event['rating'], 'now':event['at'],
                    'deterministic':True, 'scheduler_key':event['schedulerKey']}, token)
    body = {k:result[k] for k in ('state','stability','difficulty','due','step','last_review')}
for field in ('state','stability','difficulty','due','step','last_review','scheduler_key'):
    assert result[field] == fixture['expected'][field]
print('PASS Swift-encoded backup restores and replays mixed versions through HTTP')
