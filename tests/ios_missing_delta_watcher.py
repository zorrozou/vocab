#!/usr/bin/env python3
"""Move a delta record only inside this disposable simulator test container."""
import json, re, subprocess, sys, time, urllib.request
from pathlib import Path
udid, app_id, base = sys.argv[1], sys.argv[2], sys.argv[3].rstrip('/')
if not re.fullmatch(r'[0-9A-Fa-f-]{36}', udid) or not re.fullmatch(r'com\.zorro\.vocab\.regression\.[a-f0-9]{32}', app_id) or not re.fullmatch(r'http://127\.0\.0\.1:[0-9]+', base):
    raise SystemExit('Refusing unexpected simulator, app identifier or fixture')
def request(path, payload=None):
    body=json.dumps(payload).encode() if payload is not None else None
    req=urllib.request.Request(base+path,body,{'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=5) as response: return json.load(response)
deadline=time.monotonic()+240
while time.monotonic()<deadline:
    if request('/api/v1/__ui_fixture/disk-status')['state']=='arm':
        root=Path(subprocess.check_output(['/usr/bin/xcrun','simctl','get_app_container',udid,app_id,'data'],text=True).strip()).resolve()
        if f'/Devices/{udid}/data/Containers/Data/Application/' not in str(root): raise RuntimeError('Unexpected app container')
        directory=root/'Documents'/'VocabDelta'
        records=list(directory.glob('delta-*.json'))
        if len(records)!=1 or not records[0].with_suffix('.guard').is_file(): raise RuntimeError('Expected one guarded record')
        records[0].rename(records[0].with_suffix('.test-saved'))
        request('/api/v1/__ui_fixture/disk-transition',{'state':'blocked'})
        break
    time.sleep(.1)
else: raise SystemExit('missing-record watcher timed out')
