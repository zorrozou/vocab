"""Eligibility has the same meaning in the report and the actual optimizer."""
import sys
from pathlib import Path
from datetime import datetime,timedelta,timezone
from copy import deepcopy
sys.path.insert(0,str(Path(__file__).resolve().parent))
from app.training_data import training_data
from app.learning_health import health
now=datetime(2026,10,30,tzinfo=timezone.utc)
cards={}
for n in range(20):
    events=[{'id':f'{n}-{i}','at':(now-timedelta(days=60-i*2,minutes=n)).isoformat(),'rating':1 if (i+n)%5==0 else 3} for i in range(21)]
    cards[f'word{n}']={'fsrsHistory':{'base':{'is_new':True},'events':events},'appliedFsrs':[e['id'] for e in events]}
s={'cards':cards}
records,r=training_data(s,now);assert len(records)==420 and r['effective']==400 and r['eligible']
assert health(s,now.timestamp())['training']==r
assert health(s,now.timestamp(),words={'word0':1})['training']['effective']==20
bad=deepcopy(s);bad['cards']['word0']['fsrsIssue']='broken'
assert training_data(bad,now)[1]['effective']==380
bad=deepcopy(s);bad['cards']['word0']['fsrsHistory']['base']['is_new']=False
assert training_data(bad,now)[1]['excluded_cards']=={'missing_origin':1}
bad=deepcopy(s)
for card in bad['cards'].values():
 for event in card['fsrsHistory']['events']:event['rating']=3
r=training_data(bad,now)[1];assert r['effective']==400 and not r['eligible'] and 'validation_missing_outcome' in r['reasons']
bad=deepcopy(s);bad['cards']['copy']=deepcopy(bad['cards']['word0'])
r=training_data(bad,now)[1];assert r['effective']==380 and r['excluded_cards']=={'invalid_event':2}
bad=deepcopy(s);bad['cards']['word0']['fsrsHistory']['events'][0]['at']='2026-10-01'
assert training_data(bad,now)[1]['effective']==380
for malformed in [[],{'fsrsHistory':[]},{'fsrsHistory':{'base':[],'events':[]}}, {'fsrsHistory':{'base':{'is_new':True},'events':cards['word0']['fsrsHistory']['events']},'appliedFsrs':[{}]}]:
 bad=deepcopy(s);bad['cards']['word0']=malformed
 assert training_data(bad,now)[1]['effective']==380
print('PASS shared training eligibility, missing origin, pending/invalid cards, conflicting IDs, timezone precision and both-outcome gates')
