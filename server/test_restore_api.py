#!/usr/bin/env python3
"""Run against an isolated test server; creates and restores disposable accounts."""
import json, urllib.error, urllib.request, uuid
BASE = 'http://127.0.0.1:18765'
def call(path, body=None, token=None, method=None):
    headers = {'Content-Type': 'application/json'}
    if token: headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(BASE + path, json.dumps(body).encode() if body is not None else None,
                                 headers, method=method)
    with urllib.request.urlopen(req, timeout=15) as r: return json.load(r)
def expect(code, path, body, token, method=None):
    try:
        call(path, body, token, method)
        raise AssertionError('request unexpectedly succeeded')
    except urllib.error.HTTPError as e:
        assert e.code == code, e.code

def register():
    return call('/api/v1/auth/register', {'username':'restore_' + uuid.uuid4().hex[:8], 'password':'test_password_123'})['token']
def state(word):
    return {'v':1,'cards':{word:{'pos':1}},'log':[],'pendingNew':[],'settings':{'newPerDay':10}}
owner, other = register(), register()
call('/api/v1/me/state', state('apple'), owner, 'PUT')
old = call('/api/v1/me/state', token=owner)
call('/api/v1/me/state', state('banana'), owner, 'PUT')
new = call('/api/v1/me/state', token=owner)
assert new['updated_at'] > old['updated_at']
expect(409, '/api/v1/me/state/restore', {'state':state('cherry'),'expected_updated_at':old['updated_at']}, owner)
assert call('/api/v1/me/state/backups', token=owner)['backups'] == []
expect(422, '/api/v1/me/state/restore', {'state':{'cards':[]},'expected_updated_at':new['updated_at']}, owner)
restored = call('/api/v1/me/state/restore', {'state':state('cherry'),'expected_updated_at':new['updated_at']}, owner)
assert restored['state']['restoreEpoch'] == 1 and set(restored['state']['cards']) == {'cherry'}
backup_id = call('/api/v1/me/state/backups', token=owner)['backups'][0]['id']
backup = call('/api/v1/me/state/backups/' + str(backup_id), token=owner)['state']
assert set(backup['cards']) == {'apple','banana'}
try:
    call('/api/v1/me/state/backups/' + str(backup_id), token=other)
    raise AssertionError('other user read backup')
except urllib.error.HTTPError as e: assert e.code == 404
expect(409, '/api/v1/me/state', state('apple'), owner, 'PUT')
assert set(call('/api/v1/me/state', token=owner)['state']['cards']) == {'cherry'}
current = restored['state']; current['cards']['date'] = {'pos':2}
call('/api/v1/me/state', current, owner, 'PUT')
assert set(call('/api/v1/me/state', token=owner)['state']['cards']) == {'cherry','date'}
print('PASS restore CAS, archived prior state, owner isolation and stale-device protection')
