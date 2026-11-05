"""Small persistent work queue. Requests only enqueue; generation survives app exit."""
import json
import logging
import threading
import time
from uuid import uuid4


def init(conn):
    conn.execute("""CREATE TABLE IF NOT EXISTS coach_jobs_v3(
        owner TEXT,day TEXT,kind TEXT,key TEXT,payload TEXT,token TEXT,status TEXT,
        attempts INTEGER,next REAL,priority INTEGER,PRIMARY KEY(owner,day,kind,key))""")
    conn.execute("CREATE INDEX IF NOT EXISTS coach_jobs_due_v3 ON coach_jobs_v3(status,next,priority)")
    conn.execute("CREATE TABLE IF NOT EXISTS coach_context_v3(owner TEXT PRIMARY KEY,body TEXT)")


def enqueue(conn, owner, day, kind, key, payload, priority=5):
    raw = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    row = conn.execute("SELECT payload,status,next FROM coach_jobs_v3 WHERE owner=? AND day=? AND kind=? AND key=?",
                       (owner, day, kind, key)).fetchone()
    if row and row[0] == raw and (row[1] != 'failed' or row[2] > time.time()):
        return
    conn.execute("INSERT OR REPLACE INTO coach_jobs_v3 VALUES(?,?,?,?,?,?,'queued',0,?,?)",
                 (owner, day, kind, key, raw, uuid4().hex, time.time(), priority))


class Worker:
    def __init__(self, connect, execute, enabled):
        self.connect, self.execute, self.enabled = connect, execute, enabled
        self.wake, self.stop = threading.Event(), threading.Event()
        self.threads = []

    def once(self, media=None):
        if not self.enabled():
            return False
        with self.connect() as conn:
            lane = "" if media is None else (" AND kind IN ('audio','vocabulary')" if media else " AND kind NOT IN ('audio','vocabulary')")
            row = conn.execute("""SELECT owner,day,kind,key,payload,token,attempts FROM coach_jobs_v3
                WHERE status IN ('queued','running') AND next<=?"""+lane+" ORDER BY priority,day,next LIMIT 1", (time.time(),)).fetchone()
            if not row:
                return False
            owner, day, kind, key, raw, token, attempts = row
            conn.execute("UPDATE coach_jobs_v3 SET status='running',attempts=attempts+1,next=? WHERE token=?",
                         (time.time()+600, token))
        try:
            self.execute(owner, day, kind, key, json.loads(raw))
            status, delay = 'complete', 0
        except Exception as exc:
            logging.getLogger(__name__).warning("Coach background %s: %s", kind, type(exc).__name__)
            status, delay = ('queued', (60, 300)[attempts]) if attempts < 2 else ('failed', 21600)
        with self.connect() as conn:
            conn.execute("UPDATE coach_jobs_v3 SET status=?,next=? WHERE token=?", (status, time.time()+delay, token))
        return True

    def start(self):
        if any(t.is_alive() for t in self.threads):
            return
        with self.connect():
            pass
        self.stop.clear()
        def run(media):
            while not self.stop.is_set():
                try:
                    if self.once(media):
                        continue
                except Exception as exc:
                    logging.getLogger(__name__).warning("Coach worker: %s", type(exc).__name__)
                self.wake.wait(15)
                self.wake.clear()
        self.threads = [threading.Thread(target=run,args=(media,),name='coach-media' if media else 'coach-preparation',daemon=True) for media in (False,True)]
        for thread in self.threads:thread.start()

    def close(self):
        self.stop.set()
        self.wake.set()
