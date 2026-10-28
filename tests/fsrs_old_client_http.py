#!/usr/bin/env python3
"""An old client ignoring event versions must not settle an unsafe replay."""
import copy, json, os, sys, urllib.request
url = os.getenv('VOCAB_TEST_BASE','http://127.0.0.1:18765')
fixture = json.load(open(sys.argv[1])); token=fixture['token']

def request(path, data=None, method=None):
    headers={'Content-Type':'application/json','Authorization':'Bearer '+token}
    req=urllib.request.Request(url+path,json.dumps(data).encode() if data is not None else None,headers,method=method)
    with urllib.request.urlopen(req,timeout=15) as response: return json.load(response)

old = copy.deepcopy(fixture['state']); card=old['cards']['apple']; pending=card['pendingFsrs']; body=pending['base']
# Emulate the previous client: all events use current server parameters, ignoring per-event keys.
for event in pending['events']:
    result=request('/api/v1/fsrs/review',{**body,'rating':event['rating'],'now':event['at'],'deterministic':True})
    body={k:result[k] for k in ('state','stability','difficulty','due','step','last_review')}
assert result['due'] != fixture['expected']['due']
card['fsrs']={k:result[k] for k in ('state','stability','difficulty','due','step','scheduled_days')}
card['fsrs']['lastReview']=result['last_review']; card['due']=result['due']
card['appliedFsrs']=[e['id'] for e in pending['events']]
card.pop('pendingFsrs'); card.pop('fsrsReplayVersions',None)
request('/api/v1/me/state', old, 'PUT')
saved=request('/api/v1/me/state')['state']['cards']['apple']
assert 'pendingFsrs' in saved and 'fsrsReplayVersions' not in saved
print('PASS old HTTP client cannot settle a replay that ignores mixed scheduler versions')
