"""Verify client/server rounding compatibility without persisting posterior drift."""
import copy, json, sys, urllib.error, urllib.request, uuid
sys.path.insert(0, 'server')
from app.posterior_evidence import replay
BASE = 'http://127.0.0.1:18765'
def call(path, body=None, token=None, method=None):
    headers = {'Content-Type':'application/json'}
    if token: headers['Authorization'] = 'Bearer ' + token
    request = urllib.request.Request(BASE+path, None if body is None else json.dumps(body).encode(), headers, method=method)
    with urllib.request.urlopen(request, timeout=15) as response: return json.load(response)
assert call('/api/v1/__ui_fixture')['fixture'] == 'vocab-ui-isolated-v1'
account = call('/api/v1/auth/register', {'username':'post_'+uuid.uuid4().hex[:10], 'password':'test_password_123'})
token = account['token']
history = {'algorithm':'bayes-grid-1', 'baseId':'empty', 'baseCount':0, 'base':None, 'events':{}}
for i,(rank,resp,weight,guess) in enumerate([(2331,0,.15,.25),(2009,1,1,.25),(2449,0,.15,.25)]):
    history['events'][f'e{i}'] = {'kind':'update','device':'device','at':'2026-10-27T00:00:00Z', 'day':'2026-10-27',
        'parents':[f'e{i-1}'] if i else [],'rank':rank,'resp':resp,'weight':weight,'guess':guess}
prefix = copy.deepcopy(history); prefix['events'].pop('e2')
base,_ = replay(prefix)
suffix = {'algorithm':'bayes-grid-1','baseId':'prefix','baseCount':2,'base':base,
          'events':{'e2':{**history['events']['e2'],'parents':[]}}}
mixed,count = replay(suffix,client_arithmetic=True)
canonical,_ = replay(history)
state = {'v':1,'cards':{},'log':[],'pendingNew':[],'settings':{},'posterior':mixed,'posteriorHistory':history,'probeCount':count}
call('/api/v1/me/state', state, token, 'PUT')
server = call('/api/v1/me/state', token=token)
assert server['state']['posterior'] == canonical
bad = copy.deepcopy(state); bad['posterior'][0] += .001; bad['posterior'][1] -= .001
try: call('/api/v1/me/state', bad, token, 'PUT')
except urllib.error.HTTPError as error: assert error.code == 409
else: raise AssertionError('materially inconsistent posterior was accepted')
assert call('/api/v1/me/state',token=token)['state']['posterior'] == canonical
restored = call('/api/v1/me/state/restore', {'state':state,'expected_updated_at':server['updated_at']}, token)
assert restored['state']['posterior'] == canonical
print('PASS mixed posterior rounding is canonicalized on upload and restore; material mismatch rejected')
