#!/usr/bin/env python3
"""Independent placement evidence merges within the same reset epoch."""
import copy
from fastapi import HTTPException
from app.auth import anchor_legacy_evidence, merge_learning_states, validate_band_evidence

base={'v':1,'cards':{},'log':[],'pendingNew':[],'settings':{},'knowledge':{'apple':{'a':0,'b':0,'pos':7},'banana':{'a':0,'b':0,'pos':8}},'bandStats':{'0':{'a':0,'b':0}},'placementResetAt':100}
anchored,changed=anchor_legacy_evidence(base)
assert changed and anchored['bandEvidence']['0']['baseId']=='empty'
def branch(word, eid, ok, pos):
    state=copy.deepcopy(anchored)
    event={'device':'device-a','at':'2026-10-27T10:00:00Z','ok':ok,'pos':pos}
    state['knowledgeEvidence'][word]['events'][eid]=event
    state['knowledge'][word]['a' if ok else 'b']+=1
    state['bandEvidence']['0']['events'][eid]=event
    state['bandStats']['0']['a' if ok else 'b']+=1
    return state
a=branch('apple','aaaaaaaa-1111',True,7)
b=branch('banana','bbbbbbbb-2222',False,8)
x=merge_learning_states(a,b);y=merge_learning_states(b,a)
assert x['bandStats']==y['bandStats']=={'0':{'a':1,'b':1}}
assert x['bandEvidence']==y['bandEvidence'] and len(x['bandEvidence']['0']['events'])==2
assert merge_learning_states(x,a)['bandStats']==x['bandStats']
bad=copy.deepcopy(a);bad['bandEvidence']['0']['events']['aaaaaaaa-1111']['ok']=False
bad['bandStats']['0']={'a':0,'b':1}
try: validate_band_evidence(bad);raise AssertionError('band event diverged from word event')
except HTTPException as error: assert error.status_code==409
# Reset discards older band evidence without discarding historical word evidence.
new=copy.deepcopy(a);new['placementResetAt']=200;new['bandStats']=None;new.pop('bandEvidence')
merged=merge_learning_states(b,new)
assert merged['bandStats'] is None and not merged.get('bandEvidence')
assert len(merged['knowledgeEvidence']['banana']['events'])==1
late=merge_learning_states(merged,b)
assert late['bandStats'] is None and not late.get('bandEvidence')
print('PASS placement band events converge once and old epochs cannot revive reset bands')
