#!/usr/bin/env python3
"""Pagination reports scanned positions even for pages without content words."""
from unittest.mock import patch
from pathlib import Path
from tempfile import TemporaryDirectory
import shutil, sys

# Import an isolated application copy so startup cannot create databases in
# either the repository or a developer's configured data directory.
tmp = TemporaryDirectory(prefix='vocab-pagination-')
root = Path(tmp.name)
shutil.copytree(Path(__file__).parent / 'app', root / 'app', ignore=shutil.ignore_patterns('__pycache__'))
(root / 'data').mkdir()
shutil.copy2(Path(__file__).resolve().parents[1] / 'data' / 'lexicon_v0.1.sqlite', root / 'data' / 'lexicon_v0.1.sqlite')
(root / 'static').mkdir()
sys.path.insert(0, str(root))
from app import main

rows = [{'id': i} for i in range(1, 86)]
tags = {45: 'n', 85: 'v'}
with patch.object(main, 'seq', rows), patch.object(main, 'PTAG', tags), \
     patch.object(main, 'word_detail', lambda wid: {'word': f'w{wid}', 'pos': wid}):
    def check(value, expected):
        assert all(value[k]==v for k,v in expected.items()),(value,expected)
        assert value['lexicon_revision']==main.LEXICON_REVISION
        assert value['remaining_positions']==max(0,len(rows)-value['next_pos']+1)
    first = main.lexicon_at(pos=1, n=2)
    check(first, {'from': 1, 'words': [], 'next_pos': 41, 'exhausted': False})
    second = main.lexicon_at(pos=first['next_pos'], n=2)
    check(second, {'from': 41, 'words': [{'word': 'w45', 'pos': 45}], 'next_pos': 81, 'exhausted': False})
    third = main.lexicon_at(pos=second['next_pos'], n=2)
    check(third, {'from': 81, 'words': [{'word': 'w85', 'pos': 85}], 'next_pos': 86, 'exhausted': True})
    beyond = main.lexicon_at(pos=999, n=2)
    check(beyond, {'from': 999, 'words': [], 'next_pos': 999, 'exhausted': True})
    one = main.lexicon_at(pos=41, n=1)
    assert one['next_pos'] == 46 and one['exhausted'] is False
print('PASS lexicon scan cursor, empty pages, bounded result and confirmed exhaustion')
tmp.cleanup()
