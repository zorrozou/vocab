"""Versioned study evidence preserves answers but not duplicate information."""
import copy
import json
import os
import sys
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone

sys.path.insert(0, 'server')
from app.posterior_evidence import replay, validate

BASE = os.environ.get('VOCAB_TEST_BASE', 'http://127.0.0.1:18765').rstrip('/')
day = datetime.now(timezone.utc).date().isoformat()


def call(path, body=None, token=None, method=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(BASE + path, None if body is None else json.dumps(body).encode(), headers, method=method)
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)


def account():
    a = call('/api/v1/auth/register', {'username': 'evidence_' + uuid.uuid4().hex[:10], 'password': 'isolated_test_123'})
    return a['token']


def state(events, logs=None):
    history = {'algorithm': 'bayes-grid-1', 'baseId': 'empty', 'base': None, 'baseCount': 0, 'events': events}
    post, count = replay(history)
    return {'v': 1, 'cards': {}, 'log': logs or [], 'settings': {}, 'pendingNew': [],
            'posteriorHistory': history, 'posterior': post, 'probeCount': count}


def event(weight=1., parents=None, resp=1):
    return {'kind': 'update', 'device': uuid.uuid4().hex, 'at': day + 'T00:00:00Z', 'day': day,
            'parents': parents or [], 'rank': 6000, 'resp': resp, 'weight': weight, 'guess': .25}


def grade(word, kind):
    return {'d': day, 'word': word, 'kind': kind, 'rating': 3, 'eventId': uuid.uuid4().hex}


token = account()
body = {'day': day, 'offset_minutes': 0, 'candidates': [{'word': 'apple', 'kind': 'probe'}]}
plan = call('/api/v1/me/study-plan', body, token)
key = plan['items'][0]['probe_evidence_key']
assert call('/api/v1/me/study-plan', body, token)['items'][0]['probe_evidence_key'] == key
assert call('/api/v1/me/study-plan', body, account())['items'][0]['probe_evidence_key'] != key
left_id, right_id = key + uuid.uuid4().hex, key + uuid.uuid4().hex
left = state({left_id: event()}, [grade('apple', 'probe')])
right = state({right_id: event(resp=0)}, [grade('apple', 'probe')])
call('/api/v1/me/state', left, token, 'PUT')
call('/api/v1/me/state', right, token, 'PUT')
merged = call('/api/v1/me/state', token=token)['state']
assert merged['probeCount'] == 1 and len(merged['posteriorHistory']['events']) == 2 and len(merged['log']) == 2
# Reversing arrival order must produce the same effective evidence. Event IDs
# stay unique, so opposing causal branches cannot collapse into a graph cycle.
other = account()
call('/api/v1/me/state', right, other, 'PUT')
call('/api/v1/me/state', left, other, 'PUT')
assert call('/api/v1/me/state', token=other)['state']['posterior'] == merged['posterior']

# Old clients preserve the scoped IDs as ordinary strings. Their later legacy
# update remains valid after downloading a deduplicated result.
legacy = copy.deepcopy(merged)
events = legacy['posteriorHistory']['events']
events[uuid.uuid4().hex] = event(parents=list(events))
legacy['posterior'], legacy['probeCount'] = replay(legacy['posteriorHistory'])
call('/api/v1/me/state', legacy, token, 'PUT')
assert call('/api/v1/me/state', token=token)['state']['probeCount'] == 2

# Independent devices may each have 1.2 passive weight. The merge caps new
# scoped evidence at 1.5, while retaining all six observations and real grades.
token = account()
plan = call('/api/v1/me/study-plan', {'day': day, 'offset_minutes': 0,
    'candidates': [{'word': 'review' + str(i), 'kind': 'review'} for i in range(6)]}, token)
branches = []
for items in (plan['items'][:3], plan['items'][3:]):
    events, logs = {}, []
    for item in items:
        events[item['review_evidence_key'] + uuid.uuid4().hex] = event(.4, list(events)[-1:])
        logs.append(grade(item['word'], 'review'))
    branches.append(state(events, logs))
    assert branches[-1]['probeCount'] == 3
for branch in branches:
    call('/api/v1/me/state', branch, token, 'PUT')
merged = call('/api/v1/me/state', token=token)['state']
expected, _ = replay(state({'legacy': event(1.5)})['posteriorHistory'])
assert all(abs(a-b) < 1e-12 for a, b in zip(expected, merged['posterior']))
assert len(merged['posteriorHistory']['events']) == 6 and len(merged['log']) == 6 and merged['probeCount'] == 4
assert merged['track']['dayWDay'] == day and merged['track']['dayW'] == 1.5
before = call('/api/v1/me/state', token=token)
compacted = call('/api/v1/me/state/checkpoint', {'expected_updated_at': before['updated_at']}, token)
assert compacted['state']['posteriorHistory']['events'] == {}
assert compacted['state']['track']['dayW'] == 1.5, 'compaction must not release the used daily weight'
head = call('/api/v1/me/state', token=token)
restored = call('/api/v1/me/state/restore', {'state': before['state'], 'expected_updated_at': head['updated_at']}, token)
assert restored['state']['track']['dayW'] == 1.5 and restored['state']['posterior'] == merged['posterior']
for tracking in ('invalid', {'dayWDay':'invalid','dayW':0}):
    bad = copy.deepcopy(restored['state']); bad['track'] = tracking
    try:
        call('/api/v1/me/state', bad, token, 'PUT')
    except urllib.error.HTTPError as exc:
        assert exc.code == 422
    else:
        raise AssertionError('Malformed tracking data was accepted')

# Two probes answered in reverse order retain a valid causal graph, two unique
# words and all four answer events. No history is rewritten to share an ID.
keys = ['p1_' + day + '_' + str(i) * 32 + '_' for i in range(2)]
events = {}
for order in (keys, list(reversed(keys))):
    parent = []
    for prefix in order:
        identity = prefix + uuid.uuid4().hex
        events[identity] = event(parents=parent)
        parent = [identity]
check = state(events)
assert check['probeCount'] == 2 and len(events) == 4
validate(check)
# Existing unscoped observations are not retroactively classified or removed.
old = state({'old-a': event(), 'old-b': event()})
assert old['probeCount'] == 2
# A new day supplies independent delayed information; day binding is validated.
tomorrow = '2099-01-01'
later = event(); later['day'] = tomorrow
different_days = state({keys[0] + uuid.uuid4().hex: event(),
    'p1_' + tomorrow + '_' + '0' * 32 + '_' + uuid.uuid4().hex: later})
assert different_days['probeCount'] == 2
validate(different_days)
print('PASS shared probe deduplication, arrival-order stability, legacy continuation, passive 1.5 cap and opposing causal branches; actual grades retained')
