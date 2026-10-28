"""Server-issued guest secrets isolate jobs; device identifiers alone are insufficient."""
import json, urllib.request, urllib.error, urllib.parse, uuid
base = 'http://127.0.0.1:18765'
def call(path, body=None, token=None, authorization=None):
    headers = {'Content-Type':'application/json'}
    if token: headers['X-Guest-Token'] = token
    if authorization: headers['Authorization'] = authorization
    req = urllib.request.Request(base + path, None if body is None else json.dumps(body).encode(), headers)
    with urllib.request.urlopen(req, timeout=10) as r: return json.load(r)
def status(fn, code):
    try: fn()
    except urllib.error.HTTPError as e: assert e.code == code, e.code
    else: raise AssertionError('request unexpectedly succeeded')
a, b = call('/api/v1/auth/guest', {})['token'], call('/api/v1/auth/guest', {})['token']
assert len(a) == 64 and a != b
job = 'guest-' + uuid.uuid4().hex
payload = {'device':'web-public-device','date':'2026-10-27','weak_words':['apple'],'learned_max_pos':5000,'sync':True,'request_id':job}
status(lambda: call('/api/v1/personalize', payload), 401)
status(lambda: call('/api/v1/personalize', payload, '0' * 64), 401)
assert call('/api/v1/personalize', payload, a)['job_id'] == job
query = urllib.parse.urlencode({'job_id':job,'device':'web-public-device'})
assert call('/api/v1/personalized/job?' + query, token=a)['job_id'] == job
status(lambda: call('/api/v1/personalized/job?' + query), 401)
status(lambda: call('/api/v1/personalized/job?' + query, token=b), 404)
status(lambda: call('/api/v1/personalized/job?' + query, token=a, authorization='Bearer invalid'), 401)
print('PASS issued guest credentials isolate jobs from public device IDs and invalid tokens')
