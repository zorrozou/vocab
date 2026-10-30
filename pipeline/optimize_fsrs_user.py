# -*- coding: utf-8 -*-
"""Optimize FSRS from applied, precisely timestamped rating events.

By default, read and write the same server/data directory as the API. Use
--data-dir when the deployed API stores data elsewhere. Legacy date-only logs
and pending events cannot be ordered reliably and are not used for training.
"""
import argparse
import json
import math
import os
import sqlite3
import sys
import tempfile
from contextlib import closing
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

from fsrs import Card, Rating, ReviewLog, Scheduler
Optimizer = None  # Optional heavy dependency is loaded only when a fit is eligible.

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DATA = ROOT / 'server' / 'data'
sys.path.insert(0, str(ROOT / 'server' if (ROOT / 'server/app').is_dir() else ROOT))
from app.training_data import training_data, MIN_OBSERVATIONS
MIN_REVIEWS = MIN_OBSERVATIONS


def readonly(path):
    if not path.is_file():
        raise FileNotFoundError(f'Database not found: {path}')
    return sqlite3.connect('file:' + quote(str(path.resolve()), safe='/') + '?mode=ro', uri=True)


def collect_reviews(state, word2id, now):
    """Only complete new-card histories; an invalid/missing step excludes the card."""
    records, _ = training_data(state, now, word2id)
    return [ReviewLog(card_id=int(word2id[word]),rating=Rating(rating),review_datetime=at,review_duration=None)
            for at,word,_,rating in records]


def effective_reviews(reviews):
    previous, effective = {}, []
    for review in reviews:
        prior = previous.get(review.card_id)
        if prior and (review.review_datetime-prior).days > 0: effective.append(review)
        previous[review.card_id] = review.review_datetime
    return effective


def split_reviews(reviews):
    effective = effective_reviews(reviews)
    if len(effective) < MIN_REVIEWS: return None
    cutoff = effective[int(len(effective)*.8)].review_datetime
    train = [r for r in reviews if r.review_datetime < cutoff]
    test = [r for r in effective if r.review_datetime >= cutoff]
    train_effective = effective_reviews(train)
    # Both outcomes must be represented; no automatic fit on only memorized examples.
    if len(train_effective) < 320 or len(test) < 80: return None
    for group in (train_effective,test):
        if {r.rating == Rating.Again for r in group} != {True,False}: return None
    return train, test


def validation_scores(parameters, reviews, test):
    scheduler = Scheduler(parameters=parameters,desired_retention=.9,enable_fuzzing=False)
    keys = {(r.card_id,r.review_datetime) for r in test}
    cards, losses, briers = {}, [], []
    for r in reviews:
        c = cards.get(r.card_id) or Card(card_id=r.card_id,due=r.review_datetime)
        if (r.card_id,r.review_datetime) in keys:
            keys.remove((r.card_id,r.review_datetime))
            probability = min(1-1e-9,max(1e-9,float(scheduler.get_card_retrievability(c,r.review_datetime))))
            outcome = int(r.rating != Rating.Again)
            losses.append(-math.log(probability if outcome else 1-probability))
            briers.append((probability-outcome)**2)
        cards[r.card_id],_ = scheduler.review_card(c,r.rating,review_datetime=r.review_datetime)
    if not losses: raise ValueError('No valid held-out observations')
    return {'log_loss':sum(losses)/len(losses),'brier':sum(briers)/len(briers),'count':len(losses)}


def optimize(uid: int, data_dir: Path = DEFAULT_DATA, check_only=False):
    global Optimizer
    data_dir = Path(data_dir)
    with closing(readonly(data_dir / 'users.db')) as conn:
        row = conn.execute('SELECT u.account_id,s.state_json FROM users u JOIN account_state s ON s.account_id=u.account_id WHERE u.id=?', (uid,)).fetchone()
    if not row:
        print(f'uid{uid}: 无学习状态')
        return False
    account_id, state_json = row
    if not isinstance(account_id, str) or len(account_id) != 32 or any(c not in '0123456789abcdef' for c in account_id):
        raise ValueError('Invalid account identity')
    state = json.loads(state_json)
    with closing(readonly(data_dir / 'lexicon_v0.1.sqlite')) as lex:
        word2id = dict(lex.execute('SELECT word,id FROM lexicon_entry'))
    reviews = collect_reviews(state, word2id, datetime.now(timezone.utc))
    _, readiness = training_data(state, datetime.now(timezone.utc), word2id)
    if check_only:
        print(json.dumps({"user_id":uid, **readiness},ensure_ascii=False,sort_keys=True))
        return readiness["eligible"]
    split = split_reviews(reviews)
    effective = len(effective_reviews(reviews))
    print(f'uid{uid}: 完整历史有效跨日观测 {effective} 条')
    if split is None:
        print(f'uid{uid}: 样本或留出集不足，保留现有参数')
        return False
    train, test = split
    if Optimizer is None:
        try:
            from fsrs.optimizer import Optimizer
        except ImportError as error:
            raise RuntimeError('优化器依赖未安装；请在隔离训练环境执行，现有参数未改动') from error
    params = list(Optimizer(train).compute_optimal_parameters(verbose=False))
    if not all(type(v) in (int,float) and math.isfinite(v) for v in params): raise ValueError('Invalid optimized parameters')
    Scheduler(parameters=params,desired_retention=.9)
    target = data_dir / f'fsrs_optimal_account_{account_id}.json'
    prior = json.loads(target.read_text()) if target.exists() else {'parameters':list(Scheduler().parameters)}
    baseline = validation_scores(prior['parameters'],reviews,test)
    candidate = validation_scores(params,reviews,test)
    print(json.dumps({'baseline':baseline,'candidate':candidate},sort_keys=True))
    if any(candidate[k] > baseline[k] + 1e-12 for k in ('log_loss','brier')):
        print(f'uid{uid}: 留出验证未改善，保留现有参数')
        return False
    result = {'user_id':uid,'review_count':effective,'parameters':params,'desired_retention':.9,
              'optimized_at':datetime.now(timezone.utc).isoformat(),'validation':{'baseline':baseline,'candidate':candidate,'training_observations':len(effective_reviews(train))}}
    # Preserve the exact previous version before atomic activation of this tested candidate.
    if target.exists():
        import hashlib
        raw = target.read_bytes(); archive = data_dir / 'fsrs_parameter_history'; archive.mkdir(exist_ok=True)
        backup = archive / (account_id + '-' + hashlib.sha256(raw).hexdigest() + '.json')
        if not backup.exists(): backup.write_bytes(raw)
    fd, temporary = tempfile.mkstemp(prefix='.fsrs-optimal-', dir=data_dir)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(result, f, ensure_ascii=False, indent=2, allow_nan=False)
            f.write('\n')
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f'uid{uid}: 已保存 {target}')
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='只报告有效样本与留出集条件，不训练、不写入参数')
    parser.add_argument('--data-dir', type=Path, default=DEFAULT_DATA)
    parser.add_argument('user_id', type=int, nargs='+')
    args = parser.parse_args()
    try:
        for uid in args.user_id:
            optimize(uid, args.data_dir, check_only=args.check)
    except (OSError, ValueError, RuntimeError, ImportError, sqlite3.Error, json.JSONDecodeError) as error:
        print(f'参数优化失败: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
