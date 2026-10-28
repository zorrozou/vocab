#!/usr/bin/env python3
"""Scan every snapshot word in both directions against the isolated app copy."""
import sys,time
sys.path.insert(0, sys.argv[1] if len(sys.argv) > 1 else 'server')
from app import main as m

start=time.monotonic(); unavailable=[]
for pos, row in enumerate(m.seq,1):
    target=row['id']; target_meanings=m._QUIZ_MEANINGS.get(target,set())
    for mode in ('forward','reverse'):
        q=m.quiz(pos=pos,seed=42,mode=mode); options=q['options']
        if not options:
            unavailable.append((pos,row['word'],mode,q.get('reason','missing_gloss')))
            continue
        assert len(options)==4 and sum(bool(o['ok']) for o in options)==1, (pos,mode,q)
        assert len({o['text'] for o in options})==4, (pos,mode,q)
        for o in options:
            if o['ok']: continue
            if mode=='reverse':
                wid=m.WORD2ID[o['text']]; parts=m._QUIZ_MEANINGS.get(wid,set())
            else:
                parts=m._gloss_parts(o['text'].split('. ',1)[-1])
            assert not m._gloss_overlaps(target_meanings,parts), (pos,mode,q)
assert not unavailable, f'unavailable questions: {unavailable[:20]} (total {len(unavailable)})'
print(f'PASS {len(m.seq)} words in both directions; no literal sense overlaps and four unique choices ({time.monotonic()-start:.1f}s)')
