#!/usr/bin/env python3
"""Check the real HTTP authentication contract on the isolated server."""
import json
import urllib.request
import uuid

BASE = 'http://127.0.0.1:18765'
username = 'ident_' + uuid.uuid4().hex[:9]
def post(path, body):
    req = urllib.request.Request(BASE + path, json.dumps(body).encode(), {'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=15) as response:
        return json.load(response)
register = post('/api/v1/auth/register', {'username': username, 'password': 'test_password_123'})
login = post('/api/v1/auth/login', {'username': username.upper(), 'password': 'test_password_123'})
assert register['user']['account_id'] == login['user']['account_id']
assert len(register['user']['account_id']) == 32
assert register['user']['id'] == login['user']['id']
assert 0 < register['user']['id'] < 2 ** 52
print('PASS HTTP register and case-insensitive login return stable account identity and safe numeric ID')
from concurrent.futures import ThreadPoolExecutor
from urllib.error import HTTPError
name = 'race_' + uuid.uuid4().hex[:10]
def simultaneous(_):
    try:
        post('/api/v1/auth/register', {'username': name, 'password': 'test_password_123'})
        return 200
    except HTTPError as error:
        return error.code
with ThreadPoolExecutor(max_workers=6) as pool:
    results = list(pool.map(simultaneous, range(6)))
assert sorted(results) == [200, 409, 409, 409, 409, 409], results
print('PASS concurrent duplicate registration returns one success and five conflicts')
