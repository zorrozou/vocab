#!/usr/bin/env python3
"""Upgrade legacy personal data without letting a reused UID claim it again."""
import sqlite3
import json
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from fastapi import HTTPException
sys.path.insert(0, sys.argv[1] if len(sys.argv) > 1 else 'server')
from app import auth, main as m

with tempfile.TemporaryDirectory() as tmp:
    auth.USERS_DB = Path(tmp) / 'users.db'
    m.PERSONAL_DB = Path(tmp) / 'personal.db'
    m.DATA_DIR = Path(tmp)
    old_body = m.PersonalizeIn(device='u7', date='2026-10-27', weak_words=['apple'], sync=True, request_id='old-job-123')
    with sqlite3.connect(auth.USERS_DB) as db:
        db.execute('CREATE TABLE users(id INTEGER PRIMARY KEY, username TEXT UNIQUE COLLATE NOCASE, nickname TEXT, password_hash TEXT, salt TEXT, created_at REAL, last_login_at REAL)')
        db.execute("INSERT INTO users VALUES(7,'alice','Alice','hash','salt',0,0)")
        db.execute('CREATE TABLE user_state(user_id INTEGER PRIMARY KEY, state_json TEXT, updated_at REAL)')
        db.execute('CREATE TABLE user_state_backups(id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, state_json TEXT NOT NULL, created_at REAL NOT NULL, reason TEXT NOT NULL)')
        db.execute("INSERT INTO user_state VALUES(7,'{\"cards\":{\"apple\":{}}}',123)")
        db.execute("INSERT INTO user_state_backups VALUES(3,7,'{\"cards\":{\"banana\":{}}}',122,'before_restore')")
    with sqlite3.connect(m.PERSONAL_DB) as db:
        db.execute('CREATE TABLE requests(device TEXT, date TEXT, payload TEXT, created REAL, processed INTEGER DEFAULT 0)')
        db.execute("CREATE TABLE sentences(device TEXT, date TEXT, target TEXT, recall TEXT, text TEXT, created REAL, zh TEXT DEFAULT '')")
        db.execute('CREATE TABLE personal_jobs(id TEXT PRIMARY KEY, device TEXT NOT NULL, date TEXT NOT NULL, payload TEXT NOT NULL, status TEXT NOT NULL, created REAL NOT NULL, updated REAL NOT NULL, error TEXT, lease_owner TEXT, lease_until REAL)')
        db.execute('CREATE TABLE fsrs_scheduler_versions(owner TEXT NOT NULL, scheduler_key TEXT NOT NULL, config_json TEXT NOT NULL, created REAL NOT NULL, PRIMARY KEY(owner,scheduler_key))')
        config = m.fsrs_scheduler_config(m._FsrsScheduler(desired_retention=.81))
        key = m.fsrs_config_key(config)
        db.execute('INSERT INTO fsrs_scheduler_versions VALUES(?,?,?,?)', ('user:7', key, json.dumps(config), time.time()))
        (m.DATA_DIR / 'fsrs_optimal_uid7.json').write_text(json.dumps({'parameters':config['parameters'], 'desired_retention':.81}))
        db.execute("INSERT INTO requests VALUES('u7','2026-10-27',?,?,0)", (old_body.model_dump_json(), time.time()))
        db.execute("INSERT INTO sentences VALUES('u7','2026-10-27','apple','','old personal',?,'')", (time.time(),))
        db.execute("INSERT INTO personal_jobs VALUES('old-job-123','u7','2026-10-27',?,'complete',?,?,NULL,NULL,NULL)", (old_body.model_dump_json(), time.time(), time.time()))
    auth.init_users()
    with sqlite3.connect(auth.USERS_DB) as db:
        old_id = db.execute('SELECT account_id FROM users WHERE id=7').fetchone()[0]
        old_token = auth.make_token(db, 7)
        assert json.loads(db.execute('SELECT state_json FROM account_state WHERE account_id=?', (old_id,)).fetchone()[0])['cards'] == {'apple': {}}
        assert db.execute('SELECT id FROM account_state_backups WHERE account_id=?', (old_id,)).fetchone()[0] == 3
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(lambda _: m.init_db(), range(4)))
    assert m.personal_owner('ignored', 'Bearer ' + old_token) == 'account:' + old_id
    assert m.fsrs_for_user(7, old_id).desired_retention == .81
    assert m.personalize(old_body.model_copy(), authorization='Bearer ' + old_token)['status'] == 'complete'
    with sqlite3.connect(m.PERSONAL_DB) as db:
        for table in ('requests', 'sentences', 'personal_jobs'):
            assert db.execute('SELECT device FROM ' + table).fetchone()[0] == 'account:' + old_id
        assert db.execute('SELECT 1 FROM fsrs_scheduler_versions WHERE owner=? AND scheduler_key=?', ('account:' + old_id, key)).fetchone()
    # Simulate a database restored or recreated with the same numeric ID and name.
    with sqlite3.connect(auth.USERS_DB) as db:
        db.execute('DELETE FROM users WHERE id=7')
        db.execute("INSERT INTO users(id,username,account_id,legacy_personal) VALUES(7,'alice',?,1)", ('f' * 32,))
        new_token = auth.make_token(db, 7)
    m.init_db()
    assert auth.user_by_token('Bearer ' + old_token) is None
    assert m.personal_owner('ignored', 'Bearer ' + new_token) == 'account:' + 'f' * 32
    assert m.fsrs_for_user(7, 'f' * 32).desired_retention == m.FSRS.desired_retention
    try:
        m.personalized_job(job_id='old-job-123', device='ignored', authorization='Bearer ' + new_token)
        raise AssertionError('new identity read old job')
    except HTTPException as error:
        assert error.status_code == 404
    with sqlite3.connect(m.PERSONAL_DB) as db:
        assert db.execute('SELECT device FROM personal_jobs').fetchone()[0] == 'account:' + old_id
        assert db.execute('SELECT account_id FROM legacy_personal_bindings WHERE user_id=7').fetchone()[0] == old_id
        assert not db.execute('SELECT 1 FROM fsrs_scheduler_versions WHERE owner=? AND scheduler_key=?', ('account:' + 'f' * 32, key)).fetchone()
    with sqlite3.connect(auth.USERS_DB) as db:
        assert not db.execute('SELECT 1 FROM account_state WHERE account_id=?', ('f' * 32,)).fetchone()
        assert not db.execute('SELECT 1 FROM account_state_backups WHERE account_id=?', ('f' * 32,)).fetchone()
print('PASS legacy personal data migrates atomically and cannot be reclaimed by a reused account ID')
