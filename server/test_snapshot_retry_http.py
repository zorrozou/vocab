#!/usr/bin/env python3
"""Retry semantics for immutable snapshots against a disposable fixture."""
import json, os, urllib.error, urllib.request, uuid
from concurrent.futures import ThreadPoolExecutor

BASE = os.environ.get('VOCAB_TEST_BASE', 'http://127.0.0.1:18765').rstrip('/')
def call(path, method='GET', body=None, token=None, key=None):
    headers = {'Content-Type': 'application/json'}
    if token: headers['Authorization'] = 'Bearer ' + token
    if key is not None: headers['Idempotency-Key'] = key
    req = urllib.request.Request(BASE + path, None if body is None else json.dumps(body).encode(), headers, method=method)
    with urllib.request.urlopen(req, timeout=45) as response:
        return json.load(response)
def reject(status, *args, **kwargs):
    try: call(*args, **kwargs)
    except urllib.error.HTTPError as error: assert error.code == status, (error.code, status)
    else: raise AssertionError('request unexpectedly succeeded')
def register():
    return call('/api/v1/auth/register', 'POST', {'username':'retry_'+uuid.uuid4().hex[:10], 'password':'test_password_123'})['token']
def create(token, key): return call('/api/v1/me/state/snapshots', 'POST', {}, token, key)

owner, other = register(), register()
key = uuid.uuid4().hex
reject(422, '/api/v1/me/state/snapshots', 'POST', {}, owner, 'INVALID')
with ThreadPoolExecutor(max_workers=5) as pool:
    results = list(pool.map(lambda _: create(owner, key), range(5)))
assert all(item == results[0] for item in results), results
snapshot = results[0]
other_snapshot = create(other, key)
assert other_snapshot['snapshot_id'] != snapshot['snapshot_id']
state = {'v':1, 'cards':{'apple':{'pos':1}}, 'log':[], 'pendingNew':[], 'settings':{}}
call('/api/v1/me/state', 'PUT', state, owner)
assert create(owner, key) == snapshot  # Ordinary later writes do not change a retry's result.
current = call('/api/v1/me/state', token=owner)
call('/api/v1/me/state/checkpoint', 'POST', {'expected_updated_at':current['updated_at']}, owner)
reject(409, '/api/v1/me/state/snapshots', 'POST', {}, owner, key)
new_key = uuid.uuid4().hex
new = create(owner, new_key)
assert new['restore_epoch'] == 1
# Creation has cleaned the old epoch, but its key still fences delayed retries.
reject(409, '/api/v1/me/state/snapshots', 'POST', {}, owner, key)
call('/api/v1/me/state/snapshots/' + other_snapshot['snapshot_id'], 'DELETE', token=other)
reject(410, '/api/v1/me/state/snapshots', 'POST', {}, other, key)
reject(404, '/api/v1/me/state/snapshots/' + other_snapshot['snapshot_id'] + '?page=0', token=other)
call('/api/v1/__ui_fixture/snapshot-expire', 'POST', {'token':owner, 'snapshot_id':new['snapshot_id']})
reject(410, '/api/v1/me/state/snapshots', 'POST', {}, owner, new_key)
print('PASS concurrent idempotent snapshot retries, account isolation, immutable result, restore and deletion fencing and expiry')
