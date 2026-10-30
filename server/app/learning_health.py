"""Read-only learning diagnostics and deterministic repair from retained history."""
from copy import deepcopy
from datetime import datetime, timezone
import json
from fastapi import HTTPException
from app.study_policy import instant, is_mastered


def training_observations(cards, now):
    # Same first-64-per-card and whole elapsed-day rule as the pinned optimizer.
    observations=[]
    for card in cards.values():
        h=card.get('fsrsHistory') or {}
        if card.get('pendingFsrs') or (h.get('base') or {}).get('is_new') is not True: continue
        events=h.get('events') or []
        if not events or set(card.get('appliedFsrs') or [])!={e.get('id') for e in events}:continue
        if any(instant(e.get('at')) is None or instant(e['at'])>now or type(e.get('rating')) is not int or e['rating'] not in (1,2,3,4) for e in events):continue
        unique={e['id']:e for e in events}
        if any(unique[e['id']]!=e for e in events):continue
        previous=None
        for e in sorted(unique.values(),key=lambda e:(instant(e['at']),e['id']))[:64]:
            at=instant(e['at'])
            if previous is not None and at-previous>=86400: observations.append((at,e['rating']==1))
            previous=at
    observations.sort()
    return len(observations)


def health(state, now=None):
    now = now or datetime.now(timezone.utc).timestamp()
    cards = state.get('cards') or {}
    counters = {'observations': 0, 'remembered': 0, 'forgotten': 0, 'hard': 0}
    by_day, seen = {}, set()
    pending = sum(len((c.get('pendingFsrs') or {}).get('events', [])) for c in cards.values())
    issues = [{'word': w, 'reason': c['fsrsIssue']} for w,c in sorted(cards.items()) if c.get('fsrsIssue')]
    for word, card in cards.items():
        pending_ids = {e['id'] for e in (card.get('pendingFsrs') or {}).get('events', [])}
        previous = None
        for key, event in sorted(((card.get('studyEvidence') or {}).get('events') or {}).items(), key=lambda x:(instant(x[1].get('at')) or 0, x[0])):
            at, prior = instant(event.get('at')), instant(event.get('priorAt'))
            if at is None: continue
            candidates = [v for v in (prior, previous) if v is not None]
            gap = at-max(candidates) if candidates else 0
            previous = at
            if key in seen: continue
            seen.add(key)
            if not now-28*86400 <= at <= now: continue
            day = event.get('day', '')
            row = by_day.setdefault(day, {'words': set(), 'attempts': 0})
            row['words'].add(word); row['attempts'] += 1
            if key in pending_ids or gap < 86400 or event.get('kind') not in ('review','drill') or not event.get('verified') or event.get('hinted'): continue
            counters['observations'] += 1
            rating = event.get('rating')
            if rating == 1 or event.get('guessed'): counters['forgotten'] += 1
            else:
                counters['remembered'] += 1
                if rating == 2: counters['hard'] += 1
    def mastered(c):
        try: return is_mastered(c)
        except (TypeError,ValueError,KeyError): return False
    due = sum(not mastered(c) and (instant((c.get('fsrs') or {}).get('due') or c.get('due')) or float('inf')) <= now for c in cards.values())
    effective=training_observations(cards,now)
    raw = len(json.dumps(state,ensure_ascii=False,separators=(',',':')).encode())
    compact_bytes, blocked = None, None
    try:
        from app.auth import checkpoint_learning_state
        compact_bytes = len(json.dumps(checkpoint_learning_state(state),ensure_ascii=False,separators=(',',':')).encode())
    except (HTTPException, ValueError, TypeError, KeyError) as e:
        blocked = str(getattr(e,'detail','历史数据需先校验'))
    n = counters['observations']
    rate = round(counters['remembered']/n*100,1) if n else None
    lines = [f"最近 28 天延迟回忆：{n} 次有效观测，记住 {counters['remembered']}，忘记 {counters['forgotten']}，其中困难 {counters['hard']}。",
             f"实际记住率 {rate}%（目标 90%）。" if rate is not None else '尚无跨 24 小时的有效回忆观测。',
             '只统计已同步、未提示的延迟复习；学习展示和即时验收不计入。样本少于 30 次时不据此调整参数。',
             f'完整历史有效训练观测 {effective}/400；达到门槛后仍须通过时间留出验证，才可启用个性化参数。',
             f"当前到期 {due} 词；异常卡 {len(issues)} 词；待处理评分 {pending} 次。",
             f"进度占用 {raw/1048576:.2f} MB；" + (f"整理预计节省 {max(0,raw-compact_bytes)/1048576:.2f} MB。" if compact_bytes is not None else f"暂不能整理：{blocked}。")]
    if raw >= 4*1048576: lines.append('建议先让其他设备同步，再使用设置中的历史整理；整理前会保留两端备份。')
    return {**counters, 'recall_percent':rate,'due':due,'pending':pending,'issues':issues,'bytes':raw,
            'training_observations':effective,'compact_bytes':compact_bytes,'checkpoint_blocked':blocked,'lines':lines,
            'days':[{'day':d,'words':len(r['words']),'attempts':r['attempts']} for d,r in sorted(by_day.items())]}


def repair(card, review):
    """Only reconstruct derived scheduling, never change event IDs, time, or origin."""
    from app.auth import _card_history_events
    if not isinstance(card, dict) or len(json.dumps(card)) > 2*1024*1024:
        raise HTTPException(422, '卡片格式或大小无效')
    history = card.get('fsrsHistory')
    if not isinstance(history, dict) or not history.get('events'):
        raise HTTPException(409, '缺少完整评分起点；请导出原卡并从保留的备份恢复，不能安全重置')
    events, applied = _card_history_events(card, history)
    if len(events) > 2000: raise HTTPException(422, '历史较长，请先导出并联系维护者分批核对')
    if any(key in applied and not e.get('schedulerKey') for key,(_,e) in events.items()):
        raise HTTPException(409, '已应用评分缺少参数版本，不能猜测原算法')
    base = deepcopy(history.get('base') or {})
    ordered, versions, configs, result = [], {}, {}, None
    last_at = instant(base.get('last_review'))
    for key, (at, event) in sorted(events.items(), key=lambda x:(x[1][0],x[0])):
        if last_at is not None and at.timestamp() < last_at:
            raise HTTPException(409, '评分时间早于历史起点，原卡已保留')
        request = {**base,'now':event['at'],'rating':event['rating'],'deterministic':True,'scheduler_key':event.get('schedulerKey')}
        result = review(request)
        version = result['scheduler_key']; versions[key] = version
        configs[version] = result['scheduler_config']
        ordered.append({**event,'schedulerKey':version})
        base = {k:result[k] for k in ('state','stability','difficulty','due','step','last_review')}
        base['is_new'] = False; last_at = at.timestamp()
    out = deepcopy(card)
    out['fsrs'] = {k:result[k] for k in ('state','stability','difficulty','due','step')}
    out['fsrs']['lastReview'] = result['last_review']
    out['due'] = result['due']; out.pop('stage',None)
    out['schedulerKey'] = result['scheduler_key']
    out['fsrsHistory'] = {**history,'events':ordered}
    out['fsrsReplayVersions'] = {**(card.get('fsrsReplayVersions') or {}),**versions}
    out['appliedFsrs'] = sorted(applied | set(events))
    out.pop('pendingFsrs',None); out.pop('fsrsIssue',None)
    return {'card':out,'schedulers':configs,'events':len(events)}
