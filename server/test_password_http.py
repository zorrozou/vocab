"""Verify legacy password migration through a disposable loopback fixture."""
import json, urllib.error, urllib.request, uuid

base = 'http://127.0.0.1:18765'
def call(path, body=None, token=None, method=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    request = urllib.request.Request(base + path, None if body is None else json.dumps(body).encode(), headers, method=method)
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.load(response)

assert call('/api/v1/__ui_fixture')['fixture'] == 'vocab-ui-isolated-v1'
username = 'legacy_' + uuid.uuid4().hex[:8]
password = 'test_password_123'
account = call('/api/v1/auth/register', {'username': username, 'password': password})
token = account['token']
state = {'v': 1, 'cards': {'apple': {'pos': 1}}, 'log': [], 'pendingNew': [], 'settings': {}}
call('/api/v1/me/state', state, token, 'PUT')
call('/api/v1/__ui_fixture/password-legacy', {'token': token})
assert call('/api/v1/__ui_fixture/password-status', token=token)['scheme'] == 'legacy'
try:
    call('/api/v1/auth/login', {'username': username, 'password': 'wrong'})
except urllib.error.HTTPError as error:
    assert error.code == 401
else:
    raise AssertionError('wrong password accepted')
assert call('/api/v1/__ui_fixture/password-status', token=token)['scheme'] == 'legacy'
new = call('/api/v1/auth/login', {'username': username.upper(), 'password': password})
assert new['user']['account_id'] == account['user']['account_id']
assert call('/api/v1/me/state', token=new['token'])['state']['cards'] == state['cards']
assert call('/api/v1/me/state', token=token)['state']['cards'] == state['cards']
assert call('/api/v1/__ui_fixture/password-status', token=token)['scheme'] == 'argon2id'
print('PASS legacy password HTTP migration preserves state, account identity and active sessions')
