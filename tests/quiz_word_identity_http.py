"""A saved rank must never silently select another word's quiz."""
import json, os, urllib.request, urllib.error
base=os.environ.get('VOCAB_TEST_BASE','http://127.0.0.1:18765').rstrip('/')
def get(path):
    with urllib.request.urlopen(base+path,timeout=15) as response: return json.load(response)
apple=get('/api/v1/lexicon/word?word=apple')
legacy=get('/api/v1/quiz?pos=1&seed=7')
assert legacy['word']!='apple'
for mode in ['forward','reverse']:
    q=get('/api/v1/quiz?pos=1&word=Apple&seed=7&mode='+mode)
    assert q['word']=='apple' and q['pos']==apple['pos']
    assert len(q['options'])==4 and sum(o['ok'] for o in q['options'])==1
    correct=next(o['text'] for o in q['options'] if o['ok'])
    assert ('apple'==correct) if mode=='reverse' else ('苹果' in correct)
try: get('/api/v1/quiz?pos=1&word=doesnotexistvocab')
except urllib.error.HTTPError as error: assert error.code==404
else: raise AssertionError('unknown word fell back to rank')
assert get('/api/v1/quiz?pos=1&seed=7')==legacy
print('PASS quiz follows word identity despite stale rank, supports both directions and rejects unknown words')
