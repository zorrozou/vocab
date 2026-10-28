#!/usr/bin/env python3
"""A verified state backup can restore its FSRS versions to a different account."""
import copy, json, sqlite3, sys, tempfile
from pathlib import Path
from fastapi import HTTPException
sys.path.insert(0, sys.argv[1] if len(sys.argv) > 1 else 'server')
from app import auth, main as m

with tempfile.TemporaryDirectory() as temp:
    m.PERSONAL_DB = Path(temp) / 'personal.db'
    auth.USERS_DB = Path(temp) / 'users.db'
    auth.init_users(); m.init_db()
    default = m._FsrsScheduler()
    optimized = m._FsrsScheduler(desired_retention=.82)
    m.fsrs_for_user = lambda uid, account_id: optimized if uid == 1 else default
    m.identity_by_token = lambda token: {'one':(1,'a'*32), 'two':(2,'b'*32), 'three':(3,'c'*32)}.get(token)
    req = m.FsrsIn(is_new=True, rating=3, now='2026-10-20T00:00:00Z', deterministic=True)
    first = m.fsrs_review(req, authorization='one')
    key, config = first['scheduler_key'], first['scheduler_config']
    backup = {'v':1, 'cards':{}, 'log':[], 'pendingNew':[], 'settings':{}, 'fsrsSchedulers':{key:config}}
    auth.validate_restore_state(backup)
    stale = {'v':1, 'cards':{}, 'log':[], 'pendingNew':[], 'settings':{}}
    assert key in auth.merge_learning_states(backup, stale)['fsrsSchedulers']
    assert key in auth.merge_learning_states(stale, backup)['fsrsSchedulers']
    with sqlite3.connect(auth.USERS_DB) as conn:
        conn.execute('INSERT INTO account_state(account_id,state_json,updated_at) VALUES(?,?,?)', ('b'*32,json.dumps(backup),1))
    restored = m.fsrs_review(req.model_copy(update={'scheduler_key':key}), authorization='two')
    assert restored == first
    with sqlite3.connect(m.PERSONAL_DB) as conn:
        assert conn.execute('SELECT 1 FROM fsrs_scheduler_versions WHERE owner=? AND scheduler_key=?', ('account:' + 'b'*32,key)).fetchone()
    # No access to another owner's snapshots without an explicit imported backup.
    try:
        m.fsrs_review(req.model_copy(update={'scheduler_key':key}), authorization='three')
        raise AssertionError('other user accessed an unimported snapshot')
    except HTTPException as e:
        assert e.status_code == 409
    damaged = copy.deepcopy(backup)
    damaged['fsrsSchedulers'][key]['desired_retention'] = .7
    try:
        auth.validate_restore_state(damaged)
        raise AssertionError('tampered backup accepted')
    except HTTPException as e:
        assert e.status_code == 422
    # JavaScript serializes integral floating-point values as integers; hashes remain stable.
    integral = copy.deepcopy(config)
    for field in ('parameters','learning_steps','relearning_steps'):
        integral[field] = [int(v) if float(v).is_integer() else v for v in integral[field]]
    assert m.fsrs_config_key(integral) == key
print('PASS portable scheduler backup, owner isolation, stale merges, integrity and cross-language numbers')
