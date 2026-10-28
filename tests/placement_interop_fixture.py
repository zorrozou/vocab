#!/usr/bin/env python3
"""Create an isolated account and old placement state for Web/Swift reset tests."""
import json,os,sys,urllib.request,uuid
from pathlib import Path
base='http://127.0.0.1:18765'
def call(path,body=None,token=None,method=None):
    headers={'Content-Type':'application/json'}
    if token:headers['Authorization']='Bearer '+token
    req=urllib.request.Request(base+path,None if body is None else json.dumps(body).encode(),headers,method=method)
    with urllib.request.urlopen(req,timeout=10) as r:return json.load(r)
a=call('/api/v1/auth/register',{'username':'plc_'+uuid.uuid4().hex[:9],'password':'test_password_123'})
state={'v':1,'cards':{},'log':[],'pendingNew':[],'settings':{'newPerDay':10,'dailyCap':100},'calibrated':True,'frontier':3000,'pointer':3001,'probeCount':100,'posterior':[1,0],'placementResetAt':9999999999}
call('/api/v1/me/state',state,a['token'],'PUT')
current=call('/api/v1/me/state',token=a['token'])['state']
path=Path(sys.argv[1]);path.write_text(json.dumps({'token':a['token'],'uid':a['user']['id'],'accountId':a['user']['account_id'],'state':current}));os.chmod(path,0o600)
print('PASS isolated legacy placement state prepared')
