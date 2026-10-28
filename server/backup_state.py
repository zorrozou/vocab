#!/usr/bin/env python3
"""Create and verify an offline backup, or restore it into a new staging directory."""
import argparse
import hashlib
import json
import os
import secrets
import shutil
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

DATABASES = ('users.db', 'personal.db', 'lexicon_v0.1.sqlite')
REQUIRED = {'users.db', 'personal.db'}
MANIFEST = 'manifest.json'


def digest(path):
    hasher = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            hasher.update(block)
    return hasher.hexdigest()


def check_sqlite(path):
    with sqlite3.connect('file:' + quote(str(path.resolve()), safe='/') + '?mode=ro', uri=True) as db:
        result = db.execute('PRAGMA quick_check').fetchall()
    if result != [('ok',)]:
        raise ValueError(f'SQLite integrity check failed: {path.name}')


def safe_regular(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f'Expected a regular file: {path.name}')


def create(data, destination):
    data = data.resolve(strict=True)
    if not data.is_dir():
        raise ValueError('Data path must be a directory')
    names = list(DATABASES[:2])
    if (data / DATABASES[2]).exists() or (data / DATABASES[2]).is_symlink():
        names.append(DATABASES[2])
    names.extend(sorted(p.name for p in data.glob('fsrs_optimal*.json')))
    for name in names:
        safe_regular(data / name)
    destination = destination.absolute()
    if destination.resolve().is_relative_to(data):
        raise ValueError('Backup directory must be outside the data directory')
    destination.mkdir(mode=0o700)  # Refuses to replace any existing destination.
    try:
        records = []
        for name in names:
            source, target = data / name, destination / name
            if name in DATABASES:
                with sqlite3.connect('file:' + quote(str(source.resolve()), safe='/') + '?mode=ro', uri=True) as src:
                    with sqlite3.connect(target) as dst:
                        src.backup(dst)
                check_sqlite(target)
            else:
                shutil.copyfile(source, target)
            os.chmod(target, 0o600)
            records.append({'name': name, 'size': target.stat().st_size, 'sha256': digest(target)})
        manifest = {'format': 1, 'created_utc': datetime.now(timezone.utc).isoformat(), 'files': records}
        (destination / MANIFEST).write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
        os.chmod(destination / MANIFEST, 0o600)
        verify(destination)
    except BaseException:
        shutil.rmtree(destination)
        raise


def verify(backup):
    if backup.is_symlink() or not backup.is_dir():
        raise ValueError('Backup must be a directory, not a symlink')
    manifest_path = backup / MANIFEST
    safe_regular(manifest_path)
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    if manifest.get('format') != 1 or not isinstance(manifest.get('files'), list):
        raise ValueError('Invalid backup manifest')
    seen = set()
    records = {}
    for entry in manifest['files']:
        if not isinstance(entry, dict):
            raise ValueError('Invalid backup entry')
        name = entry.get('name')
        if not isinstance(name, str) or Path(name).name != name or name in seen:
            raise ValueError('Invalid or duplicate backup filename')
        if name not in DATABASES and not (name.startswith('fsrs_optimal') and name.endswith('.json')):
            raise ValueError(f'Unexpected backup filename: {name}')
        seen.add(name)
        path = backup / name
        safe_regular(path)
        if path.stat().st_size != entry.get('size') or digest(path) != entry.get('sha256'):
            raise ValueError(f'Backup checksum mismatch: {name}')
        if name in DATABASES:
            check_sqlite(path)
        records[name] = entry
    if not REQUIRED.issubset(seen):
        raise ValueError('Backup is missing a required database')
    return records


def reset_sync_generation(path, create_if_missing=False):
    """Rotate the offline database identity and invalidate transient sync data."""
    safe_regular(path)
    db = sqlite3.connect('file:' + quote(str(path.resolve()), safe='/') + '?mode=rw', uri=True, timeout=15)
    try:
        db.execute('BEGIN IMMEDIATE')
        exists = db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='sync_metadata'").fetchone()
        if not exists and not create_if_missing:
            db.rollback()
            return None  # Legacy databases receive a new identity on migration.
        if not exists:
            db.execute('CREATE TABLE sync_metadata(id INTEGER PRIMARY KEY CHECK(id=1), generation TEXT NOT NULL)')
        generation = secrets.token_hex(16)
        db.execute('INSERT INTO sync_metadata(id,generation) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET generation=excluded.generation', (generation,))
        for table in ('account_state_snapshots', 'account_state_changes', 'account_state_change_compact', 'account_state_batches', 'account_restore_receipts', 'account_guarded_restore_receipts', 'account_checkpoint_receipts', 'account_delta_stage_parts', 'account_delta_stages'):
            if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone():
                db.execute('DELETE FROM ' + table)  # Fixed, internal table names only.
        db.commit()
        return generation
    except BaseException:
        db.rollback()
        raise
    finally:
        db.close()


def restore(backup, destination):
    records = verify(backup)
    names = sorted(records)
    backup = backup.resolve(strict=True)
    destination = destination.absolute()
    if destination.resolve().is_relative_to(backup):
        raise ValueError('Restore directory must be outside the backup')
    destination.mkdir(mode=0o700)  # Staging only; never replaces a live directory.
    try:
        for name in names:
            shutil.copyfile(backup / name, destination / name)
            os.chmod(destination / name, 0o600)
        for name in names:
            if (destination / name).stat().st_size != records[name]['size'] or digest(destination / name) != records[name]['sha256']:
                raise ValueError(f'Restored file differs: {name}')
            if name in DATABASES:
                check_sqlite(destination / name)
        # The staging copy is verified byte-for-byte first. A modern database
        # then gets a fresh identity so a prior client's cursor cannot alias it.
        reset_sync_generation(destination / 'users.db')
        check_sqlite(destination / 'users.db')
    except BaseException:
        shutil.rmtree(destination)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    make = sub.add_parser('create', help='Snapshot files after all writers have stopped')
    make.add_argument('--data', type=Path, required=True)
    make.add_argument('--output', type=Path, required=True)
    make.add_argument('--writers-stopped', action='store_true', required=True,
                      help='Declare that API, background jobs and other writers are stopped')
    check = sub.add_parser('verify', help='Verify checksums and SQLite integrity')
    check.add_argument('--backup', type=Path, required=True)
    stage = sub.add_parser('restore', help='Restore to a new staging directory only')
    stage.add_argument('--backup', type=Path, required=True)
    stage.add_argument('--output', type=Path, required=True)
    reset = sub.add_parser('reset-sync-generation', help='Invalidate incremental cursors after an offline manual database replacement')
    reset.add_argument('--data', type=Path, required=True)
    reset.add_argument('--writers-stopped', action='store_true', required=True,
                       help='Declare that API, background jobs and other writers are stopped')
    args = parser.parse_args()
    try:
        if args.command == 'create':
            create(args.data, args.output)
        elif args.command == 'verify':
            verify(args.backup)
        elif args.command == 'restore':
            restore(args.backup, args.output)
        else:
            data = args.data.resolve(strict=True)
            if not data.is_dir():
                raise ValueError('Data path must be a directory')
            reset_sync_generation(data / 'users.db', create_if_missing=True)
    except (OSError, ValueError, sqlite3.Error, json.JSONDecodeError) as error:
        print(f'Backup operation failed: {error}', file=sys.stderr)
        return 1
    print(f'{args.command}: OK')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
