"""Persistence, retries, lease recovery and stale completion without LLM calls."""
from contextlib import contextmanager
from tempfile import TemporaryDirectory
from pathlib import Path
from unittest.mock import patch
import sqlite3
from app import coach_jobs as jobs

with TemporaryDirectory() as directory:
    path=Path(directory)/'jobs.db'
    @contextmanager
    def connect():
        db=sqlite3.connect(path)
        try:
            with db:
                db.execute('BEGIN IMMEDIATE');jobs.init(db);yield db
        finally:db.close()
    calls=[]
    def fail(*args):calls.append(args);raise RuntimeError('fixture failure')
    with patch.object(jobs.time,'time',return_value=100):
        with connect() as c:jobs.enqueue(c,'a','2026-11-05','prepare','life',{'revision':1})
        w=jobs.Worker(connect,fail,lambda:True)
        assert w.once() and not w.once()
    with patch.object(jobs.time,'time',return_value=161):assert w.once()
    with patch.object(jobs.time,'time',return_value=462):assert w.once() and not w.once()
    with connect() as c:
        row=c.execute('select status,attempts from coach_jobs_v3').fetchone()
        assert row==('failed',3)
    with patch.object(jobs.time,'time',return_value=500):
        with connect() as c:jobs.enqueue(c,'a','2026-11-05','prepare','life',{'revision':2})
        def changed(owner,day,kind,key,payload):
            with connect() as c:jobs.enqueue(c,owner,day,kind,key,{'revision':3})
        w=jobs.Worker(connect,changed,lambda:True);assert w.once()
        with connect() as c:
            assert c.execute('select status from coach_jobs_v3').fetchone()[0]=='queued'
            c.execute("UPDATE coach_jobs_v3 SET status='running',next=600")
        # New worker object with the same database, after a crashed processing lease.
        calls.clear();w=jobs.Worker(connect,lambda *args:calls.append(args),lambda:True)
        assert not w.once()
    with patch.object(jobs.time,'time',return_value=601):
        assert w.once() and calls[0][-1]=={'revision':3}
        with connect() as c:
            jobs.enqueue(c,'a','2026-11-05','audio','sound',{'text':'a'},0)
            jobs.enqueue(c,'a','2026-11-05','prepare','work',{'revision':1},5)
        assert w.once(media=False) and calls[-1][2]=='prepare'
        assert w.once(media=True) and calls[-1][2]=='audio'
print('PASS persisted retries, failed-job backoff, replacement during work, crashed lease recovery and independent material/audio lanes')
