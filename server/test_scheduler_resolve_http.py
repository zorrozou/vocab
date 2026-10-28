#!/usr/bin/env python3
"""Resolve only owned, verified scheduler versions and fence database rotation."""
import json, os, time, urllib.error, urllib.request, uuid
from concurrent.futures import ThreadPoolExecutor
from app.fsrs_config import fsrs_config_key

BASE=os.environ.get('VOCAB_TEST_BASE','http://127.0.0.1:18765').rstrip('/')
def call(path,method='GET',body=None,token=None):
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    req=urllib.request.Request(BASE+path,None if body is None else json.dumps(body).encode(),headers,method=method)
    with urllib.request.urlopen(req,timeout=30) as response:
        if path.endswith('/resolve'): assert response.headers.get('Cache-Control')=='no-store'
        return json.load(response)
def reject(code,path,method='GET',body=None,token=None):
    try: call(path,method,body,token)
    except urllib.error.HTTPError as error: assert error.code==code, (error.code,code)
    else: raise AssertionError('request unexpectedly succeeded')
def register():
    return call('/api/v1/auth/register','POST',{'username':'params_'+uuid.uuid4().hex[:8],'password':'test_password_123'})['token']
def resolve(token,generation,keys):
    return call('/api/v1/me/fsrs-schedulers/resolve','POST',{'generation':generation,'keys':keys},token)

owner,other=register(),register()
snapshot=call('/api/v1/me/state/snapshots?representation=stored','POST',{},owner)
generation=snapshot['generation']
review=call('/api/v1/fsrs/review','POST',{'is_new':True,'rating':3,'deterministic':True},owner)
key,config=review['scheduler_key'],review['scheduler_config']
unknown=('0' if key[0]!='0' else '1')+key[1:]
out=resolve(owner,generation,[key,unknown])
assert out['generation']==generation and out['missing']==[unknown] and fsrs_config_key(out['versions'][key])==key
assert resolve(other,generation,[key])['missing']==[key]
assert resolve(owner,generation,[])=={'generation':generation,'versions':{},'missing':[]}
reject(401,'/api/v1/me/fsrs-schedulers/resolve','POST',{'generation':generation,'keys':[key]})
for invalid in ([key,key],['z'*64],['a'*64]*257):
    reject(422,'/api/v1/me/fsrs-schedulers/resolve','POST',{'generation':generation,'keys':invalid},owner)
wrong=('0' if generation[0]!='0' else '1')+generation[1:]
reject(409,'/api/v1/me/fsrs-schedulers/resolve','POST',{'generation':wrong,'keys':[key]},owner)
# An explicitly imported backup belongs to the new account and remains usable.
imported={'v':1,'cards':{},'log':[],'pendingNew':[],'settings':{},'fsrsSchedulers':{key:config}}
call('/api/v1/me/state','PUT',imported,other)
assert fsrs_config_key(resolve(other,generation,[key])['versions'][key])==key
# Hold the separate parameter DB read, then rotate the users database generation.
call('/api/v1/__ui_fixture/scheduler-resolve-hold','POST',{})
with ThreadPoolExecutor(max_workers=1) as pool:
    future=pool.submit(resolve,owner,generation,[key])
    try:
        for _ in range(100):
            if call('/api/v1/__ui_fixture/scheduler-resolve-status')['started']: break
            time.sleep(.05)
        else: raise AssertionError('scheduler lookup did not reach its gate')
        new_generation=call('/api/v1/__ui_fixture/reset-sync-generation','POST',{})['generation']
    finally:
        call('/api/v1/__ui_fixture/scheduler-resolve-release','POST',{})
    try: future.result()
    except urllib.error.HTTPError as error: assert error.code==409
    else: raise AssertionError('lookup crossed a database generation change')
assert new_generation!=generation
assert fsrs_config_key(resolve(owner,new_generation,[key])['versions'][key])==key
assert call('/api/v1/__ui_fixture/scheduler-corrupt','POST',{'token':owner,'key':key})['changed']==1
reject(409,'/api/v1/me/fsrs-schedulers/resolve','POST',{'generation':new_generation,'keys':[key]},owner)
assert call('/api/v1/__ui_fixture/scheduler-delete','POST',{'token':owner,'key':key})['deleted']==1
assert resolve(owner,new_generation,[key])['missing']==[key]
assert fsrs_config_key(resolve(other,new_generation,[key])['versions'][key])==key
print('PASS account-scoped scheduler resolution, integrity, explicit missing keys and generation race')
