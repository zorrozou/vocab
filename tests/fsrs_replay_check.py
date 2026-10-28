#!/usr/bin/env python3
"""Replay the same offline history twice against an isolated API instance."""
import json
import urllib.request

BASE = 'http://127.0.0.1:18765'

def post(body):
    req = urllib.request.Request(BASE + '/api/v1/fsrs/review',
                                 json.dumps(body).encode(), {'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)

def replay():
    body = {'is_new': True}
    for rating, when in [(3, '2026-10-20T00:00:00Z'), (3, '2026-10-20T00:15:00Z'),
                         (3, '2026-10-23T00:15:00Z'), (1, '2026-10-27T00:15:00Z')]:
        result = post({**body, 'rating': rating, 'now': when, 'deterministic': True})
        body = {k: result[k] for k in ('state', 'stability', 'difficulty', 'due', 'step', 'last_review')}
    return result

first = replay()
for _ in range(5):
    assert replay() == first, (replay(), first)
assert first['last_review'] == '2026-10-27T00:15:00+00:00'
assert first['state'] == 3
print('PASS repeated offline FSRS history returns identical final card')
