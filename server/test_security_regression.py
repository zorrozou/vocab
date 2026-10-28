#!/usr/bin/env python3
"""Run against an isolated local instance: never use a production database."""
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

base = (sys.argv[1] if len(sys.argv) > 1 else 'http://127.0.0.1:18765').rstrip('/')

def request(path, body=None, token=None, method=None, guest=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    if guest:
        headers['X-Guest-Token'] = guest
    payload = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=payload, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.load(resp)

suffix = uuid.uuid4().hex[:10]
auth = request('/api/v1/auth/register', {'username': 'sec_' + suffix, 'password': 'test_password_123'})
token = auth['token']
uid = auth['user']['id']
query = '?device=u' + str(uid) + '&date=2026-10-27'
user = request('/api/v1/personalized' + query, token=token)
guest_token = request('/api/v1/auth/guest', body={})['token']
guest = request('/api/v1/personalized' + query, guest=guest_token)
assert user['device'] == 'account:' + auth['user']['account_id']
assert guest['device'].startswith('guest:v2:')
try:
    request('/api/v1/personalized' + query)
    raise AssertionError('public device ID was accepted without a guest credential')
except urllib.error.HTTPError as e:
    assert e.code == 401
try:
    request('/api/v1/personalized' + query, token='invalid')
    raise AssertionError('invalid bearer downgraded to guest')
except urllib.error.HTTPError as e:
    assert e.code == 401
word = request('/api/v1/lexicon/word?word=apple')
sentence = word['sentences'][0]['text']
params = urllib.parse.urlencode({'word': 'apple', 'text': sentence})
assert request('/api/v1/sentence/report?' + params, method='POST')['ok']
after = request('/api/v1/lexicon/word?word=apple')
assert sentence in [item['text'] for item in after['sentences']]
print('PASS guest namespace, invalid token and non-destructive report')

# Concurrent whole-state writes must not lose cards due to overlapping read/modify/write.
from concurrent.futures import ThreadPoolExecutor
import threading
workers = 12
barrier = threading.Barrier(workers)
def write_card(i):
    barrier.wait()
    state = {'cards': {f'word{i}': {'pos': i}}, 'log': [], 'pendingNew': [],
             'frontier': 1, 'pointer': 1, 'probeCount': 0}
    return request('/api/v1/me/state', state, token=token, method='PUT')
with ThreadPoolExecutor(max_workers=workers) as pool:
    assert all(result['ok'] for result in pool.map(write_card, range(workers)))
state = request('/api/v1/me/state', token=token)['state']
assert len(state['cards']) == workers, state['cards']
print('PASS simultaneous state writes retain all independent cards')

# Conflicting offline branches are rejected transactionally; neither branch is silently discarded.
name = 'cf_' + uuid.uuid4().hex[:10]
token2 = request('/api/v1/auth/register', {'username': name, 'password': 'test_password_123'})['token']
fsrs = {'state': 2, 'stability': 5, 'difficulty': 4, 'due': '2026-10-20T00:00:00Z',
        'step': None, 'lastReview': '2026-10-15T00:00:00Z'}
replay_base = {'is_new': False, 'state': 2, 'stability': 5, 'difficulty': 4, 'due': fsrs['due'],
        'step': None, 'last_review': fsrs['lastReview']}
def one_card(card):
    return {'cards': {'apple': card}, 'log': [], 'pendingNew': [], 'frontier': 1, 'pointer': 1, 'probeCount': 0}
pending = {'fsrs': fsrs, 'pendingFsrs': {'base': replay_base, 'events': [
    {'id': 'event-a', 'rating': 1, 'at': '2026-10-27T00:00:00Z'}]}}
request('/api/v1/me/state', one_card(pending), token=token2, method='PUT')
try:
    request('/api/v1/me/state', one_card({'fsrs': {**fsrs, 'lastReview': '2026-10-26T00:00:00Z'}}),
            token=token2, method='PUT')
    raise AssertionError('conflicting branch was accepted')
except urllib.error.HTTPError as e:
    assert e.code == 409
saved = request('/api/v1/me/state', token=token2)['state']
assert saved['cards']['apple']['pendingFsrs']['events'][0]['id'] == 'event-a'
print('PASS conflicting offline state returns 409 without changing server data')
