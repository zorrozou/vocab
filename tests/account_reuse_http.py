#!/usr/bin/env python3
"""Verify same numeric ID cannot reclaim state, backups, snapshots or optimizer parameters.
Run ONLY against the disposable API and provide its data directory explicitly.
"""
import json, sqlite3, sys, urllib.error, urllib.request, uuid
from pathlib import Path
from fsrs import Scheduler
base = 'http://127.0.0.1:18765'
data = Path(sys.argv[1]).resolve()
name = 'reuse_' + uuid.uuid4().hex[:9]
def request(path, body=None, token=None, method=None):
    headers = {'Content-Type':'application/json'}
    if token: headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(base + path, None if body is None else json.dumps(body).encode(), headers, method=method)
    with urllib.request.urlopen(req, timeout=15) as response: return json.load(response)
a = request('/api/v1/auth/register', {'username':name,'password':'testing123456'})
uid, aid, token = a['user']['id'], a['user']['account_id'], a['token']
legacy_file = data / f'fsrs_optimal_uid{uid}.json'
account_file = data / f'fsrs_optimal_account_{aid}.json'
if legacy_file.exists() or account_file.exists(): raise RuntimeError('refusing to overwrite parameter file')
try:
    custom = {'parameters':list(Scheduler().parameters),'desired_retention':.81}
    account_file.write_text(json.dumps(custom))
    first = request('/api/v1/fsrs/review', {'is_new':True,'rating':3,'deterministic':True}, token)
    key = first['scheduler_key']
    state = {'v':1,'cards':{'apple':{'pos':1}},'log':[], 'pendingNew':[], 'settings':{}}
    request('/api/v1/me/state', state, token, 'PUT')
    old = request('/api/v1/me/state', token=token)
    request('/api/v1/me/state/restore', {'state':state,'expected_updated_at':old['updated_at']}, token)
    assert request('/api/v1/me/state/backups', token=token)['backups']
    # Change only this disposable account to model a replacement with the exact same numeric ID/name.
    replacement = uuid.uuid4().hex
    with sqlite3.connect(data / 'users.db') as db:
        assert db.execute('UPDATE users SET account_id=? WHERE id=? AND account_id=?', (replacement,uid,aid)).rowcount == 1
    b = request('/api/v1/auth/login', {'username':name,'password':'testing123456'})
    new_token = b['token']
    assert b['user']['id'] == uid and b['user']['account_id'] == replacement
    assert request('/api/v1/me/state', token=new_token)['state'] is None
    assert request('/api/v1/me/state/backups', token=new_token)['backups'] == []
    assert key not in request('/api/v1/me/fsrs-schedulers', token=new_token)['versions']
    # An unrelated legacy UID optimizer must not be applied to the replacement account.
    legacy_file.write_text(json.dumps(custom))
    new = request('/api/v1/fsrs/review', {'is_new':True,'rating':3,'deterministic':True}, new_token)
    assert new['scheduler_key'] != key
    try:
        request('/api/v1/fsrs/review', {'is_new':True,'rating':3,'scheduler_key':key}, new_token)
        raise AssertionError('replacement account accessed old snapshot')
    except urllib.error.HTTPError as error: assert error.code == 409
    try:
        request('/api/v1/me/state', token=token)
        raise AssertionError('old token still works')
    except urllib.error.HTTPError as error: assert error.code == 401
    print('PASS HTTP same-ID replacement cannot read state, backups, snapshots or UID optimizer')
finally:
    legacy_file.unlink(missing_ok=True)
    account_file.unlink(missing_ok=True)
