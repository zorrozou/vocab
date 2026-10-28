#!/usr/bin/env python3
"""Exercise the byte limit only against an isolated test server and database."""
import json
import os
import urllib.error
import urllib.request
import uuid

BASE = os.environ.get('VOCAB_TEST_BASE', 'http://127.0.0.1:18765').rstrip('/')

def call(path, body=None, token=None, method=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    payload = json.dumps(body, ensure_ascii=False).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=payload, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=45) as resp:
        return json.load(resp)

auth = call('/api/v1/auth/register', {'username': 'cap_' + uuid.uuid4().hex[:10],
                                      'password': 'test_password_123'})
token = auth['token']
def state(cards):
    return {'cards': cards, 'log': [], 'pendingNew': [], 'frontier': 1, 'pointer': 1, 'probeCount': 0}
def put(s):
    return call('/api/v1/me/state', s, token=token, method='PUT')
def expect_413(s):
    try:
        put(s)
        raise AssertionError('oversized state accepted')
    except urllib.error.HTTPError as e:
        assert e.code == 413, e.code

# Well beyond the old proxy's 64 KiB, but below the new byte limit.
payload = 'a' * (4 * 1024 * 1024 + 300000)
put(state({'apple': {'extra': payload}}))
assert call('/api/v1/me/state', token=token)['state']['cards']['apple']['extra'] == payload
# Two individually permitted states can exceed the cap after the merge.
expect_413(state({'banana': {'extra': payload}}))
after = call('/api/v1/me/state', token=token)['state']
assert set(after['cards']) == {'apple'} and after['cards']['apple']['extra'] == payload
expect_413(state({'oversize': {'extra': 'b' * (9 * 1024 * 1024)}}))
assert set(call('/api/v1/me/state', token=token)['state']['cards']) == {'apple'}
print('PASS large state, merged-size rejection and transactional preservation')
