#!/usr/bin/env python3
"""Cached verification must never cross a SQLite commit or database replacement."""
import os, sqlite3, subprocess, sys, tempfile, time
from pathlib import Path
from app import state_verification_cache as cache

with tempfile.TemporaryDirectory(prefix='vocab verification cache-') as tmp:
    path = Path(tmp) / 'state.db'
    writer = sqlite3.connect(path)
    writer.execute('PRAGMA journal_mode=WAL')
    writer.execute('CREATE TABLE state(account TEXT PRIMARY KEY, revision INTEGER, payload TEXT)')
    writer.execute("INSERT INTO state VALUES('a',1,'old')")
    writer.commit()
    before = cache.stamp(path)
    assert before is not None and cache.lookup(before, 'a', 1) is None
    cache.remember(before, 'a', 1, 4)
    assert cache.lookup(before, 'a', 1) == 4
    assert cache.lookup(before, 'b', 1) is None and cache.lookup(before, 'a', 2) is None
    # A read transaction may be pinned to the previous state while a writer
    # commits. Its old sample must neither hit nor be published for the future.
    reader = sqlite3.connect(path)
    sampled = cache.stamp(path)
    reader.execute('BEGIN')
    assert reader.execute("SELECT payload FROM state WHERE account='a'").fetchone()[0] == 'old'
    writer.execute("UPDATE state SET payload='new' WHERE account='a'")
    writer.commit()
    assert reader.execute("SELECT payload FROM state WHERE account='a'").fetchone()[0] == 'old'
    assert cache.lookup(sampled, 'a', 1) is None
    cache.remember(sampled, 'a', 1, 9)
    after = cache.stamp(path)
    assert cache.lookup(after, 'a', 1) is None
    reader.close()
    cache.remember(after, 'a', 1, 5)
    assert cache.lookup(after, 'a', 1) == 5
    # Another connection changes content without incrementing its revision.
    with sqlite3.connect(path) as external:
        external.execute("UPDATE state SET payload='corrupt' WHERE account='a'")
    assert cache.lookup(cache.stamp(path), 'a', 1) is None
    sample = cache.stamp(path); cache.remember(sample, 'a', 1, 8)
    subprocess.run([sys.executable, '-c', "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute(\"UPDATE state SET payload='other process' WHERE account='a'\"); c.commit(); c.close()", str(path)], check=True)
    assert cache.lookup(cache.stamp(path), 'a', 1) is None
    old_ttl = cache._TTL_SECONDS
    try:
        cache._TTL_SECONDS = .05
        sample = cache.stamp(path); cache.remember(sample, 'a', 1, 6)
        assert cache.lookup(sample, 'a', 1) == 6
        time.sleep(.07)
        assert cache.lookup(cache.stamp(path), 'a', 1) is None
    finally: cache._TTL_SECONDS = old_ttl
    writer.close()
    # Replacing a database while no SQLite writer is using it must not reuse
    # validation from the original inode, even if revisions are identical.
    sample = cache.stamp(path); cache.remember(sample, 'a', 1, 7)
    other = Path(tmp) / 'replacement.db'
    with sqlite3.connect(other) as db:
        db.execute('CREATE TABLE state(account TEXT PRIMARY KEY,revision INTEGER,payload TEXT)')
        db.execute("INSERT INTO state VALUES('a',1,'different database')")
    os.replace(other, path)
    assert cache.lookup(sample, 'a', 1) is None
    new = cache.stamp(path)
    assert new is not None and cache.lookup(new, 'a', 1) is None
print('PASS verified-state cache isolation, concurrent commit, expiry and database replacement')
