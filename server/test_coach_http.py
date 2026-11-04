"""Use only against the local isolated fixture; two authenticated logins resume one lesson."""
import json
from urllib.error import HTTPError
from urllib.request import Request,urlopen
from uuid import uuid4

BASE='http://127.0.0.1:18765/api/v1/'
def call(path, body=None, token=None):
    headers={'Content-Type':'application/json'}
    if token:headers['Authorization']='Bearer '+token
    req=Request(BASE+path,data=json.dumps(body).encode() if body is not None else None,headers=headers)
    with urlopen(req,timeout=8) as r:
        if path.startswith('coach/'):assert r.headers['Cache-Control']=='no-store'
        return json.load(r)
name='coach_'+uuid4().hex[:12]
creds={'username':name,'password':uuid4().hex}
a=call('auth/register',creds)['token'];b=call('auth/login',creds)['token']
d1,d2=str(uuid4()),str(uuid4())
def enter(action,client,token,**kw):return call('coach/'+action,dict(client=client,offset=480,**kw),token)
def clock(client,token,op):return call('coach/clock',{'client':client,'action':op,'offset':480},token)
assert clock(d1,a,'pulse')['credit']>0
l=enter('lesson',d1,a,track='work');t=l['task']
assert clock(d2,b,'pulse')['busy']
aid=dict(task=t['id'],kind='transcript',event=str(uuid4()))
assert enter('aid',d1,a,**aid)['task']['shown']
clock(d1,a,'stop');assert clock(d2,b,'pulse')['credit']>0
again=enter('lesson',d2,b,track='life')
assert again['task']['id']==t['id'] and again['task']['shown'] and again['track']=='work'
reply=dict(task=t['id'],choice=t['options'].index('保留周五的会议'),mode='listen')
result=enter('answer',d2,b,**reply)
assert result['last']['mode']=='assisted' and result['independent']==0
assert enter('answer',d2,b,**reply)==result
try:enter('lesson',d2,None)
except HTTPError as e:assert e.code==401
else:raise AssertionError('Missing identity accepted')
clock(d2,b,'stop')
print('PASS two authenticated sessions share one budget, saved transcript evidence, and one answer')
