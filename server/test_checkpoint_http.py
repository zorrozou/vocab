"""Transactional history checkpoint, stale device fencing and continued learning."""
import copy, json, sys, urllib.request, urllib.error, uuid
sys.path.insert(0, 'server')
from app.posterior_evidence import replay
BASE='http://127.0.0.1:18765'
def call(path, body=None, token=None, method=None):
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    req=urllib.request.Request(BASE+path, None if body is None else json.dumps(body).encode(), headers, method=method)
    with urllib.request.urlopen(req, timeout=30) as response: return json.load(response)
def reject(fn, code=409):
    try: fn()
    except urllib.error.HTTPError as e: assert e.code == code, e.code
    else: raise AssertionError('unsafe checkpoint accepted')
a=call('/api/v1/auth/register',{'username':'cp_'+uuid.uuid4().hex[:12],'password':'test_password_123'})
t=a['token']; key='a'*64; ev='aaaaaaaa-1111'; histid='bbbbbbbb-2222'
knowledge={'device':'ios-one','at':'2026-10-27T12:00:00Z','ok':True,'pos':7}
posterior={'algorithm':'bayes-grid-1','baseId':'empty','base':None,'baseCount':0,'events':{histid:{'kind':'update','device':'ios-one','at':'2026-10-27T12:00:00Z','day':'2026-10-27','parents':[],'rank':1000,'resp':1,'weight':1,'guess':.25}}}
post, n = replay(posterior)
s={'v':1,'cards':{'apple':{'fsrs':{'state':2,'stability':2.0,'difficulty':5.0,'due':'2026-10-28'},'due':'2026-10-28',
    'fsrsHistory':{'base':{'is_new':True,'state':1,'stability':0,'difficulty':0,'rating':3},'events':[{'id':'event-a','rating':3,'at':'2026-10-27T12:00:00Z','schedulerKey':key}]},
    'appliedFsrs':['event-a'],'fsrsReplayVersions':{'event-a':key}}},'log':[],'pendingNew':[],'settings':{},'posterior':post,'probeCount':n,'posteriorHistory':posterior,
   'knowledge':{'apple':{'a':1,'b':0,'pos':7}},'knowledgeEvidence':{'apple':{'baseId':'empty','base':{'a':0,'b':0,'pos':7},'events':{ev:knowledge}}},
   'bandStats':{'0':{'a':1,'b':0}},'bandEvidence':{'0':{'baseId':'empty','base':{'a':0,'b':0},'events':{ev:knowledge}}}}
call('/api/v1/me/state',s,t,'PUT'); before=call('/api/v1/me/state',token=t); version=before['updated_at']
reject(lambda:call('/api/v1/me/state/checkpoint',{'expected_updated_at':version-1},t))
assert call('/api/v1/me/state',token=t)['updated_at']==version
result=call('/api/v1/me/state/checkpoint',{'expected_updated_at':version},t); compact=result['state']
assert compact['restoreEpoch']==1 and compact['posterior']==s['posterior'] and compact['knowledge']==s['knowledge'] and compact['bandStats']==s['bandStats']
assert compact['cards']['apple']['fsrs']==s['cards']['apple']['fsrs'] and 'fsrsHistory' not in compact['cards']['apple']
assert compact['knowledgeEvidence']['apple']['events']=={} and compact['bandEvidence']['0']['events']=={} and compact['posteriorHistory']['events']=={}
backups=call('/api/v1/me/state/backups',token=t)['backups']; assert backups[0]['reason']=='before_checkpoint'
old=call('/api/v1/me/state/backups/'+str(backups[0]['id']),token=t)['state']; assert old['knowledgeEvidence']==s['knowledgeEvidence']
reject(lambda:call('/api/v1/me/state',s,t,'PUT'))
# A branch based on the new baseline can continue without resurrecting compacted events.
new=copy.deepcopy(compact); eid='cccccccc-3333'; event={'device':'web-one','at':'2026-10-28T12:00:00Z','ok':False,'pos':7}
new['knowledge']['apple']['b']+=1; new['knowledgeEvidence']['apple']['events'][eid]=event
call('/api/v1/me/state',new,t,'PUT'); assert call('/api/v1/me/state',token=t)['state']['knowledge']['apple']['b']==1
# Pending work cannot be checkpointed and the current state is preserved.
pending=copy.deepcopy(new); pending['cards']['banana']={'pendingFsrs':{'base':{'is_new':True,'state':1,'stability':0,'difficulty':0,'rating':3},'events':[{'id':'event-b','rating':3,'at':'2026-10-28T12:00:00Z'}]}}
call('/api/v1/me/state',pending,t,'PUT'); current=call('/api/v1/me/state',token=t)
reject(lambda:call('/api/v1/me/state/checkpoint',{'expected_updated_at':current['updated_at']},t))
assert call('/api/v1/me/state',token=t)['state']['cards']['banana'].get('pendingFsrs')
print('PASS checkpoint preserves snapshot and backup, fences stale versions, allows new evidence and rejects pending reviews')
