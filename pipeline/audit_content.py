#!/usr/bin/env python3
"""Read-only audit of static sentence coverage; output Markdown, never modify the lexicon."""
import argparse
import sqlite3
from collections import defaultdict
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--db', default=str(Path(__file__).resolve().parents[1] / 'data' / 'lexicon_v0.1.sqlite'))
args = parser.parse_args()
path = Path(args.db).resolve()
conn = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True)
words = conn.execute('SELECT id, word FROM lexicon_entry ORDER BY level, frq').fetchall()
rows = conn.execute("""
    SELECT targetWordId, tier, text, translation, genMethod FROM (
      SELECT targetWordId, tier, text, translation, genMethod,
             ROW_NUMBER() OVER (PARTITION BY targetWordId, tier ORDER BY
               CASE genMethod WHEN 'tatoeba' THEN 0 WHEN 'llm-tier-v1' THEN 1 ELSE 2 END, id DESC) AS rank
      FROM sentence WHERE (genMethod LIKE 'llm-%' OR genMethod='tatoeba') AND COALESCE(flag,'')!='reported'
    ) WHERE rank=1
""").fetchall()
by_word = defaultdict(dict)
for wid, tier, text, translation, method in rows:
    by_word[wid][tier] = (text, translation, method)
missing = [(pos, word, [t for t in (1, 2, 3) if t not in by_word[wid]])
           for pos, (wid, word) in enumerate(words, 1) if any(t not in by_word[wid] for t in (1, 2, 3))]
no_zh = [(pos, word, tier) for pos, (wid, word) in enumerate(words, 1)
         for tier in (1, 2, 3) if tier in by_word[wid] and not (by_word[wid][tier][1] or '').strip()]
print('# 词库静态例句缺档清单\n')
print('该清单来自仓库词库快照，按当前服务的可见规则筛选：LLM/Tatoeba 来源、未标记 reported，并使用各档优先展示的句子。它不是生产库质量评估，词义、自然度、翻译准确性与语料授权仍需人工审核。\n')
print(f'- 词条：{len(words)}；缺至少一档：{len(missing)}；优先展示句缺中文翻译：{len(no_zh)} 条。')
print('- 档位编号：1 基础、2 进阶、3 挑战。\n')
print('## 缺档词条\n\n| 词频序号 | 单词 | 缺少档位 |\n| ---: | --- | --- |')
for pos, word, tiers in missing:
    safe_word = word.replace("|", "\\|")
    print(f'| {pos} | {safe_word} | {", ".join(map(str, tiers))} |')
print('\n## 优先展示句缺中文翻译\n\n| 词频序号 | 单词 | 档位 |\n| ---: | --- | ---: |')
for pos, word, tier in no_zh:
    safe_word = word.replace("|", "\\|")
    print(f'| {pos} | {safe_word} | {tier} |')
