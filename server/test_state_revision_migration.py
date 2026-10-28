#!/usr/bin/env python3
"""Migrate old account-state rows atomically, even with concurrent startup."""
import sqlite3
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from fastapi import HTTPException
from app import auth

with tempfile.TemporaryDirectory(prefix='vocab-revision-migration-') as directory:
    auth.USERS_DB = Path(directory) / 'users.db'
    with sqlite3.connect(auth.USERS_DB) as db:
        db.execute('CREATE TABLE account_state(account_id TEXT PRIMARY KEY, state_json TEXT NOT NULL, updated_at REAL NOT NULL)')
        db.execute('INSERT INTO account_state VALUES(?,?,?)', ('a'*32, '{"cards":{"apple":{"pos":1}}}', 42.0))
        db.execute('CREATE TABLE account_state_snapshots(snapshot_id TEXT PRIMARY KEY, account_id TEXT NOT NULL, state_revision INTEGER NOT NULL, restore_epoch INTEGER NOT NULL, payload BLOB NOT NULL, digest TEXT NOT NULL, created_at REAL NOT NULL, expires_at REAL NOT NULL)')
        db.execute('INSERT INTO account_state_snapshots VALUES(?,?,?,?,?,?,?,?)', ('b'*32, 'a'*32, 1, 0, b'old', 'digest', 1, 9999999999))
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(lambda _: auth.init_users(), range(4)))
    with sqlite3.connect(auth.USERS_DB) as db:
        row = db.execute('SELECT state_json,updated_at,state_revision FROM account_state WHERE account_id=?', ('a'*32,)).fetchone()
        assert row == ('{"cards":{"apple":{"pos":1}}}', 42.0, 1)
        assert [r[1] for r in db.execute('PRAGMA table_info(account_state)')].count('state_revision') == 1
        assert [r[1] for r in db.execute('PRAGMA table_info(account_state_snapshots)')].count('request_key') == 1
        assert [r[1] for r in db.execute('PRAGMA table_info(account_state_snapshots)')].count('retired') == 1
        assert [r[1] for r in db.execute('PRAGMA table_info(account_state_snapshots)')].count('representation') == 1
        assert db.execute('SELECT payload,request_key FROM account_state_snapshots').fetchone() == (b'old', None)
        assert db.execute('SELECT representation FROM account_state_snapshots').fetchone() == ('enriched',)
        generation = db.execute('SELECT generation FROM sync_metadata WHERE id=1').fetchone()[0]
        assert len(generation) == 32 and all(c in '0123456789abcdef' for c in generation)
    auth.init_users()
    with sqlite3.connect(auth.USERS_DB) as db:
        assert db.execute('SELECT state_revision FROM account_state').fetchone() == (1,)
        assert db.execute('SELECT generation FROM sync_metadata WHERE id=1').fetchone()[0] == generation
    for invalid in (0, -1, True, 2**63-1, '1'):
        try: auth.next_state_revision(invalid)
        except HTTPException as exc: assert exc.status_code == 409
        else: raise AssertionError(f'invalid revision accepted: {invalid!r}')
    assert auth.next_state_revision(2**53) == 2**53 + 1
print('PASS concurrent stored-state revision migration, preservation and overflow checks')
