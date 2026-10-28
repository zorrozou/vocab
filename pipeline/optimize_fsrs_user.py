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

from fsrs import Rating, ReviewLog, Scheduler
from fsrs.optimizer import Optimizer

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DATA = ROOT / 'server' / 'data'
MIN_REVIEWS = 400


def readonly(path):
    if not path.is_file():
        raise FileNotFoundError(f'Database not found: {path}')
    return sqlite3.connect('file:' + quote(str(path.resolve()), safe='/') + '?mode=ro', uri=True)


def collect_reviews(state, word2id, now):
    """Use only events known to be applied, with unique IDs and valid exact times."""
    seen = {}
    reviews = []
    cards = state.get('cards', {})
    if not isinstance(cards, dict):
        raise ValueError('Invalid cards in learning state')
    for word, card in cards.items():
        if not isinstance(card, dict) or card.get('pendingFsrs'):
            continue
        card_id = word2id.get(word)
        history, applied = card.get('fsrsHistory'), card.get('appliedFsrs')
        if not card_id or not isinstance(history, dict) or not isinstance(applied, list):
            continue
        applied = set(x for x in applied if isinstance(x, str))
        events = history.get('events')
        if not isinstance(events, list):
            continue
        for event in events:
            if not isinstance(event, dict):
                continue
            event_id, raw_time, rating = event.get('id'), event.get('at'), event.get('rating')
            if not isinstance(event_id, str) or not event_id or event_id not in applied:
                continue
            if not isinstance(rating, int) or isinstance(rating, bool) or rating not in (1, 2, 3, 4) or not isinstance(raw_time, str):
                continue
            try:
                at = datetime.fromisoformat(raw_time.replace('Z', '+00:00'))
                if at.tzinfo is None or at.utcoffset() is None:
                    continue
                at = at.astimezone(timezone.utc)
            except (ValueError, OverflowError):
                continue
            if at > now:
                continue
            signature = (int(card_id), rating, at)
            if event_id in seen:
                if seen[event_id] != signature:
                    raise ValueError('Conflicting rating event IDs')
                continue
            seen[event_id] = signature
            reviews.append((at, int(card_id), event_id, Rating(rating)))
    reviews.sort(key=lambda x: (x[0], x[1], x[2]))
    return [ReviewLog(card_id=card_id, rating=rating, review_datetime=at, review_duration=None)
            for at, card_id, _, rating in reviews]


def optimize(uid: int, data_dir: Path = DEFAULT_DATA):
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
    print(f'uid{uid}: 可验证精确时间且已应用的评分 {len(reviews)} 条')
    if len(reviews) < MIN_REVIEWS:
        print(f'uid{uid}: 少于{MIN_REVIEWS}条，保留现有参数；旧日期日志和待同步评分未用于训练')
        return False
    params = list(Optimizer(reviews).compute_optimal_parameters(verbose=False))
    if not all(isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) for v in params):
        raise ValueError('Invalid optimized parameters')
    Scheduler(parameters=params, desired_retention=0.9)  # Validate dimensions and bounds before replacing a file.
    result = {'user_id': uid, 'review_count': len(reviews), 'parameters': params,
              'desired_retention': 0.9, 'optimized_at': datetime.now(timezone.utc).isoformat()}
    target = data_dir / f'fsrs_optimal_account_{account_id}.json'
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
    parser.add_argument('--data-dir', type=Path, default=DEFAULT_DATA)
    parser.add_argument('user_id', type=int, nargs='+')
    args = parser.parse_args()
    try:
        for uid in args.user_id:
            optimize(uid, args.data_dir)
    except (OSError, ValueError, ImportError, sqlite3.Error, json.JSONDecodeError) as error:
        print(f'参数优化失败: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
