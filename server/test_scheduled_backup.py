#!/usr/bin/env python3
"""Automatic backups retain only verified managed snapshots and preserve WAL data."""
import fcntl
import os
import sqlite3
import tempfile
from pathlib import Path
import scheduled_backup
from scheduled_backup import MARKER, backup, completed_snapshot
from backup_state import verify

with tempfile.TemporaryDirectory(prefix='vocab-auto-test-') as tmp:
    base = Path(tmp); data = base / 'data'; data.mkdir(); root = base / 'snapshots'
    for name in ('users.db', 'personal.db', 'lexicon_v0.1.sqlite'):
        with sqlite3.connect(data / name) as db:
            db.execute('CREATE TABLE example(value TEXT)'); db.execute('INSERT INTO example VALUES(?)', (name,))
    writer = sqlite3.connect(data / 'users.db')
    writer.execute('PRAGMA journal_mode=WAL'); writer.execute('INSERT INTO example VALUES(?)', ('committed wal',)); writer.commit()
    first = backup(data, root, keep=2); assert completed_snapshot(first)
    with sqlite3.connect(first / 'users.db') as db:
        assert db.execute('SELECT value FROM example WHERE value=?', ('committed wal',)).fetchone()
    second = backup(data, root, keep=2); assert first.exists() and second.exists()
    third = backup(data, root, keep=2)
    assert third.exists() and len([p for p in root.iterdir() if p.is_dir()]) == 2
    for path in (p for p in root.iterdir() if p.is_dir()): verify(path)
    manual = root / '20200101T000000Z-aaaaaaaa'; manual.mkdir(); (manual / 'notes').write_text('do not delete')
    previous = {p for p in root.iterdir() if p.is_dir() and p != manual}
    (data / 'personal.db').rename(data / 'personal.missing')
    try: backup(data, root, keep=1); raise AssertionError('missing database accepted')
    except (FileNotFoundError, ValueError): pass
    assert manual.exists() and all(p.exists() for p in previous)
    (data / 'personal.missing').rename(data / 'personal.db')
    # All database writers are fenced while the snapshots are being copied.
    original_create = scheduled_backup.create
    def check_locks(source, output):
        for name in ('users.db', 'personal.db', 'lexicon_v0.1.sqlite'):
            with sqlite3.connect(source / name, timeout=.05) as contender:
                try: contender.execute('BEGIN IMMEDIATE'); raise AssertionError('database writer was not fenced')
                except sqlite3.OperationalError as error: assert 'locked' in str(error)
        original_create(source, output)
    scheduled_backup.create = check_locks
    try: backup(data, root, keep=2)
    finally: scheduled_backup.create = original_create
    # Parameter files are outside SQLite; a concurrent change rejects the new
    # backup and keeps existing snapshots.
    parameter = data / 'fsrs_optimal_test.json'; parameter.write_text('{"value":1}')
    previous = {p for p in root.iterdir() if p.is_dir() and p != manual}
    def change_parameter(source, output):
        original_create(source, output)
        parameter.write_text('{"value":2}')
    scheduled_backup.create = change_parameter
    try:
        try: backup(data, root, keep=1); raise AssertionError('changed parameter file accepted')
        except ValueError: pass
    finally: scheduled_backup.create = original_create
    assert all(p.exists() for p in previous)
    real_check = scheduled_backup.completed_snapshot
    scheduled_backup.completed_snapshot = lambda _: False
    try:
        try: backup(data, root, keep=1); raise AssertionError('unverified new backup accepted')
        except ValueError: pass
    finally: scheduled_backup.completed_snapshot = real_check
    assert all(p.exists() for p in previous)
    # A completed snapshot altered by a user must never be removed by rotation.
    protected = next(iter(previous)); (protected / 'user-note').write_text('keep')
    latest = backup(data, root, keep=1)
    assert latest.exists() and protected.exists() and manual.exists()
    assert (root.stat().st_mode & 0o077) == 0 and (latest / MARKER).stat().st_mode & 0o077 == 0
    with sqlite3.connect(data / 'users.db') as busy:
        busy.execute('BEGIN IMMEDIATE')
        try: backup(data, root, keep=1); raise AssertionError('busy database accepted')
        except sqlite3.OperationalError: pass
    assert latest.exists() and protected.exists()
    with (root / '.lock').open('r+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try: backup(data, root); raise AssertionError('concurrent backup accepted')
        except BlockingIOError: pass
    writer.close()
    bad = base / 'public'; bad.mkdir(mode=0o755); os.chmod(bad, 0o755)
    try: backup(data, bad); raise AssertionError('non-private root accepted')
    except ValueError: pass
print('PASS verified WAL backup, private storage, safe rotation, failure preservation and concurrency lock')
