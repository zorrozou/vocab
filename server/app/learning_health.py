"""Read-only learning diagnostics and deterministic repair from retained history."""
from copy import deepcopy
from datetime import datetime, timezone
import json
from fastapi import HTTPException
from app.study_policy import instant, is_mastered


def training_observations(cards, now):
    from app.training_data import training_data
    return training_data({'cards':cards}, now)[1]['effective']


def recall_summary(remembered, count):
    """Wilson interval keeps a tiny sample from looking like a settled result."""
    if not count: return {'observations':0,'recall_percent':None,'interval_percent':None}
    p, z = remembered/count, 1.96
    center = (p+z*z/(2*count))/(1+z*z/count)
    half = z*((p*(1-p)/count+z*z/(4*count*count))**.5)/(1+z*z/count)
    return {'observations':count,'recall_percent':round(p*100,1),
            'interval_percent':[round(max(0,center-half)*100,1),round(min(1,center+half)*100,1)]}


def health(state, now=None, words=None):
    now = now or datetime.now(timezone.utc).timestamp()
    cards = state.get('cards') or {}
    counters = {'observations': 0, 'remembered': 0, 'forgotten': 0, 'hard': 0}
    by_day, seen, difficult = {}, set(), {}
    periods = [{'remembered':0,'count':0} for _ in range(2)]
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
            if key in pending_ids or gap < 86400 or event.get('kind') not in ('review','drill') or event.get('verified') is not True or event.get('hinted') or type(event.get('rating')) is not int or event['rating'] not in (1,2,3,4): continue
            counters['observations'] += 1
            rating = event.get('rating')
            recalled = rating != 1 and not event.get('guessed')
            if at >= now-14*86400:
                period = periods[0 if at >= now-7*86400 else 1]
                period['count'] += 1; period['remembered'] += int(recalled)
                if not recalled or rating == 2:
                    row = difficult.setdefault(word, {'word':word,'forgotten':0,'hard':0})
                    row['forgotten' if not recalled else 'hard'] += 1
            if rating == 1 or event.get('guessed'): counters['forgotten'] += 1
            else:
                counters['remembered'] += 1
                if rating == 2: counters['hard'] += 1
    def mastered(c):
        try: return is_mastered(c)
        except (TypeError,ValueError,KeyError): return False
    due = sum(not mastered(c) and (instant((c.get('fsrs') or {}).get('due') or c.get('due')) or float('inf')) <= now for c in cards.values())
    from app.training_data import training_data
    _, training = training_data(state,now,words)
    effective = training['effective']
    raw = len(json.dumps(state,ensure_ascii=False,separators=(',',':')).encode())
    compact_bytes, blocked = None, None
    try:
        from app.auth import checkpoint_learning_state
        compact_bytes = len(json.dumps(checkpoint_learning_state(state),ensure_ascii=False,separators=(',',':')).encode())
    except (HTTPException, ValueError, TypeError, KeyError) as e:
        blocked = str(getattr(e,'detail','历史数据需先校验'))
    n = counters['observations']
    estimate = recall_summary(counters['remembered'],n)
    weeks = [recall_summary(p['remembered'],p['count']) for p in periods]
    difficult = sorted((r for r in difficult.values() if r['forgotten']+r['hard'] >= 2 and not mastered(cards[r['word']])), key=lambda r:(-r['forgotten'],-r['hard'],r['word']))[:10]
    rate = round(counters['remembered']/n*100,1) if n else None
    lines = [f"最近 28 天延迟回忆：{n} 次有效观测，记住 {counters['remembered']}，忘记 {counters['forgotten']}，其中困难 {counters['hard']}。",
             f"实际记住率 {rate}%（目标 90%）。" if rate is not None else '尚无跨 24 小时的有效回忆观测。',
             '只统计已同步、未提示的延迟复习；学习展示和即时验收不计入。样本少于 30 次时不据此调整参数。',
             f'完整历史有效训练观测 {effective}/400；达到门槛后仍须通过时间留出验证，才可启用个性化参数。',
             f"当前到期 {due} 词；异常卡 {len(issues)} 词；待处理评分 {pending} 次。",
             f"进度占用 {raw/1048576:.2f} MB；" + (f"整理预计节省 {max(0,raw-compact_bytes)/1048576:.2f} MB。" if compact_bytes is not None else f"暂不能整理：{blocked}。")]
    if n: lines.append(f"记住率的 95% 统计区间：{estimate['interval_percent'][0]}%～{estimate['interval_percent'][1]}%；仅反映当前可追溯样本。")
    for title, week in zip(('最近 7 天','此前 7 天'),weeks):
        lines.append(f"{title}：{week['observations']} 次有效观测" + (f"，记住率 {week['recall_percent']}%。" if week['observations'] else '，暂不能比较。'))
    if all(w['observations'] >= 30 for w in weeks):
        lines.append(f"两周记住率相差 {weeks[0]['recall_percent']-weeks[1]['recall_percent']:+.1f} 个百分点；题目和间隔不同，不能直接归因为算法改善或变差。")
    if training['eligible']: lines.append('数据已满足训练门槛，候选仍需同时通过 Log Loss 与 Brier 留出验证；此报告不会修改参数。')
    elif effective >= 400: lines.append(f"暂不能训练：训练观测 {training['train']}，验证观测 {training['validation']}；两组都需同时有记住与忘记。")
    if training['excluded_cards']: lines.append('缺少完整起点、存在待处理评分或异常历史的卡片不计入参数训练。')
    if difficult: lines.append('最近 14 天反复困难（仅延迟实测）：'+'；'.join(f"{r['word']}：忘记 {r['forgotten']} / 困难 {r['hard']}" for r in difficult))
    if raw >= 4*1048576: lines.append('建议先让其他设备同步，再使用设置中的历史整理；整理前会保留两端备份。')
    return {**counters, 'recall_percent':rate,'due':due,'pending':pending,'issues':issues,'bytes':raw,
            'training_observations':effective,'training':training,'recall_interval_percent':estimate['interval_percent'],'weeks':weeks,'difficult_words':difficult,'compact_bytes':compact_bytes,'checkpoint_blocked':blocked,'lines':lines,
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
