import json,urllib.request,urllib.error,uuid,os
base=os.environ.get('VOCAB_TEST_BASE','http://127.0.0.1:18765')
def call(path,body=None,token=None):
 headers={'Content-Type':'application/json'}
 if token:headers['X-Guest-Token']=token
 r=urllib.request.Request(base+path,data=None if body is None else json.dumps(body).encode(),headers=headers)
 try:
  with urllib.request.urlopen(r) as x:return x.status,json.load(x)
 except urllib.error.HTTPError as e:return e.code,json.load(e)
_,guest=call('/api/v1/auth/guest',{})
p={'word':'apple','kind':'static','text':'An apple is on the table.','reason':'translation','comment':'测试','request_id':uuid.uuid4().hex}
status,r=call('/api/v1/content/report',p,guest['token']);assert status==200,(status,r)
assert call('/api/v1/content/report',p,guest['token'])[1]['id']==r['id']
q={**p,'request_id':uuid.uuid4().hex};assert call('/api/v1/content/report',q,guest['token'])[1]['id']==r['id']
assert call('/api/v1/content/report',{**p,'reason':'grammar'},guest['token'])[0]==409
assert call('/api/v1/content/report',{**p,'word':'not-a-real-word'},guest['token'])[0]==422
assert call('/api/v1/content/report',{**p,'reason':'anything'},guest['token'])[0]==422
assert call('/api/v1/content/report',p)[0] in (401,409)
assert call('/api/v1/content/reports')[0]==404
print('PASS authenticated/guest content correction, idempotency, input validation, private review queue')
