"""Merge completed local calendar days without double counting offline branches."""
import re, uuid
from datetime import date, timedelta
from fastapi import HTTPException

def day(value):
    if not isinstance(value, str): raise HTTPException(422, '学习日期无效')
    try:
        parsed = date.fromisoformat(value)
        if parsed.isoformat() != value: raise ValueError()
        return parsed
    except ValueError: raise HTTPException(422, '学习日期无效')

def calculate(evidence):
    last, streak = evidence.get('baseDay'), evidence['baseStreak']
    if last:
        # A legacy streak proves the entire consecutive interval ending at baseDay.
        first = day(last).toordinal() - streak + 1
        ordinals = {day(item).toordinal() for item in evidence['days']}
        while first > 1 and first - 1 in ordinals:
            first -= 1
            streak += 1
    for current in sorted(evidence['days']):
        if last and current <= last: continue
        streak = streak + 1 if last and day(current) - day(last) == timedelta(days=1) else 1
        last = current
    return last, streak

def validate(state):
    evidence = state.get('streakEvidence')
    if evidence is None: return None
    if not isinstance(evidence, dict): raise HTTPException(422, '连续天数证据格式无效')
    base_id, base_day, base_streak, days = evidence.get('baseId'), evidence.get('baseDay'), evidence.get('baseStreak'), evidence.get('days')
    if not isinstance(base_id, str) or not re.fullmatch(r'(?:empty|[a-f0-9-]{8,64})', base_id) or not isinstance(base_streak, int) or isinstance(base_streak, bool) or not 0 <= base_streak <= 2**53-1 or not isinstance(days, list) or len(days) > 100000:
        raise HTTPException(422, '连续天数证据格式无效')
    if base_day is None:
        if base_streak != 0 or base_id != 'empty': raise HTTPException(422, '连续天数基线无效')
    else:
        base_date = day(base_day)
        if base_streak < 1 or base_streak > base_date.toordinal() or base_id == 'empty': raise HTTPException(422, '连续天数基线无效')
    if any(not isinstance(item, str) for item in days) or len(set(days)) != len(days): raise HTTPException(422, '学习日期无效')
    for item in days:
        day(item)
    last, streak = calculate(evidence)
    actual = state.get('streak', 0)
    if not isinstance(actual, int) or isinstance(actual, bool) or state.get('lastDay') != last or actual != streak: raise HTTPException(409, '连续天数与完成日期不一致，请先导出进度')
    return evidence

def anchor(state):
    if state.get('streakEvidence') is not None:
        validate(state)
        return state, False
    base_day, streak = state.get('lastDay'), state.get('streak', 0)
    if not base_day and streak == 0: return state, False
    result = {**state, 'streakEvidence': {'baseId':uuid.uuid4().hex, 'baseDay':base_day, 'baseStreak':streak, 'days':[]}}
    validate(result)
    return result, True

def merge(old, new):
    left, right = validate(old), validate(new)
    if left is None and right is None: return None
    if left is None or right is None:
        missing, present = (old, right) if left is None else (new, left)
        if missing.get('lastDay') == present.get('baseDay') and missing.get('streak', 0) == present['baseStreak']:
            return present
        raise HTTPException(409, '旧版连续天数无法安全合并，请先导出进度并重新加载')
    if (left['baseId'], left.get('baseDay'), left['baseStreak']) != (right['baseId'], right.get('baseDay'), right['baseStreak']):
        raise HTTPException(409, '连续天数基线不同，请先导出进度')
    result = {**left, 'days': sorted(set(left['days']) | set(right['days']))}
    return result
