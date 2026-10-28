#!/usr/bin/env python3
"""Check optimizer input safety, service paths and atomic output in isolation."""
import importlib.util
import json
import sqlite3
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch
from fsrs import Scheduler

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('vocab_optimizer', root / 'pipeline/optimize_fsrs_user.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
assert module.DEFAULT_DATA == root / 'server/data'
now = datetime.now(timezone.utc)
start = now - timedelta(days=60)
events = [{'id':f'event-{i}', 'rating':(i % 4)+1,
           'at':(start + timedelta(hours=i)).isoformat()} for i in range(400)]
card = {'fsrsHistory':{'events':events}, 'appliedFsrs':[e['id'] for e in events]}
state = {'cards':{'apple':card}, 'log':[{'d':'2020-01-01','word':'apple','kind':'review','rating':3}] * 500}
assert len(module.collect_reviews(state, {'apple':7}, now)) == 400
duplicate = {'cards':{'apple':{'fsrsHistory':{'events':events + [events[0]]}, 'appliedFsrs':card['appliedFsrs']}}}
assert len(module.collect_reviews(duplicate, {'apple':7}, now)) == 400
assert not module.collect_reviews({'cards':{'apple':{**card,'pendingFsrs':{'events':[events[-1]]}}}}, {'apple':7}, now)
invalid = {'cards':{'apple':{'fsrsHistory':{'events':[{'id':'x','at':'2020-01-01','rating':3}]},'appliedFsrs':['x']}}}
assert not module.collect_reviews(invalid, {'apple':7}, now)
conflict = {'cards':{'apple':card, 'pear':{'fsrsHistory':{'events':[events[0]]},'appliedFsrs':[events[0]['id']]}}}
try: module.collect_reviews(conflict, {'apple':7,'pear':8}, now)
except ValueError: pass
else: raise AssertionError('conflicting IDs accepted')

with tempfile.TemporaryDirectory(prefix='vocab-optimizer-') as tmp:
    data = Path(tmp); account = 'a' * 32; target = data / f'fsrs_optimal_account_{account}.json'
    with sqlite3.connect(data / 'users.db') as db:
        db.execute('CREATE TABLE users(id INTEGER PRIMARY KEY,account_id TEXT)')
        db.execute('CREATE TABLE account_state(account_id TEXT PRIMARY KEY,state_json TEXT)')
        db.execute('INSERT INTO users VALUES(7,?)', (account,))
        db.execute('INSERT INTO account_state VALUES(?,?)', (account,json.dumps(state)))
    with sqlite3.connect(data / 'lexicon_v0.1.sqlite') as db:
        db.execute('CREATE TABLE lexicon_entry(id INTEGER,word TEXT)')
        db.execute("INSERT INTO lexicon_entry VALUES(7,'apple')")
    captured = []
    class FakeOptimizer:
        def __init__(self, reviews): captured.extend(reviews)
        def compute_optimal_parameters(self, verbose=False): return list(Scheduler().parameters)
    with patch.object(module, 'Optimizer', FakeOptimizer):
        assert module.optimize(7, data)
        result = json.loads(target.read_text())
        assert result['review_count'] == 400 and len(captured) == 400
        assert captured[0].review_datetime == datetime.fromisoformat(events[0]['at'])
        assert captured[-1].review_datetime == datetime.fromisoformat(events[-1]['at'])
        original = target.read_bytes()
        with patch.object(module.os, 'replace', side_effect=OSError('simulated failure')):
            try: module.optimize(7, data)
            except OSError: pass
            else: raise AssertionError('failed write was not reported')
        assert target.read_bytes() == original
        assert not list(data.glob('.fsrs-optimal-*'))
        state['cards']['apple']['appliedFsrs'].pop()
        with sqlite3.connect(data / 'users.db') as db:
            db.execute('UPDATE account_state SET state_json=?', (json.dumps(state),))
        assert not module.optimize(7, data)
        assert target.read_bytes() == original
    try: module.readonly(data / 'missing.db')
    except FileNotFoundError: pass
    else: raise AssertionError('missing database was created')
    assert not (data / 'missing.db').exists()
print('PASS optimizer paths, applied event selection, exact times, threshold and atomic replacement')
