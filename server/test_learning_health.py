import sys
from datetime import datetime,timezone,timedelta
sys.path.insert(0,str(__import__('pathlib').Path(__file__).resolve().parent))
from app.learning_health import health,repair,training_observations
from fastapi import HTTPException
now=datetime(2026,10,30,tzinfo=timezone.utc)
def iso(days):return (now-timedelta(days=days)).isoformat()
events={
 'learn':{'at':iso(20),'day':'2026-10-10','rating':3,'kind':'learn','verified':True},
 'immediate':{'at':iso(20),'priorAt':iso(20),'day':'2026-10-10','rating':3,'kind':'acceptance','verified':True},
 'later':{'at':iso(16),'priorAt':iso(20),'day':'2026-10-14','rating':3,'kind':'review','verified':True},
 'forgot':{'at':iso(10),'priorAt':iso(16),'day':'2026-10-20','rating':1,'kind':'review','verified':True},
 'hint':{'at':iso(5),'priorAt':iso(10),'day':'2026-10-25','rating':3,'kind':'review','verified':True,'hinted':True},
 'pending':{'at':iso(1),'priorAt':iso(5),'day':'2026-10-29','rating':3,'kind':'review','verified':True},
}
card={'fsrs':{'state':2,'stability':10,'difficulty':5,'due':iso(0)},'studyEvidence':{'version':1,'legacy':False,'originAt':iso(30),'originIds':[],'events':events},'pendingFsrs':{'base':{'is_new':True},'events':[{'id':'pending','at':iso(1),'rating':3}]}}
h=health({'cards':{'apple':card}},now.timestamp())
assert h['observations']==2 and h['remembered']==1 and h['forgotten']==1 and h['recall_percent']==50
assert h['pending']==1 and h['checkpoint_blocked']
assert next(d for d in h['days'] if d['day']=='2026-10-10')['words']==1
assert next(d for d in h['days'] if d['day']=='2026-10-10')['attempts']==2
try:repair({'fsrsIssue':'broken'},lambda _:None);raise AssertionError('missing origin accepted')
except HTTPException as e:assert e.status_code==409
print('PASS actual delayed recall excludes learning, immediate, hinted and pending evidence; distinct/attempt counts, safe repair guard')

clicks=[{'id':str(i),'at':iso(1),'rating':3} for i in range(400)]
assert training_observations({'apple':{'fsrsHistory':{'base':{'is_new':True},'events':clicks},'appliedFsrs':[str(i) for i in range(400)]}},now.timestamp())==0
print('PASS 400 same-day clicks do not count as effective optimizer observations')
