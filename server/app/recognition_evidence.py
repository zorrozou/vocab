"""Immutable stratified recognition observations, separate from legacy scores.

Old clients may omit this field. They cannot erase it by uploading a snapshot.
An explicit placement reset selects an entire epoch, just like bandEvidence.
Checkpointing preserves this ledger; practice logs are not assessment evidence.
"""
import re
import hashlib
import json
from datetime import datetime
from fastapi import HTTPException


def validate(state):
    events = state.get('recognitionEvidence')
    if events is None:
        return {}
    if not isinstance(events, dict):
        raise HTTPException(422, '词义识别证据格式无效')
    for key, e in events.items():
        if (not isinstance(key, str) or not re.fullmatch(r'[a-f0-9-]{8,64}', key)
            or not isinstance(e, dict)
            or set(e) != {'version', 'word', 'pos', 'at', 'correct', 'source', 'itemId'}
            or type(e['version']) is not int or e['version'] != 1
            or not isinstance(e['word'], str) or not 1 <= len(e['word']) <= 100
            or type(e['pos']) is not int or not 1 <= e['pos'] <= 10987
            or not isinstance(e['correct'], bool)
            or e['source'] not in ('placement', 'probe', 'legacy')
            or not isinstance(e['itemId'], str) or not re.fullmatch(r'[a-f0-9]{64}', e['itemId'])
            or not isinstance(e['at'], str) or len(e['at']) > 64):
            raise HTTPException(422, '词义识别答题记录无效')
        try:
            if datetime.fromisoformat(e['at'].replace('Z', '+00:00')).tzinfo is None:
                raise ValueError()
        except ValueError:
            raise HTTPException(422, '词义识别答题时间无效')
    return events


def preserve_legacy(state):
    """Materialize only provable stratified answers before history compaction."""
    bands = ((1,2000),(2001,4000),(4001,6000),(6001,8000),(8001,10000),(10001,10987))
    old = sorted(((key,e) for b in (state.get('bandEvidence') or {}).values()
                  for key,e in b['events'].items()), key=lambda pair:(pair[1]['at'],pair[0]))[:12]
    if len(old) != 12 or len({e['pos'] for _,e in old}) != 12:
        return state
    if any(not bands[i//2][0] <= e['pos'] <= bands[i//2][1] for i,(_,e) in enumerate(old)):
        return state
    words = {key:word for word,b in (state.get('knowledgeEvidence') or {}).items() for key in b['events']}
    if any(key not in words for key,_ in old):
        return state
    try:
        if any(datetime.fromisoformat(e['at'].replace('Z', '+00:00')).tzinfo is None for _,e in old):
            return state
    except ValueError:
        return state
    events = dict(validate(state))
    for key,e in old:
        if key not in events:
            events[key] = {'version':1,'word':words[key],'pos':e['pos'],'at':e['at'],
                           'correct':e['ok'],'source':'legacy',
                           'itemId':hashlib.sha256(json.dumps(['legacy-strata-12',key,e],sort_keys=True).encode()).hexdigest()}
    result = {**state,'recognitionEvidence':events}
    validate(result)
    return result


def merge(old, new):
    events = dict(validate(old))
    for key, event in validate(new).items():
        if key in events and events[key] != event:
            raise HTTPException(409, '同一词义识别作答存在冲突，已保留两端进度')
        events[key] = event
    return events
