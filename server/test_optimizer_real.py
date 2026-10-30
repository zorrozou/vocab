#!/usr/bin/env python3
"""Run the optional upstream optimizer on disposable synthetic event history."""
import importlib.util
import json
import sqlite3
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from fsrs import Scheduler

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('vocab_optimizer_real', root / 'pipeline/optimize_fsrs_user.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
start = datetime.now(timezone.utc) - timedelta(days=100)
cards = {}
for card in range(24):
    events = []
    for i in range(20):
        at = start + timedelta(days=i * 3, minutes=card)
        rating = 1 if (i + card) % 7 == 0 else (2 if (i + card) % 5 == 0 else 3)
        events.append({'id':f'{card}-{i}', 'rating':rating, 'at':at.isoformat()})
    cards[f'word{card}'] = {'fsrsHistory':{'base':{'is_new':True},'events':events}, 'appliedFsrs':[e['id'] for e in events]}
with tempfile.TemporaryDirectory(prefix='vocab-optimizer-real-') as tmp:
    data = Path(tmp); account = 'a' * 32
    with sqlite3.connect(data / 'users.db') as db:
        db.execute('CREATE TABLE users(id INTEGER PRIMARY KEY,account_id TEXT)')
        db.execute('CREATE TABLE account_state(account_id TEXT PRIMARY KEY,state_json TEXT)')
        db.execute('INSERT INTO users VALUES(7,?)', (account,))
        db.execute('INSERT INTO account_state VALUES(?,?)', (account,json.dumps({'cards':cards})))
    with sqlite3.connect(data / 'lexicon_v0.1.sqlite') as db:
        db.execute('CREATE TABLE lexicon_entry(id INTEGER,word TEXT)')
        db.executemany('INSERT INTO lexicon_entry VALUES(?,?)', ((i+1,f'word{i}') for i in range(24)))
    accepted = module.optimize(7, data)
    target = data / f'fsrs_optimal_account_{account}.json'
    if accepted:
        result = json.loads(target.read_text())
        assert result['review_count'] == 456
        Scheduler(parameters=result['parameters'], desired_retention=result['desired_retention'])
        for key in ('log_loss','brier'): assert result['validation']['candidate'][key] <= result['validation']['baseline'][key]+1e-12
    else: assert not target.exists(), 'a worse candidate must never replace the default'

print('PASS real upstream training and held-out gate; activated=' + str(accepted))
