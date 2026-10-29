"""Generate offline phase/short-step oracles using the pinned official FSRS."""
import itertools,json
from copy import deepcopy
from datetime import datetime,timedelta,timezone
from fsrs import Scheduler,Card,State,Rating
from importlib.metadata import version
key='a'*64
start=datetime(2026,10,29,2,tzinfo=timezone.utc)
cases=[]
profiles=[([60,600],[600]),([30,300,900],[120,600]),([],[]),([0],[0]),([60],[300])]
for learning,relearning in profiles:
 config={'library':version('fsrs'),'parameters':list(Scheduler().parameters),'desired_retention':.9,'learning_steps':learning,'relearning_steps':relearning,'maximum_interval':36500}
 scheduler=Scheduler(learning_steps=[timedelta(seconds=x) for x in learning],relearning_steps=[timedelta(seconds=x) for x in relearning],enable_fuzzing=False)
 for state,step,is_new in [(1,0,True),(1,1,False),(2,None,False),(3,0,False),(3,3,False)]:
  base={'is_new':is_new,'state':state,'step':step,'stability':8.0,'difficulty':5.0,'rating':3,'due':start.isoformat(),'last_review':(start-timedelta(days=2)).isoformat()}
  for length in [1,2,3]:
   for ratings in itertools.product(range(1,5),repeat=length):
    card=Card(state=State(state),step=step,stability=None if is_new else 8,difficulty=None if is_new else 5,due=start,last_review=None if is_new else start-timedelta(days=2))
    events=[]
    for i,rating in enumerate(ratings):
     at=start+timedelta(minutes=20*i)
     card,_=scheduler.review_card(card,Rating(rating),review_datetime=at)
     events.append({'id':str(i),'rating':rating,'at':at.isoformat(),'schedulerKey':key})
    expected_due=at+timedelta(days=1) if card.state==State.Review else card.due
    cases.append({'card':{'stage':1,'due':'2030-01-01','pendingFsrs':{'base':base,'events':events}},'configurations':{key:config},'state':card.state.value,'step':card.step,'due':expected_due.isoformat()})
# No cached config: defaults must still keep a first Good at ten minutes.
case=deepcopy(cases[2]);case['configurations']={};cases.append(case)
print(json.dumps(cases))
