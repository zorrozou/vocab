#!/usr/bin/env python3
"""Temporarily remove write access only from a disposable simulator app's Documents."""
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import time
import urllib.request

udid, app_id, base = sys.argv[1], sys.argv[2], sys.argv[3].rstrip('/')
if not re.fullmatch(r'[0-9A-Fa-f-]{36}', udid) or not re.fullmatch(r'com\.zorro\.vocab\.regression\.[a-f0-9]{32}', app_id) or not re.fullmatch(r'http://127\.0\.0\.1:[0-9]+', base):
    raise SystemExit('Refusing unexpected simulator, app identifier or fixture')
documents = None
original = None

def request(path, payload=None):
    body = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(base + path, body, {'Content-Type':'application/json'})
    with urllib.request.urlopen(req, timeout=5) as response:
        return json.load(response)

def container_documents():
    root = Path(subprocess.check_output(['/usr/bin/xcrun', 'simctl', 'get_app_container', udid, app_id, 'data'], text=True).strip()).resolve()
    expected = f'/Devices/{udid}/data/Containers/Data/Application/'
    if not root.is_absolute() or expected not in str(root):
        raise RuntimeError('Refusing unexpected simulator app container')
    target = root / 'Documents'
    if not target.is_dir():
        raise RuntimeError('Disposable app Documents directory is unavailable')
    return target

def stop(_signum, _frame):
    raise SystemExit('watcher stopped')

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
try:
    deadline = time.monotonic() + 240
    while time.monotonic() < deadline:
        state = request('/api/v1/__ui_fixture/disk-status')['state']
        if state == 'arm':
            documents = container_documents()
            original = stat.S_IMODE(documents.stat().st_mode)
            os.chmod(documents, original & ~0o222)
            request('/api/v1/__ui_fixture/disk-transition', {'state':'blocked'})
        elif state == 'restore':
            if documents is None or original is None:
                raise RuntimeError('No blocked directory to restore')
            os.chmod(documents, original)
            request('/api/v1/__ui_fixture/disk-transition', {'state':'restored'})
            break
        time.sleep(.1)
    else:
        raise SystemExit('disk test watcher timed out')
finally:
    if documents is not None and original is not None and documents.exists():
        os.chmod(documents, original)
