#!/usr/bin/env python3
"""Rehearse an offline legacy upgrade and restore using disposable data."""
import hashlib
import json
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path

root = Path(__file__).resolve().parents[1]
tool = root / 'server/backup_state.py'
def run(*args, ok=True):
    result = subprocess.run([sys.executable, str(tool), *map(str, args)], capture_output=True, text=True)
    assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
    return result

with tempfile.TemporaryDirectory(prefix='vocab-rehearsal-') as tmp:
    temp = Path(tmp)
    shutil.copytree(root / 'server/app', temp / 'app', ignore=shutil.ignore_patterns('__pycache__'))
    data = temp / 'data'; data.mkdir()
    shutil.copy2(root / 'data/lexicon_v0.1.sqlite', data / 'lexicon_v0.1.sqlite')
    password, salt, token = 'test_password_123', 'ab' * 16, 'legacy-token-for-rehearsal'
    old_hash = hashlib.pbkdf2_hmac('sha256', password.encode(), bytes.fromhex(salt), 100_000).hex()
    old_state = json.dumps({'v':1,'cards':{'apple':{'pos':1}},'log':[],'pendingNew':[],'settings':{}})
    # Keep the connection open after a committed WAL write: the backup must include it.
    users = sqlite3.connect(data / 'users.db')
    users.execute('PRAGMA journal_mode=WAL')
    users.execute('CREATE TABLE users(id INTEGER PRIMARY KEY, username TEXT UNIQUE COLLATE NOCASE, nickname TEXT, password_hash TEXT, salt TEXT, created_at REAL, last_login_at REAL)')
    users.execute('CREATE TABLE tokens(token_hash TEXT PRIMARY KEY, user_id INTEGER, expires_at REAL, revoked INTEGER DEFAULT 0)')
    users.execute('CREATE TABLE user_state(user_id INTEGER PRIMARY KEY, state_json TEXT, updated_at REAL)')
    users.execute('INSERT INTO users VALUES(7,?,?,?,?,0,0)', ('alice','Alice',old_hash,salt))
    users.execute('INSERT INTO tokens VALUES(?,7,?,0)', (hashlib.sha256(token.encode()).hexdigest(), time.time()+3600))
    users.execute('INSERT INTO user_state VALUES(7,?,123)', (old_state,))
    users.commit()
    with sqlite3.connect(data / 'personal.db') as db:
        db.execute('CREATE TABLE requests(device TEXT, date TEXT, payload TEXT, created REAL, processed INTEGER DEFAULT 0)')
        db.execute("CREATE TABLE sentences(device TEXT, date TEXT, target TEXT, recall TEXT, text TEXT, created REAL, zh TEXT DEFAULT '')")
        db.execute('INSERT INTO sentences VALUES(?,?,?,?,?,?,?)', ('u7','2026-10-27','apple','','old sentence',time.time(),'旧句'))
    params = {'parameters':[1,2,3], 'desired_retention':0.81}
    (data / 'fsrs_optimal_uid7.json').write_text(json.dumps(params))
    backup = temp / 'snapshot'
    run('create','--data',data,'--output',backup,ok=False)  # explicit stopped-writer declaration required
    assert not backup.exists()
    run('create','--data',data,'--output',backup,'--writers-stopped')
    run('verify','--backup',backup)
    run('create','--data',data,'--output',backup,'--writers-stopped',ok=False)
    users.close()

    # Run the current migrations on the working copy, then upgrade the password.
    sys.path.insert(0, str(temp))
    from app import auth, main
    main.init_db()
    login = next(r.endpoint for r in main.app.routes if getattr(r,'path',None)=='/api/v1/auth/login')
    migrated = login(auth.LoginIn(username='alice',password=password), None)
    account_id = migrated['user']['account_id']
    assert auth.user_by_token('Bearer '+token) == 7
    with sqlite3.connect(data / 'users.db') as db:
        assert db.execute('SELECT password_hash FROM users WHERE id=7').fetchone()[0].startswith('$argon2id$')
        assert json.loads(db.execute('SELECT state_json FROM account_state WHERE account_id=?',(account_id,)).fetchone()[0])['cards']['apple']
    with sqlite3.connect(data / 'personal.db') as db:
        assert db.execute('SELECT device,text FROM sentences').fetchone() == ('account:'+account_id,'old sentence')

    # Modern backups retain account data, but each restored staging copy gets a
    # distinct sync generation and cannot expose stale snapshots or change rows.
    with sqlite3.connect(data / 'users.db') as db:
        original_generation = db.execute('SELECT generation FROM sync_metadata WHERE id=1').fetchone()[0]
        db.execute('INSERT INTO account_state_changes VALUES(?,?,?,?,?,?,?,?)', (account_id,2,1,0,0,b'old-change','digest',1))
        db.execute('INSERT INTO account_state_change_compact VALUES(?,?,?,?)', (account_id,2,b'compact-change','digest'))
        db.execute('INSERT INTO account_state_change_compact VALUES(?,?,?,?)', (account_id,3,b'orphaned-change','digest'))
        db.execute('INSERT INTO account_state_snapshots(snapshot_id,account_id,state_revision,restore_epoch,payload,digest,created_at,expires_at) VALUES(?,?,?,?,?,?,?,?)', ('a'*32,account_id,1,0,b'old-snapshot','digest',1,time.time()+600))
        db.execute('INSERT INTO account_state_batches VALUES(?,?,?,?,?,?,?,?,?)', (account_id,'b'*32,'digest',original_generation,0,1,0,1,1))
        db.execute('INSERT INTO account_restore_receipts VALUES(?,?,?,?,?,?,?,?,?,?,?)', (account_id,'e'*32,'digest',original_generation,0,1,0,1,1,1,'f'*64))
        db.execute('INSERT INTO account_guarded_restore_receipts VALUES(?,?,?,?,?,?,?,?,?)', (account_id,'a'*32,'digest',original_generation,1,1,'{}','digest',1))
        db.execute('INSERT INTO account_checkpoint_receipts VALUES(?,?,?,?,?,?,?,?,?,?)', (account_id,'9'*32,'digest',original_generation,0,1,0,1,1,1))
        db.execute('INSERT INTO account_delta_stages VALUES(?,?,?,?,?,?,?,?,?,?,?)', (account_id,'c'*32,original_generation,'1',0,3,1,'digest',1,time.time()+600,'d'*32))
        db.execute('INSERT INTO account_delta_stage_parts VALUES(?,?,?,?,?)', (account_id,'c'*32,0,b'old','digest'))
        state_json, revision = db.execute('SELECT state_json,state_revision FROM account_state WHERE account_id=?', (account_id,)).fetchone()
        auth.state_segments.write(db, account_id, revision, json.loads(state_json), force=True)
    modern = temp / 'modern-snapshot'
    run('create','--data',data,'--output',modern,'--writers-stopped')
    run('verify','--backup',modern)
    identities = []
    for index in range(2):
        target = temp / f'modern-staging-{index}'
        run('restore','--backup',modern,'--output',target)
        with sqlite3.connect(target / 'users.db') as db:
            identities.append(db.execute('SELECT generation FROM sync_metadata WHERE id=1').fetchone()[0])
            assert db.execute('SELECT count(*) FROM account_state_changes').fetchone()[0] == 0
            assert db.execute('SELECT count(*) FROM account_state_change_compact').fetchone()[0] == 0
            assert db.execute('SELECT count(*) FROM account_state_snapshots').fetchone()[0] == 0
            assert db.execute('SELECT count(*) FROM account_state_batches').fetchone()[0] == 0
            assert db.execute('SELECT count(*) FROM account_restore_receipts').fetchone()[0] == 0
            assert db.execute('SELECT count(*) FROM account_guarded_restore_receipts').fetchone()[0] == 0
            assert db.execute('SELECT count(*) FROM account_checkpoint_receipts').fetchone()[0] == 0
            assert db.execute('SELECT count(*) FROM account_delta_stages').fetchone()[0] == 0
            assert db.execute('SELECT count(*) FROM account_delta_stage_parts').fetchone()[0] == 0
            assert json.loads(db.execute('SELECT state_json FROM account_state WHERE account_id=?',(account_id,)).fetchone()[0])['cards']['apple']
            state_json, revision = db.execute('SELECT state_json,state_revision FROM account_state WHERE account_id=?', (account_id,)).fetchone()
            assert auth.state_segments.read(db, account_id, revision, state_json)['cards']['apple']
    assert len(set(identities + [original_generation])) == 3
    with sqlite3.connect(data / 'users.db') as db:
        assert db.execute('SELECT generation FROM sync_metadata WHERE id=1').fetchone()[0] == original_generation
        assert db.execute('SELECT count(*) FROM account_state_changes').fetchone()[0] == 1
        assert db.execute('SELECT count(*) FROM account_state_change_compact').fetchone()[0] == 2
        assert db.execute('SELECT count(*) FROM account_state_snapshots').fetchone()[0] == 1
        assert db.execute('SELECT count(*) FROM account_state_batches').fetchone()[0] == 1
        assert db.execute('SELECT count(*) FROM account_restore_receipts').fetchone()[0] == 1
        assert db.execute('SELECT count(*) FROM account_guarded_restore_receipts').fetchone()[0] == 1
        assert db.execute('SELECT count(*) FROM account_checkpoint_receipts').fetchone()[0] == 1
        assert db.execute('SELECT count(*) FROM account_delta_stages').fetchone()[0] == 1
        assert db.execute('SELECT count(*) FROM account_delta_stage_parts').fetchone()[0] == 1
        state_json, revision = db.execute('SELECT state_json,state_revision FROM account_state WHERE account_id=?', (account_id,)).fetchone()
        assert auth.state_segments.read(db, account_id, revision, state_json)['cards']['apple']
    run('reset-sync-generation','--data',temp/'modern-staging-0',ok=False)
    run('reset-sync-generation','--data',temp/'modern-staging-0','--writers-stopped')
    with sqlite3.connect(temp/'modern-staging-0'/'users.db') as db:
        assert db.execute('SELECT generation FROM sync_metadata WHERE id=1').fetchone()[0] not in (original_generation,*identities)
    run('verify','--backup',modern)  # Staging mutations never change the verified backup.

    staged = temp / 'rollback-staging'
    run('restore','--backup',backup,'--output',staged)
    run('restore','--backup',backup,'--output',staged,ok=False)
    with sqlite3.connect(staged / 'users.db') as db:
        assert 'account_id' not in {r[1] for r in db.execute('PRAGMA table_info(users)')}
        assert db.execute('SELECT password_hash,salt FROM users WHERE id=7').fetchone() == (old_hash,salt)
        assert json.loads(db.execute('SELECT state_json FROM user_state WHERE user_id=7').fetchone()[0]) == json.loads(old_state)
        assert db.execute('SELECT count(*) FROM tokens').fetchone()[0] == 1
    with sqlite3.connect(staged / 'personal.db') as db:
        assert db.execute('SELECT device,text FROM sentences').fetchone() == ('u7','old sentence')
    assert json.loads((staged/'fsrs_optimal_uid7.json').read_text()) == params
    assert (staged/'lexicon_v0.1.sqlite').is_file()
    (backup/'fsrs_optimal_uid7.json').write_text('tampered')
    run('verify','--backup',backup,ok=False)
    rejected = temp / 'rejected'
    run('restore','--backup',backup,'--output',rejected,ok=False)
    assert not rejected.exists()
print('PASS offline snapshot, upgrade, staged rollback, WAL preservation and tamper rejection')
