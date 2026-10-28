#!/usr/bin/env python3
"""Actual HTTP state mutations keep the segmented index and full mirror atomic."""
import copy, json, os, urllib.error, urllib.request
BASE=os.environ.get('VOCAB_TEST_BASE','http://127.0.0.1:18765').rstrip('/')
def call(path,method='GET',body=None,token=None):
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    req=urllib.request.Request(BASE+path,None if body is None else json.dumps(body).encode(),headers,method=method)
    with urllib.request.urlopen(req,timeout=45) as r:return json.load(r)
def reject(status,path,method='GET',body=None,token=None):
    try: call(path,method,body,token)
    except urllib.error.HTTPError as e: assert e.code==status,(e.code,status,e.read())
    else: raise AssertionError(f'{path} unexpectedly succeeded')
def action(token,mode,**extra):return call('/api/v1/__ui_fixture/state-segment-action','POST',{'token':token,'mode':mode,**extra})
seed=call('/api/v1/__ui_fixture/recovery-case','POST',{});token=seed['token']
other=call('/api/v1/__ui_fixture/recovery-case','POST',{})['token']
state=call('/api/v1/me/state',token=token)['state'];state['fixtureText']='x'*(1100*1024)
state['cards'].update({f'word_{i}':{'pos':i+2} for i in range(50)})
call('/api/v1/me/state','PUT',state,token)
info=action(token,'info');assert info['version']==1 and info['items']>=51
before=call('/api/v1/me/state',token=token);assert before['state']['fixtureText']==state['fixtureText']
manifest=call('/api/v1/me/state/snapshots?representation=stored','POST',{},token);assert manifest['state_revision']==before['state_revision']
# Inject failure after the compatibility row update and ensure the complete
# transaction, including the previous segment set, survives unchanged.
action(token,'trigger',enabled=True)
changed=copy.deepcopy(before['state']);changed['cards']['newword']={'pos':100}
reject(500,'/api/v1/me/state','PUT',changed,token)
action(token,'trigger',enabled=False)
assert action(token,'info')==info
assert call('/api/v1/me/state',token=token)==before
action(token,'guard-unchanged',enabled=True)
call('/api/v1/me/state','PUT',changed,token)
action(token,'guard-unchanged',enabled=False)
after=call('/api/v1/me/state',token=token);assert after['state']['cards']['newword']
assert action(token,'info')['revision']==after['state_revision']
generation=after['sync_generation']
def changes(revision):return '/api/v1/me/state/changes?generation='+generation+'&after='+revision
assert call(changes(after['state_revision']),token=token)['change'] is None
assert call(changes(before['state_revision']),token=token)['change'] is not None
action(token,'corrupt-item')
reject(409,changes(after['state_revision']),token=token)
reject(409,changes(before['state_revision']),token=token)
action(token,'repair');assert call('/api/v1/me/state',token=token)==after
# Missing marker metadata blocks reads, writes and destructive recovery rather
# than silently falling back to the large compatibility mirror.
action(token,'corrupt')
reject(409,'/api/v1/me/state',token=token)
reject(409,'/api/v1/me/state','PUT',changed,token)
reject(409,'/api/v1/me/state/snapshots?representation=stored','POST',{},token)
reject(409,changes(after['state_revision']),token=token)
reject(409,changes(before['state_revision']),token=token)
reject(409,'/api/v1/me/state/restore','POST',{'state':{'v':1,'cards':{},'log':[],'pendingNew':[],'settings':{}},'expected_updated_at':after['updated_at']},token)
assert call('/api/v1/me/state',token=other)['state']['cards']['apple']
action(token,'repair');assert call('/api/v1/me/state',token=token)==after
# A legacy writer that advances only the full mirror cannot be mistaken for a
# verified segmented revision by the new reader.
action(token,'stale');reject(409,'/api/v1/me/state',token=token);reject(409,'/api/v1/me/state','PUT',changed,token)
reject(409,changes(after['state_revision']),token=token)
print('PASS segmented state HTTP atomicity, corruption and legacy-write fencing')
