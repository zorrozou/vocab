#!/usr/bin/env python3
"""Exercise legacy migration and token binding against disposable SQLite databases."""
import hashlib
import sqlite3
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from app import auth

with tempfile.TemporaryDirectory() as directory:
    auth.USERS_DB = Path(directory) / 'users.db'
    with sqlite3.connect(auth.USERS_DB) as db:
        db.execute('CREATE TABLE users(id INTEGER PRIMARY KEY, username TEXT UNIQUE COLLATE NOCASE, nickname TEXT, password_hash TEXT, salt TEXT, created_at REAL, last_login_at REAL)')
        db.execute('CREATE TABLE tokens(token_hash TEXT PRIMARY KEY, user_id INTEGER, expires_at REAL, revoked INTEGER DEFAULT 0)')
        db.execute("INSERT INTO users VALUES(7, 'alice', 'Alice', 'hash', 'salt', 0, 0)")
        for token, uid in [('legacy', 7), ('orphan', 8)]:
            db.execute('INSERT INTO tokens VALUES(?,?,?,0)', (hashlib.sha256(token.encode()).hexdigest(), uid, time.time() + 1000))
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(lambda _: auth.init_users(), range(4)))
    assert auth.user_by_token('Bearer legacy') == 7
    with sqlite3.connect(auth.USERS_DB) as db:
        original = db.execute('SELECT account_id FROM users WHERE id=7').fetchone()[0]
        assert len(original) == 32
        newer = auth.make_token(db, 7)
        db.execute('DELETE FROM users WHERE id=7')
        db.execute("INSERT INTO users(id,username,account_id) VALUES(7,'alice',?)", ('a' * 32,))
        db.execute("INSERT INTO users(id,username,account_id) VALUES(8,'bob',?)", ('b' * 32,))
    auth.init_users()
    assert auth.user_by_token('Bearer legacy') is None
    assert auth.user_by_token('Bearer ' + newer) is None
    assert auth.user_by_token('Bearer orphan') is None
    with sqlite3.connect(auth.USERS_DB) as db:
        replacement = auth.make_token(db, 7)
    assert auth.user_by_token('Bearer ' + replacement) == 7
print('PASS concurrent legacy migration, stable identities and tokens rejected after ID reuse')
