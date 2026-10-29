"""Causally ordered posterior evidence, shared by browser and native clients."""
import heapq
import math
import re
import uuid
from datetime import date
from fastapi import HTTPException


def fail(status, message):
    raise HTTPException(status, message)


def valid_id(value):
    return isinstance(value, str) and bool(re.fullmatch(r'[a-zA-Z0-9_-]{1,100}', value))


def study_scope(key):
    match = re.fullmatch(r'([pr])1_(\d{4}-\d{2}-\d{2})_([0-9a-f]{32})_[0-9a-f]{32}', key)
    return match.groups() if match else None


def preserve_study_budget(state):
    """Persist a conservative used-weight counter before history compaction."""
    per_word = {}
    for key, event in (state.get('posteriorHistory') or {}).get('events', {}).items():
        scope = study_scope(key)
        if scope and scope[0] == 'r':
            per_word[scope] = max(per_word.get(scope, 0), event['weight'])
    totals = {}
    for (_, day, _), weight in per_word.items():
        totals[day] = min(1.5, totals.get(day, 0) + weight)
    if not totals:
        return state
    raw_track = state.get('track')
    if raw_track is not None and not isinstance(raw_track, dict):
        fail(422, '水平追踪记录格式无效')
    track = dict(raw_track or {})
    previous_day = track.get('dayWDay') or ''
    if not isinstance(previous_day, str):
        fail(422, '水平证据日期无效')
    if previous_day:
        try:
            if date.fromisoformat(previous_day).isoformat() != previous_day:
                raise ValueError()
        except ValueError:
            fail(422, '水平证据日期无效')
    day = max(totals)
    if day < previous_day:
        return state
    prior = (track.get('dayW') or 0) if previous_day == day else 0
    if not isinstance(prior, (int, float)) or isinstance(prior, bool) or not math.isfinite(prior) or prior < 0:
        fail(422, '水平证据权重无效')
    track.update(dayWDay=day, dayW=max(prior, totals[day]))
    return {**state, 'track': track}


def replay(history, *, client_arithmetic=False):
    events = history['events']
    degree = {key: len(event['parents']) for key, event in events.items()}
    children = {key: [] for key in events}
    for key, event in events.items():
        for parent in event['parents']:
            if parent not in events:
                fail(422, '后验证据缺少因果事件')
            children[parent].append(key)
    ready = [(events[key]['day'], key) for key, value in degree.items() if value == 0]
    heapq.heapify(ready)
    post = history.get('base')
    post = list(post) if post is not None else None
    count = history['baseCount']
    diffused, visited = set(), 0
    observed, passive_weight = set(), {}
    while ready:
        _, key = heapq.heappop(ready)
        event = events[key]
        visited += 1
        if event['kind'] == 'update':
            weight = event['weight']
            scope = study_scope(key)
            if scope:
                if scope in observed:
                    weight = 0
                else:
                    observed.add(scope)
                    if scope[0] == 'r':
                        used = passive_weight.get(event['day'], 0)
                        weight = min(weight, max(0, 1.5 - used))
                        passive_weight[event['day']] = used + weight
            # Preserve legacy UUID evidence exactly. Only the new namespace
            # participates in cross-device deduplication and the passive budget.
            if scope and weight <= 1e-12:
                for child in children[key]:
                    degree[child] -= 1
                    if degree[child] == 0:
                        heapq.heappush(ready, (events[child]['day'], child))
                continue
            post = post if post is not None else [1 / 49] * 49
            result = []
            for i, value in enumerate(post):
                denominator = 1 + math.exp(-(i * 250 - event['rank']) / 400)
                # Swift and JavaScript compute the reciprocal first; the legacy
                # server divided directly. Near 1, the different rounding is
                # amplified when the failure likelihood is raised to a weight.
                scaled = ((1 - event['guess']) * (1 / denominator) if client_arithmetic
                          else (1 - event['guess']) / denominator)
                pk = event['guess'] + scaled
                likelihood = event['resp'] * pk + (1 - event['resp']) * (1 - pk)
                result.append(value * likelihood ** weight)
            total = sum(result)
            if total <= 0 or not math.isfinite(total):
                fail(422, '后验证据计算失败')
            post = [value / total for value in result]
            count += 1
        elif event['day'] not in diffused:
            if post is None:
                fail(422, '后验扩散缺少基线')
            k = math.exp(-(250 * 250) / (2 * 100 * 100))
            out = [v + k * ((post[i-1] if i else 0) + (post[i+1] if i+1 < len(post) else 0)) for i, v in enumerate(post)]
            total = sum(out)
            post = [v / total for v in out]
            diffused.add(event['day'])
        for child in children[key]:
            degree[child] -= 1
            if degree[child] == 0:
                heapq.heappush(ready, (events[child]['day'], child))
    if visited != len(events):
        fail(422, '后验证据因果关系存在循环')
    return post, count


def validate(state):
    history = state.get('posteriorHistory')
    if history is None:
        return None
    if not isinstance(history, dict) or history.get('algorithm') != 'bayes-grid-1' or not valid_id(history.get('baseId')):
        fail(422, '后验证据格式无效')
    base, count, events = history.get('base'), history.get('baseCount'), history.get('events')
    if not isinstance(count, int) or isinstance(count, bool) or count < 0 or not isinstance(events, dict):
        fail(422, '后验证据基线无效')
    if base is not None and (not isinstance(base, list) or not 1 <= len(base) <= 49 or any(not isinstance(x, (int, float)) or isinstance(x, bool) or not math.isfinite(x) or x < 0 for x in base) or not math.isclose(sum(base), 1, abs_tol=1e-8)):
        fail(422, '后验基线无效')
    if history['baseId'] == 'empty' and (base is not None or count != 0):
        fail(422, '空后验基线无效')
    for key, event in events.items():
        if not valid_id(key) or not isinstance(event, dict) or event.get('kind') not in ('update', 'diffuse') or not valid_id(event.get('device')) or not isinstance(event.get('at'), str) or len(event['at']) > 64:
            fail(422, '后验证据事件无效')
        scope = study_scope(key)
        if key.startswith(('p1_', 'r1_')) and (not scope or event['kind'] != 'update' or scope[1] != event.get('day')):
            fail(422, '学习证据身份或日期无效')
        parents = event.get('parents')
        if not isinstance(parents, list) or any(not valid_id(p) for p in parents) or len(parents) != len(set(parents)):
            fail(422, '后验证据因果关系无效')
        try:
            if not isinstance(event.get('day'), str) or date.fromisoformat(event['day']).isoformat() != event['day']:
                raise ValueError()
        except ValueError:
            fail(422, '后验证据日期无效')
        if event['kind'] == 'update':
            rank, resp, weight, guess = (event.get(k) for k in ('rank', 'resp', 'weight', 'guess'))
            if not isinstance(rank, int) or isinstance(rank, bool) or not 0 <= rank <= 12000 or resp not in (0, 1) or isinstance(resp, bool) or any(not isinstance(x, (int, float)) or isinstance(x, bool) or not math.isfinite(x) for x in (weight, guess)) or not 0 <= weight <= 10 or not 0 <= guess < 1:
                fail(422, '后验答题事件无效')
            if scope and (weight <= 0 or (scope[0] == 'p' and (weight != 1 or guess != .25)) or (scope[0] == 'r' and weight > .4)):
                fail(422, '学习证据权重无效')
    post, n = replay(history)
    actual = state.get('posterior')
    if n != state.get('probeCount', 0) or (post is None) != (actual is None):
        fail(409, '后验与证据不一致，请先导出进度并重新加载')
    if post is not None:
        if (not isinstance(actual, list) or len(post) != len(actual)
            or any(not isinstance(b, (int, float)) or isinstance(b, bool) or not math.isfinite(b) or b < 0 for b in actual)
            or not math.isclose(sum(actual), 1, rel_tol=0, abs_tol=1e-8)):
            fail(409, '后验与证据不一致，请先导出进度并重新加载')
        def matches(reference):
            return all(math.isclose(a, b, rel_tol=1e-9, abs_tol=1e-11) for a, b in zip(reference, actual))
        if not matches(post):
            client_post, _ = replay(history, client_arithmetic=True)
            if not matches(client_post):
                # A client may continue from a server-rounded posterior and then
                # apply further events using client arithmetic. Permit only a
                # small bounded discrepancy; callers persist canonical replay.
                if any(abs(a - b) > 1e-4 for a, b in zip(post, actual)):
                    fail(409, '后验与证据不一致，请先导出进度并重新加载')
    return history


def canonicalize(state):
    """Validate and replace any tolerated rounding drift with server replay."""
    history = validate(state)
    if history is None:
        return state
    post, count = replay(history)
    return preserve_study_budget({**state, 'posterior': post, 'probeCount': count})


def anchor(state):
    if state.get('posteriorHistory') is not None:
        validate(state)
        return state, False
    post, count = state.get('posterior'), state.get('probeCount', 0)
    if post is None and count == 0:
        return state, False
    history = {'algorithm': 'bayes-grid-1', 'baseId': str(uuid.uuid4()), 'base': post, 'baseCount': count, 'events': {}}
    result = {**state, 'posteriorHistory': history}
    validate(result)
    return result, True


def merge(old, new):
    left, right = validate(old), validate(new)
    if left is None and right is None:
        return None
    if left is None or right is None:
        missing, present = (old, right) if left is None else (new, left)
        if missing.get('posterior') is None and missing.get('probeCount', 0) == 0 and present['baseId'] == 'empty':
            return present
        fail(409, '旧版后验证据无法安全合并，请先导出进度并重新加载')
    if left['baseId'] != right['baseId'] or left.get('base') != right.get('base') or left['baseCount'] != right['baseCount']:
        fail(409, '后验基线不同，无法安全合并；请先导出进度')
    events = dict(left['events'])
    for key, event in right['events'].items():
        if key in events and events[key] != event:
            fail(409, '后验证据事件冲突，请先导出进度')
        events[key] = event
    result = {**left, 'events': events}
    replay(result)
    return result
