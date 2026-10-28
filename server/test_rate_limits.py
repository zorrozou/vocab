#!/usr/bin/env python3
import sys
from types import SimpleNamespace
from fastapi import HTTPException
sys.path.insert(0, 'server')
from app import limits

now = [100.0]
limits.monotonic = lambda: now[0]
limits._windows.clear()
a = SimpleNamespace(client=SimpleNamespace(host='192.0.2.1'))
b = SimpleNamespace(client=SimpleNamespace(host='192.0.2.2'))
for _ in range(20): limits.check_rate(a, 'auth')
try:
    limits.check_rate(a, 'auth')
    raise AssertionError('rate limit did not reject')
except HTTPException as e:
    assert e.status_code == 429 and int(e.headers['Retry-After']) > 0
limits.check_rate(b, 'auth')
now[0] += 61
limits.check_rate(a, 'auth')
for _ in range(6): limits.check_rate(a, 'personalize')
try:
    limits.check_rate(a, 'personalize')
    raise AssertionError('personalization rate limit did not reject')
except HTTPException as e:
    assert e.status_code == 429
print('PASS rate windows, address isolation and retry after expiration')
