# -*- coding: utf-8 -*-
"""验证：固定学习顺序下，复习点在编译期可预测
学习顺序固定（词频降序、10词/天）→ 学到第 i 个词时，
艾宾浩斯各节点的到期词 ≈ 序列中 i-10(昨日) / i-70(上周) / i-150(半月) / i-300(月度) 的词。
因此对每个新词，可以在编译期静态指定"例句要召回的旧词"，保证每句都有近期生词。
本脚本验证：偏移窗口内是否总有可用的、且确实先于当前位置学过的旧词。
"""
import sqlite3
from pathlib import Path

DB = Path(__file__).resolve().parent / "data" / "lexicon_v0.1.sqlite"
conn = sqlite3.connect(DB)
# 学习序列：L1 → L2 → L3，各层内按 frq 升序
seq = [r[0] for r in conn.execute(
    "SELECT word FROM lexicon_entry ORDER BY level, frq")]
conn.close()

NEW_PER_DAY = 10
OFFSETS = {"D1 昨日": 1, "D7 上周": 7, "D15 半月": 15, "D30 月度": 30}

print(f"学习序列总长: {len(seq)} 词（L1+L2+L3）\n")
print("新词(位置)           | " + " | ".join(OFFSETS))
print("-" * 78)
for i in (310, 500, 800, 1200, 2000, 3000):
    recalls = []
    for days in OFFSETS.values():
        j = i - days * NEW_PER_DAY
        recalls.append(seq[j] if j >= 0 else "—")
    print(f"{seq[i]:<14}(#{i:>4})  | " + " | ".join(f"{w:<10}" for w in recalls))

# 可用性统计：每个位置有多少比例四个偏移都有词
ok = sum(1 for i in range(len(seq)) if i - 30 * NEW_PER_DAY >= 0)
print(f"\n四个偏移全部有词的位置: {ok}/{len(seq)}（前 300 词处于冷启动期，用预编句兜底）")

# 词性搭配可用性：抽查召回词的词性分布（用于模板匹配）
conn = sqlite3.connect(DB)
print("\n各偏移窗口内召回词的词性抽样（模板生成需要名词/动词/形容词搭配）:")
for i in (500, 1200, 2000):
    parts = []
    for days in OFFSETS.values():
        w = seq[i - days * NEW_PER_DAY]
        row = conn.execute(
            "SELECT pos FROM sense WHERE wordId=(SELECT id FROM lexicon_entry WHERE word=?) AND role='core'",
            (w,)).fetchone()
        parts.append(f"{w}({row[0] if row and row[0] else '?'})")
    print(f"  #{i:>4} {seq[i]:<12} → " + ", ".join(parts))
conn.close()
