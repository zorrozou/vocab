#!/usr/bin/env python3
"""Quota rejection and physical cleanup against an isolated HTTP fixture."""
import json, os, urllib.error, urllib.request, uuid

BASE = os.environ.get('VOCAB_TEST_BASE', 'http://127.0.0.1:18765').rstrip('/')
def call(path, body, token=None, key=None, method='POST'):
    headers = {'Content-Type':'application/json'}
    if token: headers['Authorization'] = 'Bearer ' + token
    if key: headers['Idempotency-Key'] = key
    req = urllib.request.Request(BASE + path, None if body is None else json.dumps(body).encode(), headers, method=method)
    with urllib.request.urlopen(req, timeout=45) as response: return json.load(response)
def reject(status, path, body, token=None):
    try: call(path, body, token)
    except urllib.error.HTTPError as error: assert error.code == status, (error.code, status)
    else: raise AssertionError('request unexpectedly succeeded')
def register():
    return call('/api/v1/auth/register', {'username':'limit_'+uuid.uuid4().hex[:10], 'password':'test_password_123'})['token']
def create(token): return call('/api/v1/me/state/snapshots', {}, token)
def count(token): return call('/api/v1/__ui_fixture/snapshot-count', {'token':token})['count']
def expire(token, snap): call('/api/v1/__ui_fixture/snapshot-expire', {'token':token, 'snapshot_id':snap['snapshot_id']})

first, full, third = register(), register(), register()
expired = create(first)
for _ in range(3): create(full)
expire(first, expired)
reject(429, '/api/v1/me/state/snapshots', {}, full)
assert count(first) == 0  # Cleanup commits even when account quota rejects.
expired = create(first)
expire(first, expired)
call('/api/v1/__ui_fixture/snapshot-limits', {'global_bytes':0})
reject(503, '/api/v1/me/state/snapshots', {}, third)
assert count(first) == 0 and count(third) == 0
call('/api/v1/__ui_fixture/snapshot-limits', {'max_bytes':1})
reject(413, '/api/v1/me/state/snapshots', {}, third)
assert count(third) == 0
call('/api/v1/__ui_fixture/snapshot-limits', {'max_bytes':1024, 'global_bytes':1024*1024, 'max_keys':2})
for _ in range(2):
    snapshot = call('/api/v1/me/state/snapshots', {}, third, uuid.uuid4().hex)
    call('/api/v1/me/state/snapshots/' + snapshot['snapshot_id'], None, third, method='DELETE')
try:
    call('/api/v1/me/state/snapshots', {}, third, uuid.uuid4().hex)
except urllib.error.HTTPError as error:
    assert error.code == 429
else:
    raise AssertionError('retired request keys bypassed quota')
assert create(third)['snapshot_id']  # Retired records do not consume the live snapshot quota.
print('PASS snapshot size, global and retired-key quotas; expired cleanup survives 429 and 503')
