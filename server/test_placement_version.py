#!/usr/bin/env python3
"""Versioned placement resets are ordered independently of device wall clocks."""
import copy
from fastapi import HTTPException
from app.auth import merge_learning_states, validate_placement_version
base={'v':1,'cards':{},'log':[],'pendingNew':[],'settings':{},'calibrated':True,'frontier':3000,'pointer':3001,'probeCount':100,'posterior':[1.,0.], 'placementResetAt':999999.0,'bandStats':{'0':{'a':40,'b':1}},'track':{'evalDay':'2099-01-01'}}
def reset(counter, device, ident, clock, frontier, calibrated=False):
 s=copy.deepcopy(base);s.update(placementVersion={'counter':counter,'device':device,'id':ident},placementResetAt=clock,frontier=frontier,pointer=frontier+1,probeCount=3,posterior=[0.,1.],bandStats={'0':{'a':1,'b':0}},track={'evalDay':'2000-01-01'},calibrated=calibrated,wrongStreak=0);return s
first=reset(1,'device-a','aaaaaaaa-1111',10,5000)
for merged in (merge_learning_states(base,first),merge_learning_states(first,base)):
 assert merged['placementVersion']==first['placementVersion'] and merged['frontier']==5000
 assert merged['posterior']==[0.,1.] and merged['bandStats']==first['bandStats'] and not merged['calibrated']
 assert merged['placementResetAt']==10
second=reset(2,'device-a','bbbbbbbb-2222',1,7000,True)
for merged in (merge_learning_states(first,second),merge_learning_states(second,first)):
 assert merged['placementVersion']==second['placementVersion'] and merged['frontier']==7000
 assert merged['calibrated'] and merged['placementResetAt']==1
# Concurrent resets, including two tabs on the same device, use immutable IDs.
x=reset(1,'device-a','aaaaaaaa-1111',999,4000)
y=reset(1,'device-a','bbbbbbbb-2222',1,6000)
for merged in (merge_learning_states(x,y),merge_learning_states(y,x)):
 assert merged['placementVersion']==y['placementVersion'] and merged['frontier']==6000
# Stale unversioned clients cannot undo a versioned reset, even with a future clock.
legacy=copy.deepcopy(base);legacy['placementResetAt']=9999999999;legacy['wrongStreak']=9
assert merge_learning_states(second,legacy)['placementVersion']==second['placementVersion']
assert merge_learning_states(second,legacy)['frontier']==7000
assert merge_learning_states(second,legacy)['wrongStreak']==0
for bad in ({'counter':True,'device':'x','id':'aaaaaaaa'}, {'counter':1,'device':'../x','id':'aaaaaaaa'}, {'counter':2**53,'device':'x','id':'aaaaaaaa'}, {'counter':1,'device':'x','id':'bad'}):
 try: validate_placement_version({'placementVersion':bad});raise AssertionError('bad version accepted')
 except HTTPException as e: assert e.status_code==422
print('PASS placement reset versions converge despite clock skew, concurrency and legacy writes')
