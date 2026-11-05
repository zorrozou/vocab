import copy
from fastapi import HTTPException
from app.auth import merge_learning_states,checkpoint_learning_state,prepare_uploaded_state
from app import recognition_evidence
base={'v':1,'cards':{},'log':[],'pendingNew':[],'settings':{},'calibrated':True,'frontier':3000,'pointer':3001,'probeCount':0}
def event(pos,ok=True):return {'version':1,'word':f'w{pos}','pos':pos,'at':'2026-11-05T00:00:00Z','correct':ok,'source':'probe','itemId':'a'*64}
a={**base,'recognitionEvidence':{'aaaaaaaa':event(12)}};b={**base,'recognitionEvidence':{'bbbbbbbb':event(22,False)}}
for old,new in ((a,b),(b,a)):
 result=merge_learning_states(old,new);assert len(result['recognitionEvidence'])==2
 assert checkpoint_learning_state(result)['recognitionEvidence']==result['recognitionEvidence']
 assert merge_learning_states(result,base)['recognitionEvidence']==result['recognitionEvidence']
 assert prepare_uploaded_state(result)['recognitionEvidence']==result['recognitionEvidence']
reset={**base,'placementVersion':{'counter':1,'device':'device-a','id':'cccccccc'},'calibrated':False}
assert not merge_learning_states(a,reset).get('recognitionEvidence')
assert not merge_learning_states(reset,a).get('recognitionEvidence')
conflict=copy.deepcopy(a);conflict['recognitionEvidence']['aaaaaaaa']['correct']=False
try:merge_learning_states(a,conflict);raise AssertionError('conflict accepted')
except HTTPException as e:assert e.status_code==409
for field,value in [('version',True),('version',2),('correct',1),('pos',10988),('at','2026-11-05'),('itemId','bad'),('source','review')]:
 bad=copy.deepcopy(a);bad['recognitionEvidence']['aaaaaaaa'][field]=value
 try:recognition_evidence.validate(bad);raise AssertionError((field,value))
 except HTTPException as e:assert e.status_code==422
print('PASS recognition merge, old clients, checkpoint, reset ordering, conflict and validation')
# Compaction must not destroy the provable initial stratified legacy sample.
legacy=copy.deepcopy(base);legacy.update(knowledge={},knowledgeEvidence={},bandEvidence={},bandStats={})
for i in range(30):
 b=i//2 if i<12 else 5;pos=b*2000+1+i;word=f'old-{pos}';ident=f'{i:08x}'
 e={'pos':pos,'at':f'2026-11-05T00:00:{i:02d}Z','ok':True,'device':'qa'}
 legacy['knowledge'][word]={'a':1,'b':0,'pos':pos};legacy['knowledgeEvidence'][word]={'baseId':'empty','base':{'a':0,'b':0},'events':{ident:e}}
 band=legacy['bandEvidence'].setdefault(str(b),{'baseId':'empty','base':{'a':0,'b':0},'events':{}});band['events'][ident]=e
 legacy['bandStats'].setdefault(str(b),{'a':0,'b':0})['a']+=1
compacted=checkpoint_learning_state(legacy)
assert len(compacted['recognitionEvidence'])==12
assert all(e['source']=='legacy' for e in compacted['recognitionEvidence'].values())
assert checkpoint_learning_state(compacted)['recognitionEvidence']==compacted['recognitionEvidence']
print('PASS legacy stratified evidence survives checkpoint; adaptive tail stays excluded')
from app.daily_study import PlanRequest,extend_plan
request=lambda sampler:PlanRequest(day='2026-11-05',offset_minutes=0,candidates=[{'word':'sample','kind':'probe',**({'probe_sampler':sampler} if sampler else {})}])
plain=extend_plan(None,base,request(None));assert 'probe_sampler' not in plain['items'][0]
assert 'probe_sampler' not in extend_plan(plain,base,request('band-uniform-v1'))['items'][0], 'old reservations must not be relabeled'
new=extend_plan(None,base,request('band-uniform-v1'));assert new['items'][0]['probe_sampler']=='band-uniform-v1'
assert extend_plan(new,base,request(None))['items'][0]['probe_sampler']=='band-uniform-v1', 'old clients must not erase provenance'
print('PASS shared probe provenance survives old clients and cannot relabel old tasks')
