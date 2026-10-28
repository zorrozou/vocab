#!/usr/bin/env python3
"""Run against an isolated server; retries must not repeat a committed restore."""
import concurrent.futures, copy, json, urllib.error, urllib.request, uuid
BASE = 'http://127.0.0.1:18765'
def call(path, body=None, token=None, method=None):
    headers = {'Content-Type':'application/json'}
    if token: headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(BASE + path, json.dumps(body).encode() if body is not None else None, headers, method=method)
    with urllib.request.urlopen(req, timeout=15) as r: return json.load(r)
def expect(code, path, body, token):
    try: call(path, body, token)
    except urllib.error.HTTPError as e:
        assert e.code == code, e.code
        return
    raise AssertionError('request unexpectedly succeeded')
def register():
    return call('/api/v1/auth/register', {'username':'receipt_'+uuid.uuid4().hex[:8], 'password':'test_password_123'})['token']
def state(word): return {'v':1,'cards':{word:{'pos':1}},'log':[],'pendingNew':[],'settings':{'newPerDay':10}}
owner, other = register(), register()
call('/api/v1/me/state', state('apple'), owner, 'PUT')
old = call('/api/v1/me/state', token=owner)
path = '/api/v1/me/state/guarded-restore-idempotent'
body = {'state':state('cherry'), 'expected_updated_at':old['updated_at'], 'generation':old['sync_generation'],
        'state_revision':old['state_revision'], 'batch_id':uuid.uuid4().hex}
call('/api/v1/__ui_fixture/guarded-restore-receipt-failure', {'enabled':True})
expect(500, path, body, owner)
after_failure = call('/api/v1/me/state', token=owner)
assert after_failure['state_revision'] == old['state_revision'] and after_failure['state'] == old['state']
assert not call('/api/v1/me/state/backups', token=owner)['backups']
call('/api/v1/__ui_fixture/guarded-restore-receipt-failure', {'enabled':False})
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    results = list(pool.map(lambda _: call(path, body, owner), range(4)))
assert all(result == results[0] for result in results)
assert results[0]['state']['restoreEpoch'] == 1
assert len(call('/api/v1/me/state/backups', token=owner)['backups']) == 1
current = call('/api/v1/me/state', token=owner)
assert current['state_revision'] == results[0]['state_revision']
changed = copy.deepcopy(body); changed['state'] = state('different')
expect(409, path, changed, owner)
expect(409, path, body, other)
next_state = copy.deepcopy(results[0]['state']); next_state['cards']['date'] = {'pos':2}
call('/api/v1/me/state', next_state, owner, 'PUT')
assert call(path, body, owner) == results[0]
assert 'date' in call('/api/v1/me/state', token=owner)['state']['cards']
invalid = copy.deepcopy(body); invalid['batch_id'] = 'bad'
expect(422, path, invalid, owner)
call('/api/v1/__ui_fixture/corrupt-guarded-restore-receipt', {'token':owner,'batch_id':body['batch_id']})
expect(409, path, body, owner)
assert 'date' in call('/api/v1/me/state', token=owner)['state']['cards']
call('/api/v1/__ui_fixture/reset-sync-generation', {})
expect(409, path, body, owner)
print('PASS guarded restore receipt rollback, retries, conflict, isolation, corruption and generation fence')
