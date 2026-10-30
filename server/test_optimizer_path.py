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
cards = {}
for n in range(20):
    events = [{'id':f'{n}-{i}','rating':1 if (n+i)%5==0 else 3,'at':(start+timedelta(days=i*2,minutes=n)).isoformat()} for i in range(21)]
    cards[f'word{n}'] = {'fsrsHistory':{'base':{'is_new':True},'events':events},'appliedFsrs':[e['id'] for e in events]}
state = {'cards':cards}
word2id = {w:i+1 for i,w in enumerate(cards)}
reviews = module.collect_reviews(state, word2id, now)
assert len(reviews)==420 and len(module.effective_reviews(reviews))==400
assert module.split_reviews(reviews) is not None
from copy import deepcopy
partial=deepcopy(state);partial['cards']['word0']['fsrsHistory']['base']['is_new']=False
assert len(module.effective_reviews(module.collect_reviews(partial,word2id,now)))==380
hourly=[{'id':str(i),'rating':3,'at':(start+timedelta(hours=i)).isoformat()} for i in range(400)]
hourly_state={'cards':{'word0':{'fsrsHistory':{'base':{'is_new':True},'events':hourly},'appliedFsrs':[e['id'] for e in hourly]}}}
assert module.split_reviews(module.collect_reviews(hourly_state,word2id,now)) is None
missing=deepcopy(state);missing['cards']['word0']['appliedFsrs'].pop()
assert len(module.collect_reviews(missing,word2id,now))==399

with tempfile.TemporaryDirectory(prefix='vocab-optimizer-') as tmp:
    data = Path(tmp); account = 'a' * 32; target = data / f'fsrs_optimal_account_{account}.json'
    with sqlite3.connect(data / 'users.db') as db:
        db.execute('CREATE TABLE users(id INTEGER PRIMARY KEY,account_id TEXT)')
        db.execute('CREATE TABLE account_state(account_id TEXT PRIMARY KEY,state_json TEXT)')
        db.execute('INSERT INTO users VALUES(7,?)', (account,))
        db.execute('INSERT INTO account_state VALUES(?,?)', (account,json.dumps(state)))
    with sqlite3.connect(data / 'lexicon_v0.1.sqlite') as db:
        db.execute('CREATE TABLE lexicon_entry(id INTEGER,word TEXT)')
        db.executemany("INSERT INTO lexicon_entry VALUES(?,?)",((i,w) for w,i in word2id.items()))
    captured = []
    class FakeOptimizer:
        def __init__(self, reviews): captured.extend(reviews)
        def compute_optimal_parameters(self, verbose=False): return list(Scheduler().parameters)
    with patch.object(module, 'Optimizer', FakeOptimizer):
        assert module.optimize(7, data)
        result = json.loads(target.read_text())
        assert result['review_count'] == 400 and 320 <= len(captured) < 420
        assert max(r.review_datetime for r in captured) < module.split_reviews(reviews)[1][0].review_datetime
        original = target.read_bytes()
        for worse in ({'log_loss':.6,'brier':.2,'count':80}, {'log_loss':.5,'brier':.3,'count':80}):
            with patch.object(module, 'validation_scores', side_effect=[{'log_loss':.5,'brier':.2,'count':80}, worse]):
                assert not module.optimize(7, data)
            assert target.read_bytes() == original
        with patch.object(module.os, 'replace', side_effect=OSError('simulated failure')):
            try: module.optimize(7, data)
            except OSError: pass
            else: raise AssertionError('failed write was not reported')
        assert target.read_bytes() == original
        assert not list(data.glob('.fsrs-optimal-*'))
        archives = list((data/'fsrs_parameter_history').glob('*.json'))
        assert len(archives)==1 and archives[0].read_bytes()==original
        state['cards']['word0']['appliedFsrs'].pop()
        with sqlite3.connect(data / 'users.db') as db:
            db.execute('UPDATE account_state SET state_json=?', (json.dumps(state),))
        assert not module.optimize(7, data)
        assert target.read_bytes() == original
    try: module.readonly(data / 'missing.db')
    except FileNotFoundError: pass
    else: raise AssertionError('missing database was created')
    assert not (data / 'missing.db').exists()
print('PASS optimizer paths, applied event selection, exact times, threshold and atomic replacement')
