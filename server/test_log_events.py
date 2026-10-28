"""Independent identical log entries remain distinct and retries are idempotent."""
import copy, sys
sys.path.insert(0, 'server')
from fastapi import HTTPException
from app.auth import merge_log_events
legacy = {'d':'2026-10-27','word':'apple','rating':3,'kind':'review'}
a = {**legacy, 'eventId':'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'}
b = {**legacy, 'eventId':'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'}
merged = merge_log_events([legacy, a], [legacy, b])
assert len(merged) == 3 and sum(x.get('eventId') is None for x in merged) == 1
assert len(merge_log_events(merged, [a, b])) == 3
assert len(merge_log_events([a, a], [])) == 1
bad = {**a, 'rating': 1}
try: merge_log_events([a], [bad])
except HTTPException as e: assert e.status_code == 409
else: raise AssertionError('conflicting event must be rejected')
print('PASS distinct log events, legacy compatibility, retries and conflict detection')
