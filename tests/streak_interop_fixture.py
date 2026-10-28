#!/usr/bin/env python3
"""Create a disposable, anchored account for the cross-language streak test."""
import json, os, sys, urllib.request, uuid
from pathlib import Path
base='http://127.0.0.1:18765'
def call(path, body=None, token=None, method=None):
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    req=urllib.request.Request(base+path, None if body is None else json.dumps(body).encode(), headers, method=method)
    with urllib.request.urlopen(req, timeout=10) as response: return json.load(response)
a=call('/api/v1/auth/register',{'username':'cross_'+uuid.uuid4().hex[:9],'password':'test_password_123'})
state={'v':1,'cards':{},'log':[],'pendingNew':[],'settings':{'newPerDay':10,'dailyCap':100},'knowledge':{'apple':{'a':2,'b':1,'pos':7},'banana':{'a':0,'b':0,'pos':8}},'bandStats':{'0':{'a':0,'b':0}},'lastDay':'2026-10-25','streak':4}
call('/api/v1/me/state',state,a['token'],'PUT')
anchored=call('/api/v1/me/state',token=a['token'])['state']
path=Path(sys.argv[1]);path.write_text(json.dumps({'token':a['token'],'uid':a['user']['id'],'accountId':a['user']['account_id'],'state':anchored}))
os.chmod(path,0o600)
print('PASS isolated account and stable streak baseline prepared')
