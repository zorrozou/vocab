"""Checkpoints preserve aggregates and refuse histories that cannot be proven settled."""
import copy, sys
from fastapi import HTTPException
sys.path.insert(0, 'server')
from app.auth import checkpoint_learning_state, serialize_state
key='a'*64
s={'cards':{'apple':{'fsrs':{'state':2,'stability':1,'difficulty':5},
    'fsrsHistory':{'base':{'is_new':True,'state':1,'stability':0,'difficulty':0,'rating':3},
                   'events':[{'id':'event-123','rating':3,'at':'2026-10-27T12:00:00Z','schedulerKey':key}]},
    'appliedFsrs':['event-123'],'fsrsReplayVersions':{'event-123':key}}},
   'knowledge':{'apple':{'a':300,'b':0,'pos':7}},'knowledgeEvidence':{'apple':{'baseId':'empty','base':{'a':0,'b':0,'pos':7},'events':{f'{i:08x}-1111':{'device':'device','at':'2026-10-27T12:00:00Z','ok':True,'pos':7} for i in range(300)}}},
   'bandStats':{},'log':[],'pendingNew':[],'settings':{}}
before=serialize_state(s); compact=checkpoint_learning_state(s)
assert compact['knowledge']==s['knowledge'] and compact['cards']['apple']['fsrs']==s['cards']['apple']['fsrs']
assert compact['knowledgeEvidence']['apple']['events']=={} and len(serialize_state(compact)) < len(before)/4
assert len(s['knowledgeEvidence']['apple']['events'])==300
for change in ('pending','missing_proof','extra_applied','missing_card','missing_history'):
    bad=copy.deepcopy(s); card=bad['cards']['apple']
    if change=='pending': card['pendingFsrs']=copy.deepcopy(card['fsrsHistory'])
    elif change=='missing_proof': card.pop('fsrsReplayVersions')
    elif change=='extra_applied': card['appliedFsrs'].append('event-other')
    elif change=='missing_card': card.pop('fsrs')
    else: card.pop('fsrsHistory')
    try: checkpoint_learning_state(bad)
    except HTTPException as e: assert e.status_code==409
    else: raise AssertionError('unproven history checkpointed: '+change)
print('PASS checkpoint reduces settled evidence and rejects incomplete histories without modifying source')
