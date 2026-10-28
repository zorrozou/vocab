#!/usr/bin/env python3
"""Run only with a dedicated isolated app copy/stub; manipulates its test database."""
import json, os, sqlite3, subprocess, sys, time, urllib.parse, urllib.request, uuid
from pathlib import Path
root = Path(sys.argv[1]).resolve()
assert (root / 'stub_personal.py').exists()
base = 'http://127.0.0.1:18765'
def call(path, body=None):
    req = urllib.request.Request(base + path, data=json.dumps(body).encode() if body is not None else None,
                                 headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req, timeout=2) as response: return json.load(response)
def start(slow):
    env = dict(os.environ, VOCAB_TEST_SLOW='1' if slow else '0')
    proc = subprocess.Popen([sys.executable, str(root / 'stub_personal.py')], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(100):
        try:
            if call('/api/v1/health')['ok']: return proc
        except Exception: time.sleep(.05)
    proc.terminate(); raise RuntimeError('test server failed to start')
def stop(proc):
    proc.kill(); proc.wait(timeout=10)
job_id = 'restart-' + uuid.uuid4().hex
payload = {'device':'restart-guest-secret', 'date':'2026-10-27', 'weak_words':['apple'],
           'learned_max_pos':5000, 'sync':True, 'replace':True, 'request_id':job_id}
query = urllib.parse.urlencode({'job_id':job_id,'device':payload['device']})
proc = start(True)
try:
    call('/api/v1/personalize', payload)
    for _ in range(100):
        result = call('/api/v1/personalized/job?' + query)
        if result['status'] == 'running': break
        time.sleep(.05)
    assert result['status'] == 'running', result
finally:
    stop(proc)
# Simulate expiry of the crashed worker's lease without waiting for its 120-second timeout.
with sqlite3.connect(root / 'data' / 'personal.db') as conn:
    conn.execute('UPDATE personal_jobs SET lease_until=? WHERE id=?', (time.time()-1, job_id))
proc = start(False)
try:
    for _ in range(100):
        result = call('/api/v1/personalized/job?' + query)
        if result['status'] == 'complete': break
        time.sleep(.05)
    assert result['status'] == 'complete' and len(result['sentences']) == 1, result
finally:
    stop(proc)
print('PASS real process restart recovers an expired task lease')
