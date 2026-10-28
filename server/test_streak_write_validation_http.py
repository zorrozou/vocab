#!/usr/bin/env python3
"""An accepted state must not poison later legacy streak anchoring."""
import json, os, urllib.request, urllib.error, uuid
BASE=os.environ.get('VOCAB_TEST_BASE','http://127.0.0.1:18765').rstrip('/')
def call(path, method='GET', body=None, token=None):
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    request=urllib.request.Request(BASE+path, None if body is None else json.dumps(body,separators=(',',':')).encode(), headers, method=method)
    with urllib.request.urlopen(request,timeout=30) as response:return json.load(response)
def reject(path,method,body,token):
    try:call(path,method,body,token)
    except urllib.error.HTTPError as error:assert error.code==422,(error.code,error.read())
    else:raise AssertionError('unanchorable legacy streak accepted')
user=call('/api/v1/auth/register','POST',{'username':'streak_'+uuid.uuid4().hex[:8],'password':'test_password_123'});token=user['token']
state={'v':1,'cards':{},'log':[],'pendingNew':[],'settings':{},'streak':0,'lastDay':None}
call('/api/v1/me/state','PUT',state,token);head=call('/api/v1/me/state',token=token)
bad={**state,'streak':51};reject('/api/v1/me/state','PUT',bad,token)
batch={'generation':head['sync_generation'],'base_revision':head['state_revision'],'restore_epoch':0,'batch_id':uuid.uuid4().hex,'ops':[{'op':'set','path':['streak'],'value':51}]}
reject('/api/v1/me/state/deltas','POST',batch,token)
after=call('/api/v1/me/state',token=token);assert after['state_revision']==head['state_revision'] and after['state']['streak']==0
snapshot=call('/api/v1/me/state/snapshots?representation=stored','POST',{},token);assert snapshot['state_revision']==head['state_revision']
# Valid legacy streaks still anchor and read normally.
valid={**state,'streak':2,'lastDay':'2026-10-26'};call('/api/v1/me/state','PUT',valid,token)
latest=call('/api/v1/me/state',token=token);assert latest['state']['streak']==2 and latest['state']['streakEvidence']['baseStreak']==2
print('PASS invalid legacy streak writes reject atomically; valid legacy state remains readable')
