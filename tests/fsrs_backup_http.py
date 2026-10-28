#!/usr/bin/env python3
"""Verify an exported state restores recorded scheduler versions for another account."""
import copy, json, os, sqlite3, sys, urllib.error, urllib.request, uuid
from pathlib import Path
url = os.getenv('VOCAB_TEST_BASE','http://127.0.0.1:18765')
fixture = json.load(open(sys.argv[1]))

def request(path, data=None, token=None, method=None):
    headers = {'Content-Type':'application/json'}
    if token: headers['Authorization'] = 'Bearer '+token
    req = urllib.request.Request(url+path, json.dumps(data).encode() if data is not None else None, headers, method=method)
    with urllib.request.urlopen(req, timeout=15) as response: return json.load(response)

def register():
    return request('/api/v1/auth/register',{'username':'bak_'+uuid.uuid4().hex[:8], 'password':'testing123456'})['token']

source = request('/api/v1/me/state', token=fixture['token'])['state']
if len(sys.argv) > 2:
    # Explicit isolated DB only: simulate an older stored state predating embedded snapshots.
    users_db = Path(sys.argv[2]) / 'users.db'
    with sqlite3.connect(users_db) as conn:
        raw = conn.execute('SELECT state_json FROM account_state WHERE account_id=(SELECT account_id FROM users WHERE id=?)', (fixture['uid'],)).fetchone()[0]
        old = json.loads(raw); old.pop('fsrsSchedulers', None)
        conn.execute('UPDATE account_state SET state_json=? WHERE account_id=(SELECT account_id FROM users WHERE id=?)', (json.dumps(old), fixture['uid']))
    source = request('/api/v1/me/state', token=fixture['token'])['state']
    assert source.get('fsrsSchedulers'), 'older state should be enriched from this account’s verified snapshots'
events = source['cards']['apple']['fsrsHistory']['events']
key = events[-1]['schedulerKey']
assert key in source['fsrsSchedulers']
destination, other = register(), register()
snapshots = request('/api/v1/me/fsrs-schedulers', token=fixture['token'])['versions']
assert key in snapshots and snapshots[key] == source['fsrsSchedulers'][key]
try:
    request('/api/v1/me/fsrs-schedulers')
    raise AssertionError('unauthenticated scheduler export accepted')
except urllib.error.HTTPError as e:
    assert e.code == 401
result = request('/api/v1/me/state/restore', {'state':source, 'expected_updated_at':None}, destination)
assert key in result['state']['fsrsSchedulers']
body = {'is_new':True, 'rating':3, 'now':'2026-10-25T00:00:00Z', 'deterministic':True, 'scheduler_key':key}
restored = request('/api/v1/fsrs/review',body,destination)
assert restored['scheduler_key'] == key and restored['scheduler_config'] == source['fsrsSchedulers'][key]
try:
    request('/api/v1/fsrs/review',body,other)
    raise AssertionError('another account accessed a non-imported snapshot')
except urllib.error.HTTPError as e:
    assert e.code == 409
# Merely mentioning another owner's version does not expose its snapshot on pull.
without_snapshots = copy.deepcopy(source)
without_snapshots.pop('fsrsSchedulers', None)
request('/api/v1/me/state', without_snapshots, other, 'PUT')
other_state = request('/api/v1/me/state', token=other)['state']
assert key not in (other_state.get('fsrsSchedulers') or {})
other = register()  # use a fresh empty account for the tampered restore test
bad = copy.deepcopy(source)
bad['fsrsSchedulers'][key]['desired_retention'] = 0.7
try:
    request('/api/v1/me/state/restore', {'state':bad, 'expected_updated_at':None}, other)
    raise AssertionError('tampered snapshot was restored')
except urllib.error.HTTPError as e:
    assert e.code == 422
print('PASS HTTP backup restores scheduler snapshots, preserves account isolation and rejects tampering')
