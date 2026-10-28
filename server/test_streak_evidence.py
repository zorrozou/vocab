"""Completed days merge from a shared baseline without duplicate day counts."""
import copy, sys
from fastapi import HTTPException
sys.path.insert(0, 'server')
from app.auth import merge_learning_states, anchor_legacy_evidence, checkpoint_learning_state
from app.streak_evidence import validate

def branch(dates, base=None):
    s=copy.deepcopy(base or {'streak':0,'lastDay':None})
    s['streakEvidence']={'baseId':'empty','baseDay':None,'baseStreak':0,'days':dates}
    from app.streak_evidence import calculate
    s['lastDay'],s['streak']=calculate(s['streakEvidence'])
    return s

a,b=branch(['2026-10-26']),branch(['2026-10-27'])
for x,y in ((a,b),(b,a)):
    merged=merge_learning_states(x,y)
    assert (merged['lastDay'],merged['streak'])==('2026-10-27',2)
    assert merge_learning_states(merged,x)['streak']==2
c=branch(['2026-10-29']); assert merge_learning_states(a,c)['streak']==1
legacy={'lastDay':'2026-10-25','streak':4}
anchored,added=anchor_legacy_evidence(legacy);assert added
x=copy.deepcopy(anchored);x['streakEvidence']['days']=['2026-10-26'];x['lastDay']='2026-10-26';x['streak']=5
y=copy.deepcopy(anchored);y['streakEvidence']['days']=['2026-10-27'];y['lastDay']='2026-10-27';y['streak']=1
assert merge_learning_states(x,y)['streak']==6
assert merge_learning_states(x,anchored)['streak']==5
z=copy.deepcopy(anchored);z['streakEvidence']['days']=['2026-10-21'];z['streak']=5
assert merge_learning_states(x,z)['streak']==6
assert merge_learning_states(merge_learning_states(x,y),z)['streak']==7
inside=copy.deepcopy(anchored);inside['streakEvidence']['days']=['2026-10-24'];assert validate(inside)
assert merge_learning_states(x,inside)['streak']==5
gap=copy.deepcopy(anchored);gap['streakEvidence']['days']=['2026-10-20'];assert validate(gap)
assert merge_learning_states(x,gap)['streak']==5
assert merge_learning_states(merge_learning_states(x,gap),z)['streak']==7

for bad in (dict(x,streak=99),dict(x,streakEvidence={**x['streakEvidence'],'days':['2026-02-30']})):
    try:validate(bad)
    except HTTPException:pass
    else:raise AssertionError('invalid evidence accepted')
other, _=anchor_legacy_evidence(legacy)
try:merge_learning_states(x,other)
except HTTPException as e:assert e.status_code==409
else:raise AssertionError('different baselines accepted')
compact=checkpoint_learning_state(x)
assert compact['lastDay']==x['lastDay'] and compact['streak']==x['streak'] and compact['streakEvidence']['days']==[]
# Compare reconstruction against the explicit set of known calendar days.
import random
from datetime import date, timedelta
from app.streak_evidence import calculate
rng=random.Random(2091)
for _ in range(1000):
    base=date(2026,10,25); count=rng.randint(1,15)
    offsets={rng.randint(-25,15) for _ in range(rng.randrange(25))}
    evidence={'baseDay':base.isoformat(),'baseStreak':count,'days':[(base+timedelta(days=n)).isoformat() for n in offsets]}
    known={base-timedelta(days=n) for n in range(count)}|{base+timedelta(days=n) for n in offsets}
    latest=max(known); cursor=latest; expected=0
    while cursor in known:
        expected+=1; cursor-=timedelta(days=1)
    assert calculate(evidence)==(latest.isoformat(),expected)
print('PASS independent completion days, legacy baselines, checkpoint and invalid evidence')
