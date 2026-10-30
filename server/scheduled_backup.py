#!/usr/bin/env python3
"""Create verified local backups and rotate only our own completed snapshots."""
import argparse
import fcntl
import os
import re
import secrets
import shutil
import sqlite3
import stat
import json
import zipfile
from contextlib import ExitStack
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

from backup_state import DATABASES, MANIFEST, create, digest, safe_regular, verify

MARKER = '.vocab-automatic-backup'
MARKER_CONTENT = 'vocab-automatic-backup-v1\n'
NAME = re.compile(r'^\d{8}T\d{6}Z-[a-f0-9]{8}$')


def scheduler_files(data):
    result = {}
    for path in sorted(data.glob('fsrs_optimal*.json')):
        safe_regular(path)
        result[path.name] = digest(path)
    return result


def completed_snapshot(path):
    if path.is_symlink() or not path.is_dir() or not NAME.fullmatch(path.name):
        return False
    marker = path / MARKER
    if marker.is_symlink() or not marker.is_file() or marker.read_text() != MARKER_CONTENT:
        return False
    records = verify(path)
    allowed = set(records) | {MARKER, MANIFEST}
    # SQLite may create empty WAL and shared-memory sidecars while verifying a
    # WAL-mode snapshot. Never delete a snapshot with a nonempty WAL or a link.
    for name in DATABASES:
        for suffix in ('-wal', '-shm'):
            sidecar = path / (name + suffix)
            if sidecar.exists() or sidecar.is_symlink():
                if sidecar.is_symlink() or not sidecar.is_file() or (suffix == '-wal' and sidecar.stat().st_size):
                    return False
                allowed.add(sidecar.name)
    return {p.name for p in path.iterdir()} == allowed


def maintain_archive(output, root):
    """Monthly portable archive; never modifies live state or restore epochs.

    Ordinary daily rotation cannot remove the compressed monthly recovery point.
    Replace it only after CRC validation. No unverified/foreign files are removed.
    """
    records = verify(output)
    month = output.name[:6]
    target = root / ("vocab-monthly-" + month + ".zip")
    temporary = root / (".monthly-" + secrets.token_hex(8) + ".tmp")
    try:
        with zipfile.ZipFile(temporary,"w",compression=zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
            for name in [*records,MANIFEST]: archive.write(output/name,name)
            archive.writestr("archive-info.json",json.dumps({"format":1,"source":output.name,"month":month}))
        os.chmod(temporary,0o600)
        with zipfile.ZipFile(temporary) as archive:
            if archive.testzip() is not None: raise ValueError("Monthly archive verification failed")
        if target.is_symlink(): raise ValueError("Monthly archive must not be a symlink")
        if target.exists():
            with zipfile.ZipFile(target) as previous:
                info=json.loads(previous.read("archive-info.json"))
                if info.get("format")!=1 or info.get("month")!=month: raise ValueError("Unrecognized monthly archive")
        os.replace(temporary,target)
    finally:
        if temporary.exists(): temporary.unlink()
    # Deduplicate identical immutable lexicon snapshots, never the live database.
    name="lexicon_v0.1.sqlite"
    for other in sorted(root.iterdir(),reverse=True):
        if other==output:continue
        try:
            if not completed_snapshot(other) or digest(other/name)!=records[name]["sha256"]:continue
            link=output/(".lexicon-"+secrets.token_hex(4))
            try:
                os.link(other/name,link);os.replace(link,output/name)
            finally:
                if link.exists():link.unlink()
            break
        except OSError:continue


def backup(data, root, keep=30):
    if keep < 1:
        raise ValueError('At least one backup must be retained')
    root = root.absolute()
    if root.is_symlink():
        raise ValueError('Backup root must not be a symlink')
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = root.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('Backup root must be owned by this user and private')
    flags = os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0)
    fd = os.open(root / '.lock', flags, 0o600)
    lock_info = os.fstat(fd)
    if not stat.S_ISREG(lock_info.st_mode) or lock_info.st_uid != os.getuid():
        os.close(fd)
        raise ValueError('Invalid backup lock')
    try:
        with os.fdopen(fd, 'r+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            name = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + secrets.token_hex(4)
            output = root / name
            data = data.resolve(strict=True)
            # Reserve every database before copying any of them. SQLite reads
            # remain available, while writers wait for this bounded snapshot.
            with ExitStack() as locks:
                for db_name in DATABASES:
                    path = data / db_name
                    if db_name == DATABASES[2] and not path.exists() and not path.is_symlink():
                        continue
                    safe_regular(path)
                    uri = 'file:' + quote(str(path.resolve()), safe='/') + '?mode=rw'
                    conn = sqlite3.connect(uri, uri=True, timeout=5)
                    locks.callback(conn.close)
                    conn.execute('BEGIN IMMEDIATE')
                before = scheduler_files(data)
                try:
                    create(data, output)
                    after = scheduler_files(data)
                    copied = {p.name: digest(p) for p in output.glob('fsrs_optimal*.json')}
                    if before != after or copied != before:
                        raise ValueError('Scheduler files changed during backup; retry later')
                except BaseException:
                    if output.exists() and not output.is_symlink(): shutil.rmtree(output)
                    raise
            marker = output / MARKER
            marker.write_text(MARKER_CONTENT)
            os.chmod(marker, 0o600)
            if not completed_snapshot(output):
                raise ValueError('New backup could not be verified; older backups were retained')
            maintain_archive(output, root)
            # A failed new snapshot must never delete older backups. Ignore
            # incomplete, altered, or foreign directories instead of deleting them.
            complete = []
            for path in root.iterdir():
                try:
                    if completed_snapshot(path): complete.append(path)
                except (OSError, ValueError, sqlite3.Error):
                    continue
            complete = sorted((p for p in complete if p != output), key=lambda p: p.name, reverse=True)
            for old in complete[keep - 1:]:
                shutil.rmtree(old)
            return output
    except BaseException:
        # fdopen owns fd once constructed; it closes it on every exit.
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--keep', type=int, default=30)
    args = parser.parse_args()
    try:
        path = backup(args.data, args.root, args.keep)
    except (OSError, ValueError, sqlite3.Error) as error:
        parser.exit(1, f'Automatic backup failed: {error}\n')
    print(f'Verified backup created: {path}')


if __name__ == '__main__':
    main()
