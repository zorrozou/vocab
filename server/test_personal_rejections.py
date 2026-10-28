#!/usr/bin/env python3
"""Rejected sentences cannot reappear after stale devices or pending jobs sync."""
import copy
from fastapi import HTTPException
from app.auth import merge_learning_states, filter_rejected_personalized

base = {'v':1,'cards':{},'log':[],'pendingNew':[],'settings':{},'personalized':{'apple':{'text':'old sentence'}}}
removed = copy.deepcopy(base); removed['personalized']={}; removed['rejectedPersonalized']={'apple':['old sentence']}
for result in (merge_learning_states(removed,base), merge_learning_states(base,removed), filter_rejected_personalized({**base, 'rejectedPersonalized': {'apple':['old sentence']}})):
    assert result['personalized'] == {}
    assert result['rejectedPersonalized'] == {'apple':['old sentence']}
    assert merge_learning_states(result,base)['personalized'] == {}
new = copy.deepcopy(removed);new['personalized']={'apple':{'text':'new sentence'}}
assert merge_learning_states(removed,new)['personalized']['apple']['text'] == 'new sentence'
independent=copy.deepcopy(removed); independent['rejectedPersonalized']={'apple':['another sentence']}
assert merge_learning_states(removed,independent)['rejectedPersonalized']['apple'] == ['another sentence','old sentence']
for rejected in ({'apple':'bad'}, {'apple':['']}, {'apple':[123]}, {'apple':['x'*2001]}, {'': ['bad']}):
    try: filter_rejected_personalized({**base,'rejectedPersonalized':rejected});raise AssertionError('malformed rejection accepted')
    except HTTPException as error: assert error.status_code == 422
older = copy.deepcopy(base); older['personalVersions'] = {'apple': {'counter':1,'device':'device-a','deleted':False}}
newer = copy.deepcopy(base); newer['personalized']['apple']['text']='newer sentence'; newer['personalVersions']={'apple':{'counter':2,'device':'device-a','deleted':False}}
assert merge_learning_states(older,newer)['personalized']['apple']['text'] == 'newer sentence'
assert merge_learning_states(newer,older)['personalized']['apple']['text'] == 'newer sentence'
deleted = copy.deepcopy(newer); deleted['personalized']={};deleted['personalVersions']['apple']={'counter':3,'device':'device-a','deleted':True}
assert not merge_learning_states(deleted,older)['personalized']
assert not merge_learning_states(older,deleted)['personalized']
assert not merge_learning_states(deleted,base)['personalized']
same = copy.deepcopy(newer); same['personalized']['apple']['recall']=None;same['personalized']['apple']['zh']=''
assert merge_learning_states(newer,same)['personalized']['apple']['text']=='newer sentence'
bad = copy.deepcopy(newer);bad['personalized']['apple']['text']='different with same version'
try: merge_learning_states(newer,bad);raise AssertionError('conflicting version accepted')
except HTTPException as error: assert error.status_code == 409
rejected = copy.deepcopy(newer);rejected['rejectedPersonalized']={'apple':['newer sentence']}
filtered = filter_rejected_personalized(rejected)
assert not filtered['personalized'] and filtered['personalVersions']['apple']['deleted'] is True
assert not merge_learning_states(filtered,newer)['personalized']
concurrent = copy.deepcopy(older);concurrent['personalized']['apple']['text']='concurrent sentence';concurrent['personalVersions']['apple']['device']='device-z'
assert merge_learning_states(older,concurrent)['personalized']['apple']['text']=='concurrent sentence'
assert merge_learning_states(concurrent,older)['personalized']['apple']['text']=='concurrent sentence'
for invalid in ({'counter':0,'device':'a','deleted':False}, {'counter':1,'device':'../bad','deleted':False}, {'counter':True,'device':'a','deleted':False}):
    broken=copy.deepcopy(base);broken['personalVersions']={'apple':invalid}
    try: merge_learning_states(base,broken);raise AssertionError('invalid personal version accepted')
    except HTTPException as error: assert error.status_code == 422
bad_job=copy.deepcopy(base);bad_job['personalJobs']=[{'weakWords':['banana'],'personalVersions':{'apple':{'counter':1,'device':'a','deleted':False}}}]
try: merge_learning_states(base,bad_job);raise AssertionError('unrelated job version accepted')
except HTTPException as error: assert error.status_code == 422
print('PASS rejected personalized sentences remain deleted after stale sync and retries')
