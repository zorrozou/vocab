"""Short-lived verified-state cache with conservative database invalidation.

Only validation results, never account contents, are cached. A separate
read-only SQLite connection observes commits from all writers; file metadata
also detects replacement and ordinary out-of-band changes. A hit is valid only
when the token is stable across the caller's read-transaction snapshot.
"""
from collections import OrderedDict
from pathlib import Path
import os
import sqlite3
import threading
import time

_TTL_SECONDS = 2.0
_MAX_DATABASES = 4
_MAX_ACCOUNTS = 256
_lock = threading.Lock()
_monitors = OrderedDict()


def _files(path):
    result = []
    for name in (path, path + '-wal'):
        try:
            st = os.stat(name)
            result.append((st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns))
        except FileNotFoundError:
            result.append(None)
    return tuple(result)


def _monitor(path):
    files = _files(path)
    if files[0] is None:
        return None
    current = _monitors.get(path)
    identity = files[0][:2]
    if current is not None and (current['identity'] != identity or current['pid'] != os.getpid()):
        current['connection'].close()
        del _monitors[path]
        current = None
    if current is None:
        conn = sqlite3.connect(Path(path).resolve().as_uri() + '?mode=ro', uri=True, timeout=1, check_same_thread=False)
        current = {'identity': identity, 'pid': os.getpid(), 'connection': conn, 'entries': OrderedDict(), 'token': object()}
        _monitors[path] = current
        while len(_monitors) > _MAX_DATABASES:
            _, removed = _monitors.popitem(last=False)
            removed['connection'].close()
    _monitors.move_to_end(path)
    return current


def _sample(path, monitor):
    before = _files(path)
    if before[0] is None or before[0][:2] != monitor['identity']:
        return None
    version = monitor['connection'].execute('PRAGMA data_version').fetchone()[0]
    after = _files(path)
    if before != after:
        return None
    return (monitor['token'], version, after)


def stamp(db_path):
    """Capture before the caller establishes its read transaction; None bypasses cache."""
    path = os.fspath(db_path)
    try:
        with _lock:
            monitor = _monitor(path)
            return (path, _sample(path, monitor)) if monitor is not None else None
    except (OSError, sqlite3.Error):
        return None


def _unchanged(token):
    if token is None or token[1] is None:
        return None
    path, sample = token
    monitor = _monitor(path)
    if monitor is None or _sample(path, monitor) != sample:
        return None
    return monitor


def lookup(token, account, revision):
    """Return the verified epoch only while the sampled database is unchanged."""
    try:
        with _lock:
            monitor = _unchanged(token)
            if monitor is None:
                return None
            key = (account, revision)
            value = monitor['entries'].get(key)
            if value is None or value[0] != token[1] or value[2] <= time.monotonic():
                monitor['entries'].pop(key, None)
                return None
            monitor['entries'].move_to_end(key)
            return value[1]
    except (OSError, sqlite3.Error):
        return None


def remember(token, account, revision, epoch):
    """Publish only if no writer changed the database since the initial sample."""
    try:
        with _lock:
            monitor = _unchanged(token)
            if monitor is None:
                return
            key = (account, revision)
            monitor['entries'][key] = (token[1], epoch, time.monotonic() + _TTL_SECONDS)
            monitor['entries'].move_to_end(key)
            while len(monitor['entries']) > _MAX_ACCOUNTS:
                monitor['entries'].popitem(last=False)
    except (OSError, sqlite3.Error):
        return
