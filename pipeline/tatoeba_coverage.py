# -*- coding: utf-8 -*-
"""Tatoeba 共现覆盖率实测
问题：对"新词 + 遗忘偏移窗口召回词"的共现句，开源句库能筛出多少？（决定 先筛后造 配比）
方法：严格过滤（全部 token 可归并到词库，数字/首字母大写词豁免）→ 倒排索引 →
对 L1 每个位置 i，检查句：其余词位置 < i 且 含 [i-15,i-5]∪[i-80,i-60] 窗口词。
同时测三档句长（12/16/20）与"保底句"（不要求召回）覆盖率作对照。
"""
import json, re, sqlite3, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DB = ROOT / "data" / "lexicon_v0.1.sqlite"
TSV = ROOT / "data" / "eng_sentences.tsv"
CAPS = (12, 16, 20)
WIN = ((15, 5), (80, 60))   # (近期偏移, 容差)

toks = lambda t: [x.strip("'") for x in re.findall(r"[a-zA-Z']+", t.lower()) if x.strip("'")]


def main():
    t0 = time.time()
    conn = sqlite3.connect(DB)
    cur = conn.cursor()
    seq = cur.execute("SELECT id, word FROM lexicon_entry ORDER BY level, frq").fetchall()
    pos_of = {wid: i for i, (wid, w) in enumerate(seq, 1)}
    id2word = dict(seq)
    word2id = {w: wid for wid, w in seq}
    vmap = {v: l for v, l in cur.execute("SELECT variant, lemma FROM variant_map")}
    conn.close()
    L1_MAX = 903  # L1 词数（本次实测范围）

    def resolve(t):
        return word2id.get(vmap.get(t, t))

    # ---- 建倒排索引：word -> [ (sid, frozenset(wordIds), ntok) ] ----
    index = {}
    n_total = n_kept = 0
    with open(TSV, encoding="utf-8", errors="ignore") as f:
        for line in f:
            parts = line.split("\t")
            if len(parts) < 3:
                continue
            n_total += 1
            ts = toks(parts[2])
            if not (3 <= len(ts) <= 20):
                continue
            ids = set()
            ok = True
            for t in ts:
                w = resolve(t)
                if w is None:
                    if t.isdigit() or (parts[2].split()[0][:1].isupper() and t[0].isupper() and len(t) > 1):
                        continue  # 数字/句首大写专名豁免
                    ok = False
                    break
                ids.add(w)
            if not ok:
                continue
            n_kept += 1
            for w in ids:
                index.setdefault(w, []).append((frozenset(ids), len(ts)))
    print(f"句库 {n_total} 句，严格过滤后 {n_kept} 句入索引（{time.time()-t0:.0f}s）")

    def windows(i):
        for span, tol in WIN:
            lo, hi = i - span - tol, i - span + tol
            yield range(max(1, lo), max(0, hi) + 1)

    # ---- 覆盖测试 ----
    stats = {c: dict(recall=0, base=0, recall2=0) for c in CAPS}
    examples = []
    for i in range(1, L1_MAX + 1):
        wid = seq[i - 1][0]
        cands = index.get(wid, [])
        for cap in CAPS:
            base_ok = 0
            recall_ok = 0
            win_ids = set()
            for r in windows(i):
                win_ids.update(r)
            for idset, ntok in cands:
                if ntok > cap:
                    continue
                if any(pos_of[w] >= i for w in idset if w != wid):
                    continue  # 含未学词
                base_ok += 1
                if any(pos_of[w] in win_ids for w in idset if w != wid):
                    recall_ok += 1
            if base_ok:
                stats[cap]["base"] += 1
            if recall_ok:
                stats[cap]["recall"] += 1
                if recall_ok >= 2:
                    stats[cap]["recall2"] += 1
        # 抽几个例句展示
        if i in (350, 600, 903) and not any(e[0] == i for e in examples):
            for idset, ntok in index.get(wid, []):
                win_ids = set()
                for r in windows(i):
                    win_ids.update(r)
                if ntok <= 16 and all(pos_of[w] < i for w in idset if w != wid) and \
                   any(pos_of[w] in win_ids for w in idset if w != wid):
                    examples.append((i, id2word[wid], idset, ntok))
                    break

    print("\n" + "=" * 62)
    print("共现覆盖率实测（L1 903 词）")
    print("=" * 62)
    print(f"{'句长上限':<8}{'保底句(仅合规)':<18}{'共现句≥1(筛)':<18}{'共现句≥2':<12}")
    for c in CAPS:
        s = stats[c]
        print(f"≤{c:<6}{s['base']}/903 ({s['base']/903*100:.0f}%){'':>5}"
              f"{s['recall']}/903 ({s['recall']/903*100:.0f}%){'':>5}"
              f"{s['recall2']}/903 ({s['recall2']/903*100:.0f}%)")

    # 需要看原句：从文件里按行重取（索引只存 id 集合）
    if examples:
        wanted = [e[2] for e in examples]
        found = {}
        with open(TSV, encoding="utf-8", errors="ignore") as f:
            for line in f:
                parts = line.split("\t")
                if len(parts) < 3 or len(examples) == len(found):
                    continue
                ts = frozenset(w for w in (resolve(t) for t in toks(parts[2])) if w)
                for k, (i, w, idset, ntok) in enumerate(examples):
                    if k not in found and ts == idset:
                        found[k] = parts[2].strip()
        print("\n共现句实例（新词 ← 召回词位置差）:")
        for k, (i, w, idset, ntok) in enumerate(examples):
            if k in found:
                recalls = sorted({id2word[x] for x in idset if x != seq[i-1][0]})
                print(f"  #{i} {w}: {found[k]}")
                print(f"      句内含旧词: {recalls}")


if __name__ == "__main__":
    main()
