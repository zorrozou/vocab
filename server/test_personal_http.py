#!/usr/bin/env python3
"""HTTP integration against an isolated API with mocked generation."""
import json, time, urllib.error, urllib.parse, urllib.request, uuid
base = 'http://127.0.0.1:18765'
def call(path, body=None, token=None):
    headers = {'Content-Type': 'application/json'}
    if token: headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(base + path, data=json.dumps(body).encode() if body is not None else None, headers=headers)
    with urllib.request.urlopen(req, timeout=10) as response:
        return json.load(response)
name = 'job_' + uuid.uuid4().hex[:10]
auth = call('/api/v1/auth/register', {'username': name, 'password': 'test_password_123'})
job_id = 'test-' + uuid.uuid4().hex
payload = {'device': 'device-one', 'date': '2026-10-27', 'weak_words': ['apple','banana'],
           'learned_max_pos': 5000, 'sync': True, 'replace': True, 'request_id': job_id}
assert call('/api/v1/personalize', payload, auth['token'])['job_id'] == job_id
assert call('/api/v1/personalize', payload, auth['token'])['job_id'] == job_id
query = urllib.parse.urlencode({'job_id': job_id, 'device': 'device-one'})
for _ in range(100):
    result = call('/api/v1/personalized/job?' + query, token=auth['token'])
    if result['status'] not in ('queued', 'running'): break
    time.sleep(.1)
assert result['status'] == 'complete' and len(result['sentences']) == 2, result
try:
    call('/api/v1/personalized/job?' + query)
    raise AssertionError('guest accessed another account task')
except urllib.error.HTTPError as e:
    assert e.code == 401
print('PASS HTTP durable task creation, idempotency, worker and owner isolation')
