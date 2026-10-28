#!/usr/bin/env python3
"""Independent evidence from the same baseline must union exactly once."""
import copy
from fastapi import HTTPException
from app.auth import anchor_legacy_knowledge, merge_learning_states, validate_knowledge_evidence

base = {'v':1,'cards':{},'log':[],'pendingNew':[],'settings':{}, 'knowledge':{'apple':{'a':2,'b':1,'pos':7}}}
def branch(event_id, ok, actor):
    value=copy.deepcopy(base)
    value['knowledge']['apple']['a' if ok else 'b']+=1
    value['knowledgeEvidence']={'apple':{'baseId':'aaaaaaaa-aaaa','base':copy.deepcopy(base['knowledge']['apple']),'events':{event_id:{'device':actor,'at':'2026-10-27T10:00:00Z','ok':ok,'pos':7}}}}
    return value
a=branch('aaaaaaaa-1111',True,'device-a');b=branch('bbbbbbbb-2222',False,'device-b')
x=merge_learning_states(a,b); y=merge_learning_states(b,a)
assert x['knowledge']==y['knowledge']=={'apple':{'a':3,'b':2,'pos':7}}
assert x['knowledgeEvidence']==y['knowledgeEvidence']
assert merge_learning_states(x,a)['knowledge']==x['knowledge']
assert merge_learning_states(x,x)['knowledge']==x['knowledge']
for pair in ((base,a),(a,base)):
    try: merge_learning_states(*pair);raise AssertionError('unanchored legacy baseline accepted')
    except HTTPException as error: assert error.status_code==409
anchored, changed = anchor_legacy_knowledge(base)
assert changed and anchored['knowledgeEvidence']['apple']['baseId'] != 'empty'
assert anchor_legacy_knowledge(anchored) == (anchored, False)
zero=copy.deepcopy(base);zero['knowledge']['apple']={'a':0,'b':0,'pos':7}
zero_event=copy.deepcopy(zero);zero_event['knowledge']['apple']['a']=1
zero_event['knowledgeEvidence']={'apple':{'baseId':'empty','base':copy.deepcopy(zero['knowledge']['apple']),'events':{'eeeeeeee-1111':{'device':'device-a','at':'2026-10-27T10:00:00Z','ok':True,'pos':7}}}}
assert merge_learning_states(zero,zero_event)['knowledge']['apple']['a']==1
same_counts_other_anchor=copy.deepcopy(b);same_counts_other_anchor['knowledgeEvidence']['apple']['baseId']='bbbbbbbb-bbbb'
try: merge_learning_states(a,same_counts_other_anchor);raise AssertionError('different baselines with equal totals merged')
except HTTPException as error: assert error.status_code==409
conflicting=copy.deepcopy(a);conflicting['knowledgeEvidence']['apple']['events']['aaaaaaaa-1111']['device']='other-device'
try: merge_learning_states(a,conflicting);raise AssertionError('conflicting event ID accepted')
except HTTPException as error: assert error.status_code==409
legacy=copy.deepcopy(base);legacy['knowledge']['apple']['a']+=2
try: merge_learning_states(a,legacy);raise AssertionError('unverifiable legacy branch accepted')
except HTTPException as error: assert error.status_code==409
incorrect=copy.deepcopy(a);incorrect['knowledge']['apple']['a']+=1
try: validate_knowledge_evidence(incorrect);raise AssertionError('unexplained evidence count accepted')
except HTTPException as error: assert error.status_code==409
wrong_base=copy.deepcopy(b);wrong_base['knowledgeEvidence']['apple']['base']['a']=3;wrong_base['knowledge']['apple']['a']=3
try: merge_learning_states(a,wrong_base);raise AssertionError('different baselines merged')
except HTTPException as error: assert error.status_code==409
print('PASS independent knowledge events merge once; unverifiable baselines and collisions fail safely')
