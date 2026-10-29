#!/usr/bin/env python3
"""Exercise real server scheduling at deterministic times on an isolated fixture."""
import json, os, urllib.request
from datetime import datetime, timedelta, timezone

base = os.environ.get('VOCAB_TEST_BASE', 'http://127.0.0.1:18765').rstrip('/')
def post(body):
    request = urllib.request.Request(base + '/api/v1/fsrs/review', json.dumps(body).encode(), {'Content-Type':'application/json'})
    with urllib.request.urlopen(request, timeout=15) as response:
        return json.load(response)
def instant(value):
    return datetime.fromisoformat(value.replace('Z','+00:00'))
def next_body(result, rating, when):
    return {**{k:result[k] for k in ('state','stability','difficulty','due','step','last_review')},
            'rating':rating,'now':when.isoformat(),'deterministic':True}

start = datetime(2026, 10, 20, tzinfo=timezone.utc)
forgot = post({'is_new':True,'rating':1,'now':start.isoformat(),'deterministic':True})
assert forgot['state'] == 1 and instant(forgot['due']) == start + timedelta(minutes=1)
step1 = post(next_body(forgot, 3, instant(forgot['due'])))
assert step1['state'] == 1 and instant(step1['due']) == instant(forgot['due']) + timedelta(minutes=10)
graduated = post(next_body(step1, 3, instant(step1['due'])))
assert graduated['state'] == 2 and instant(graduated['due']) > instant(step1['due']) + timedelta(hours=1)
relearn = post(next_body(graduated, 1, instant(graduated['due'])))
assert relearn['state'] == 3 and instant(relearn['due']) == instant(graduated['due']) + timedelta(minutes=10)
print('PASS real FSRS learning, graduation and lapse intervals')
