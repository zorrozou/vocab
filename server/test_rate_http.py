#!/usr/bin/env python3
"""Run only against a fresh isolated API with mocked generation."""
import json, urllib.error, urllib.request, uuid
base = 'http://127.0.0.1:18765'
def post(path, body):
    req = urllib.request.Request(base + path, json.dumps(body).encode(), {'Content-Type':'application/json'})
    with urllib.request.urlopen(req, timeout=10) as r: return json.load(r)
def should_limit(path, body):
    try:
        post(path, body)
        raise AssertionError('expected HTTP 429')
    except urllib.error.HTTPError as e:
        assert e.code == 429 and int(e.headers['Retry-After']) > 0
prefix = uuid.uuid4().hex
body = {'device':'rate-test-secret', 'date':'2026-10-27', 'weak_words':['apple'], 'sync':True,
        'request_id': prefix + '-0'}
post('/api/v1/personalize', body)
for _ in range(10): post('/api/v1/personalize', body) # idempotent polling is free
for i in range(1, 6): post('/api/v1/personalize', {**body, 'request_id':prefix + '-' + str(i)})
should_limit('/api/v1/personalize', {**body, 'request_id':prefix + '-6'})
for _ in range(20):
    try: post('/api/v1/auth/login', {'username':'unknown-user', 'password':'not-a-password'})
    except urllib.error.HTTPError as e: assert e.code == 401
should_limit('/api/v1/auth/login', {'username':'unknown-user', 'password':'not-a-password'})
print('PASS HTTP auth and generation limits; repeated task IDs do not consume creation quota')
