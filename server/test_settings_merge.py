#!/usr/bin/env python3
"""Concurrent per-setting changes converge without wall-clock ordering."""
import copy
from fastapi import HTTPException
from app.auth import merge_learning_states, validate_settings_versions

base = {'v':1,'cards':{},'log':[],'pendingNew':[], 'settings':{'newPerDay':10,'dailyCap':100,'voice':'Aria'}}
def version(counter, device): return {'counter':counter,'device':device}
a = copy.deepcopy(base); a['settings']['newPerDay']=20; a['settingsVersions']={'newPerDay':version(1,'device-a')}
b = copy.deepcopy(base); b['settings']['dailyCap']=30; b['settingsVersions']={'dailyCap':version(1,'device-b')}
x, y = merge_learning_states(a,b), merge_learning_states(b,a)
assert x['settings'] == y['settings'] == {'newPerDay':20,'dailyCap':30,'voice':'Aria'}
assert x['settingsVersions'] == y['settingsVersions']
assert merge_learning_states(x,base)['settings'] == x['settings']  # old client cannot undo versioned changes
assert merge_learning_states(base,x)['settings'] == x['settings']
# Concurrent edits to the same field tie-break by stable device ID, independent of arrival order.
c = copy.deepcopy(base); c['settings']['newPerDay']=5; c['settingsVersions']={'newPerDay':version(1,'device-z')}
assert merge_learning_states(a,c)['settings']['newPerDay'] == 5
assert merge_learning_states(c,a)['settings']['newPerDay'] == 5
d = copy.deepcopy(c); d['settings']['newPerDay']=15; d['settingsVersions']['newPerDay']['counter']=2
assert merge_learning_states(c,d)['settings']['newPerDay'] == 15
assert merge_learning_states(d,c)['settings']['newPerDay'] == 15
conflict = copy.deepcopy(a); conflict['settings']['newPerDay']=5
try:
    merge_learning_states(a,conflict); raise AssertionError('equal version with different values accepted')
except HTTPException as error: assert error.status_code == 409
typed = copy.deepcopy(a); typed['settings']['newPerDay'] = 1
typed['settingsVersions']['newPerDay'] = version(1, 'device-a')
boolean = copy.deepcopy(typed); boolean['settings']['newPerDay'] = True
try:
    merge_learning_states(typed, boolean); raise AssertionError('boolean and number were treated as the same value')
except HTTPException as error: assert error.status_code == 409
for invalid in ({'counter':True,'device':'a'}, {'counter':2**53,'device':'a'}, {'counter':1,'device':'../bad'}, {'counter':1,'device':'a','extra':1}):
    item=copy.deepcopy(base); item['settingsVersions']={'voice':invalid}
    try:
        validate_settings_versions(item); raise AssertionError('invalid version accepted')
    except HTTPException as error: assert error.status_code == 422
print('PASS per-field versioned settings: stale devices, independent edits, deterministic conflicts and validation')
