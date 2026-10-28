#!/usr/bin/env python3
"""Prove forked online/offline card histories replay once and reject unsafe versions."""
import copy
import sys
from fastapi import HTTPException

sys.path.insert(0, sys.argv[1] if len(sys.argv) > 1 else 'server')
from app import auth, main
main.init_db()  # test app copy, not a production database

base = {'is_new': True, 'state': 1, 'stability': 0, 'difficulty': 0, 'rating': 3}
a = {'id': 'event-a', 'rating': 3, 'at': '2026-10-20T00:00:00Z'}
b = {'id': 'event-b', 'rating': 1, 'at': '2026-10-21T00:00:00Z'}


def replay(events, key=None):
    body = dict(base)
    for event in events:
        result = main.fsrs_review(main.FsrsIn(**{**body, 'rating': event['rating'], 'now': event['at'], 'deterministic': True, 'scheduler_key': key}), authorization='')
        key = result['scheduler_key']
        body = {k: result[k] for k in ('state', 'stability', 'difficulty', 'due', 'step', 'last_review')}
    return result


def state():
    return {'v': 1, 'cards': {}, 'log': [], 'pendingNew': [], 'settings': {}, 'pointer': 1, 'frontier': 0}


def branch(event):
    r = replay([event])
    fsrs = {k: r[k] for k in ('state', 'stability', 'difficulty', 'due', 'step', 'scheduled_days')}
    fsrs['lastReview'] = r['last_review']
    s = state()
    s['cards']['apple'] = {'fsrs': fsrs, 'due': fsrs['due'], 'appliedFsrs': [event['id']],
                            'fsrsHistory': {'base': base, 'events': [event], 'schedulerKey': r['scheduler_key']}}
    return s

left, right = branch(a), branch(b)
for old, new in ((left, right), (right, left)):
    merged = auth.merge_learning_states(old, new)
    card = merged['cards']['apple']
    assert [e['id'] for e in card['pendingFsrs']['events']] == ['event-a', 'event-b']
    assert all(e['schedulerKey'] == left['cards']['apple']['fsrsHistory']['schedulerKey'] for e in card['pendingFsrs']['events'])
    assert not (set(card.get('appliedFsrs', [])) & {'event-a', 'event-b'})
    expected = replay([a, b], card['pendingFsrs']['events'][0]['schedulerKey'])
    card['fsrs'] = {k: expected[k] for k in ('state', 'stability', 'difficulty', 'due', 'step', 'scheduled_days')}
    card['fsrs']['lastReview'] = expected['last_review']
    card['due'] = expected['due']
    card['appliedFsrs'] = ['event-a', 'event-b']
    card['fsrsReplayVersions'] = {e['id']:e['schedulerKey'] for e in card['fsrsHistory']['events']}
    del card['pendingFsrs']
    again = auth.merge_learning_states(merged, old)['cards']['apple']
    assert 'pendingFsrs' not in again and set(again['appliedFsrs']) == {'event-a', 'event-b'}
    assert again['fsrs'] == card['fsrs']

# Swift omits nullable fields that JavaScript serializes as null; they are the same state.
web_state, swift_state = branch(a), branch(a)
swift_state['cards']['apple']['fsrs'].pop('scheduled_days', None)
swift_state['cards']['apple']['fsrs'].pop('step', None) if swift_state['cards']['apple']['fsrs'].get('step') is None else None
assert 'pendingFsrs' not in auth.merge_learning_states(web_state, swift_state)['cards']['apple']

# Both devices can also be offline before either applies an event.
offline1, offline2 = state(), state()
for s, event in ((offline1, a), (offline2, b)):
    s['cards']['apple'] = {'fsrsHistory': {'base': base, 'events': [event]},
                            'pendingFsrs': {'base': base, 'events': [event]}}
assert auth.merge_learning_states(offline1, offline2)['cards']['apple']['pendingFsrs']['events'] == [a, b]

# Reused IDs, different roots and changed scheduler parameters are not silently merged.
for mutate in ('event', 'root', 'scheduler', 'unknown_scheduler'):
    altered = copy.deepcopy(right)
    h = altered['cards']['apple']['fsrsHistory']
    if mutate == 'event':
        h['events'][0] = {**a, 'rating': 4}
    elif mutate == 'root':
        h['base'] = {'is_new': False, 'state': 2, 'stability': 1, 'difficulty': 5}
    elif mutate == 'scheduler':
        h['events'][0] = {**a, 'schedulerKey': 'another-version'}
    else:
        del h['schedulerKey']
    try:
        auth.merge_learning_states(left, altered)
        raise AssertionError('unsafe fork accepted: ' + mutate)
    except HTTPException as e:
        assert e.status_code == 409
try:
    replay([a], 'another-version')
    raise AssertionError('changed FSRS parameters accepted')
except HTTPException as e:
    assert e.status_code == 409

# A shared queued event from a legacy snapshot may fill missing version metadata.
modern = state(); modern['cards']['apple'] = {'fsrsHistory': {'base':base, 'events':[a]}, 'pendingFsrs': {'base':base, 'events':[a]}}
legacy_pending = state(); legacy_pending['cards']['apple'] = {'pendingFsrs': {'base':base, 'events':[a], 'schedulerKey':'original'}}
retained = auth.merge_learning_states(modern, legacy_pending)['cards']['apple']
assert retained['fsrsHistory']['events'][0]['schedulerKey'] == 'original'
assert retained['pendingFsrs']['events'][0]['schedulerKey'] == 'original'
conflicting = copy.deepcopy(legacy_pending)
conflicting['cards']['apple']['pendingFsrs']['schedulerKey'] = 'different'
try:
    auth.merge_learning_states({'v':1, 'cards':{'apple':retained}}, conflicting)
    raise AssertionError('conflicting legacy pending version accepted')
except HTTPException as e:
    assert e.status_code == 409

# A stale pre-upgrade copy at the verified origin is safe; an untracked fork is not.
legacy = state(); legacy['cards']['apple'] = {}
legacy_merge = auth.merge_learning_states(left, legacy)['cards']['apple']
assert [e['id'] for e in legacy_merge['pendingFsrs']['events']] == ['event-a']
legacy['cards']['apple'] = {'fsrs': {'state': 2, 'stability': 99, 'difficulty': 5}}
try:
    auth.merge_learning_states(left, legacy)
    raise AssertionError('untracked legacy fork accepted')
except HTTPException as e:
    assert e.status_code == 409

print('PASS shared-origin forks, deterministic replay, idempotency, legacy and scheduler conflicts')
