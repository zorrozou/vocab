"""Upgrade a date-only legacy card without losing either device's progress."""
import copy
import json
import os
import urllib.error
import urllib.request
import uuid

BASE = os.environ.get('VOCAB_TEST_BASE', 'http://127.0.0.1:18765').rstrip('/')


def call(path, body=None, token=None, method=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    request = urllib.request.Request(BASE + path, None if body is None else json.dumps(body).encode(), headers, method=method)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def account():
    return call('/api/v1/auth/register', {'username': 'origin_' + uuid.uuid4().hex[:10],
        'password': 'isolated_test_123'})['token']


def states(token):
    # Both clients already use day + T08:00:00Z when a legacy card has no
    # precise last review. The server must verify that same origin from logs.
    fsrs = {'state': 2, 'stability': 2.307, 'difficulty': 2.111,
            'due': '2026-10-22T04:06:57.077949+00:00'}
    legacy = {'v': 1, 'cards': {'apple': {'fsrs': fsrs}}, 'pendingNew': [], 'settings': {},
              'log': [{'word': 'apple', 'd': '2026-10-20', 'kind': 'review', 'rating': 3},
                      {'word': 'apple', 'd': '2026-10-23', 'kind': 'exposure', 'rating': 3}]}
    origin = {**fsrs, 'is_new': False, 'rating': 4, 'last_review': '2026-10-20T08:00:00Z'}
    event = {'id': uuid.uuid4().hex, 'rating': 4, 'at': '2026-10-24T07:20:13.229Z'}
    response = call('/api/v1/fsrs/review', {**origin, 'now': event['at'], 'deterministic': True}, token)
    event['schedulerKey'] = response['scheduler_key']
    current = {k: response[k] for k in ('state', 'stability', 'difficulty', 'due', 'step')}
    current['lastReview'] = response['last_review']
    modern = copy.deepcopy(legacy)
    modern['cards']['apple'] = {'fsrs': current, 'due': current['due'],
        'fsrsHistory': {'base': origin, 'events': [event]}, 'appliedFsrs': [event['id']],
        'fsrsReplayVersions': {event['id']: event['schedulerKey']}}
    modern['log'].append({'word': 'apple', 'd': '2026-10-24', 'kind': 'review', 'rating': 4,
                         'eventId': event['id'], 'at': event['at']})
    return legacy, modern


for reverse in (False, True):
    token = account()
    legacy, modern = states(token)
    legacy['cards']['server_only'] = {'pos': 2}
    modern['cards']['phone_only'] = {'pos': 3}
    branches = [legacy, modern] if not reverse else [modern, legacy]
    for branch in branches:
        call('/api/v1/me/state', branch, token, 'PUT')
    merged = call('/api/v1/me/state', token=token)['state']
    assert set(merged['cards']) == {'apple', 'server_only', 'phone_only'}
    assert merged['cards']['apple'] == modern['cards']['apple']
    assert len(merged['log']) == 3, 'old and new study records must survive exactly once'
    for branch in branches:
        call('/api/v1/me/state', branch, token, 'PUT')
    again = call('/api/v1/me/state', token=token)['state']
    assert again['cards'] == merged['cards'] and again['log'] == merged['log']

# The exception is narrow: real state differences, a different source day,
# explicit timestamps, or unknown scores must still fail without any write.
for mutation in ('stability', 'difficulty', 'due', 'state', 'step', 'explicit_time',
                 'missing_log', 'later_review', 'invalid_day', 'different_base_time',
                 'unknown_applied', 'unknown_pending', 'missing_version'):
    token = account()
    legacy, modern = states(token)
    fsrs = legacy['cards']['apple']['fsrs']
    if mutation in ('stability', 'difficulty', 'state', 'step'):
        fsrs[mutation] = 3
    elif mutation == 'due':
        fsrs['due'] = '2026-10-23T04:06:57.077949+00:00'
    elif mutation == 'explicit_time':
        fsrs['lastReview'] = '2026-10-20T09:00:00Z'
    elif mutation == 'missing_log':
        legacy['log'] = []
    elif mutation == 'later_review':
        legacy['log'].append({'word': 'apple', 'd': '2026-10-21', 'kind': 'review', 'rating': 3})
    elif mutation == 'invalid_day':
        legacy['log'][0]['d'] = 'invalid'
    elif mutation == 'different_base_time':
        modern['cards']['apple']['fsrsHistory']['base']['last_review'] = '2026-10-20T09:00:00Z'
    elif mutation == 'unknown_applied':
        legacy['cards']['apple']['appliedFsrs'] = ['unknown-score']
    elif mutation == 'unknown_pending':
        legacy['cards']['apple']['pendingFsrs'] = {'base': {'is_new': True}, 'events': [
            {'id': 'unknown-score', 'rating': 3, 'at': '2026-10-21T08:00:00Z'}]}
    else:
        modern['cards']['apple']['fsrsHistory']['events'][0].pop('schedulerKey')
        modern['cards']['apple'].pop('fsrsReplayVersions')
    call('/api/v1/me/state', legacy, token, 'PUT')
    before = call('/api/v1/me/state', token=token)
    try:
        call('/api/v1/me/state', modern, token, 'PUT')
        raise AssertionError('unsafe legacy merge accepted: ' + mutation)
    except urllib.error.HTTPError as error:
        assert error.code == 409, (mutation, error.code, error.read())
    after = call('/api/v1/me/state', token=token)
    assert after['state'] == before['state'] and after['state_revision'] == before['state_revision'], mutation

print('PASS date-only legacy origin migration, both upload orders, idempotency and unsafe-fork preservation')
