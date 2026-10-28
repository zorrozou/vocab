#!/usr/bin/env python3
"""Concurrent reads use independent read-only SQLite connections."""
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from app.main import WORD2ID, static_sentences, core_sense, _lx

items = list(WORD2ID.items())[:2]
expected = {wid: (static_sentences(wid), core_sense(wid)) for _, wid in items}
barrier = Barrier(8)
def work(_):
    barrier.wait()
    for _, wid in items:
        assert (static_sentences(wid), core_sense(wid)) == expected[wid]
    return id(_lx.local.connection)
with ThreadPoolExecutor(max_workers=8) as pool:
    assert len(set(pool.map(work, range(8)))) > 1
print('PASS concurrent lexicon reads use separate connections and preserve results')
