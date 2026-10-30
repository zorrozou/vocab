import json,os,urllib.request,urllib.error
base=os.environ.get('VOCAB_TEST_BASE','http://127.0.0.1:18765/').rstrip('/')+'/'
def call(body):
    req=urllib.request.Request(base+'api/v1/fsrs/review',data=json.dumps(body).encode(),headers={'Content-Type':'application/json','Connection':'close'})
    try:
        with urllib.request.urlopen(req) as r:return r.status,json.load(r)
    except urllib.error.HTTPError as e:return e.code,json.load(e)
good={'state':2,'stability':30,'difficulty':5,'rating':3,'last_review':'2026-03-01T00:00:00Z','now':'2026-03-08T00:00:00Z','deterministic':True}
assert call(good)[0]==200
for field,value in [('state',9),('state',True),('rating',0),('rating',5),('is_new','false'),('stability',True),('difficulty','5'),('stability',float('inf')),('stability',-1),('stability',0),('difficulty',100),('difficulty',0),('step',-1),('due','bad'),('last_review','2026-03-09T00:00:00Z')]:
    status,body=call({**good,field:value});assert status==422,(field,status,body)
    assert body['detail']['code']=='invalid-fsrs-input'
assert call({'is_new':True,'rating':3})[0]==200
future={**good,'last_review':'2026-03-08T08:00:00Z'}
assert call(future)[0]==422
assert call({**future,'legacy_last_review_day':'2026-03-08'})[0]==200
print('PASS FSRS typed validation, new-card defaults and explicit legacy-date compatibility')
