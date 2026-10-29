#!/usr/bin/env python3
"""Run only against a fresh isolated API with mocked generation."""
import json, os, urllib.error, urllib.request, uuid
base = os.environ.get('VOCAB_TEST_BASE', 'http://127.0.0.1:18765').rstrip('/')
guest_token = None
def post(path, body):
    headers = {'Content-Type':'application/json'}
    if path == '/api/v1/personalize' and guest_token: headers['X-Guest-Token'] = guest_token
    req = urllib.request.Request(base + path, json.dumps(body).encode(), headers)
    with urllib.request.urlopen(req, timeout=10) as r: return json.load(r)
def should_limit(path, body):
    try:
        post(path, body)
        raise AssertionError('expected HTTP 429')
    except urllib.error.HTTPError as e:
        assert e.code == 429 and int(e.headers['Retry-After']) > 0
guest_token = post('/api/v1/auth/guest', {})['token']
prefix = uuid.uuid4().hex
body = {'device':'rate-test-secret', 'date':'2026-10-27', 'weak_words':['apple'], 'sync':True,
        'request_id': prefix + '-0'}
post('/api/v1/personalize', body)
for _ in range(10): post('/api/v1/personalize', body) # idempotent polling is free
for i in range(1, 6): post('/api/v1/personalize', {**body, 'request_id':prefix + '-' + str(i)})
should_limit('/api/v1/personalize', {**body, 'request_id':prefix + '-6'})
for _ in range(19): # Issuing the guest credential consumed one auth request.
    try: post('/api/v1/auth/login', {'username':'unknown-user', 'password':'not-a-password'})
    except urllib.error.HTTPError as e: assert e.code == 401
should_limit('/api/v1/auth/login', {'username':'unknown-user', 'password':'not-a-password'})
print('PASS HTTP auth and generation limits; repeated task IDs do not consume creation quota')
