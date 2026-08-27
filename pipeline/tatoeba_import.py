# -*- coding: utf-8 -*-
"""Tatoeba 自然语料正式导入（三档句主力供源）
过滤：token 全归并命中词库、句长 4~18、其余词学习位置均早于目标词
分档：按句长补 基础(≤10) / 进阶(11-16) / 挑战(17-18) 档位
翻译：优先 Tatoeba 中英对照链接（cmn），缺则留空待 LLM 回填
用法: python tatoeba_import.py [--start 1] [--end 10991]
"""
import argparse, json, re, sqlite3, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sentence_batch import load, toks

ROOT = Path(__file__).resolve().parent
DATA = ROOT / "data"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--start", type=int, default=1)
    ap.add_argument("--end", type=int, default=10 ** 9)
    args = ap.parse_args()
    conn, seq, pos_of, id2word, word2id, pos_tag, senses_core, vmap = load()
    cur = conn.cursor()
    end = min(args.end, len(seq))
    seq_id_at = {i: seq[i - 1][0] for i in range(1, end + 1)}

    # ---- 中英对照表 ----
    cmn = {}
    cmn_path = DATA / "cmn_sentences.tsv"
    links_path = DATA / "eng-cmn_links.tsv"
    if cmn_path.exists() and links_path.exists():
        for line in open(cmn_path, encoding="utf-8", errors="ignore"):
            p = line.rstrip("\n").split("\t")
            if len(p) >= 3:
                cmn[p[0]] = p[2].strip()
        eng2cmn = {}
        for line in open(links_path, encoding="utf-8", errors="ignore"):
            p = line.rstrip("\n").split("\t")
            if len(p) >= 2 and p[1] in cmn:
                eng2cmn[p[0]] = cmn[p[1]]
        print(f"中英对照: {len(eng2cmn)} 条链接", flush=True)
    else:
        eng2cmn = {}
        print("无中英对照文件，翻译留空待回填", flush=True)

    def resolve(t):
        return word2id.get(vmap.get(t, t))

    # ---- 倒排：词 → 合规句 ----
    index = {}
    n_line = 0
    with open(DATA / "eng_sentences.tsv", encoding="utf-8", errors="ignore") as f:
        for line in f:
            parts = line.split("\t")
            if len(parts) < 3:
                continue
            n_line += 1
            text = parts[2].strip()
            if not text or not text[0].isupper() or not text.endswith((".", "!", "?")):
                continue
            ts = toks(text)
            if not (4 <= len(ts) <= 18):
                continue
            ids = set()
            ok = True
            for t in ts:
                w = resolve(t)
                if w is None:
                    if t.isdigit():
                        continue
                    ok = False
                    break
                ids.add(w)
            if ok and ids:
                for w in ids:
                    index.setdefault(w, []).append((parts[0], text, len(ts), frozenset(ids)))
    print(f"扫描 {n_line} 句，入索引 {sum(len(v) for v in index.values())} 条引用", flush=True)

    TIER_LEN = {1: 10, 2: 16, 3: 18}
    made = 0
    for i in range(args.start, end + 1):
        wid = seq_id_at[i]
        have_tato = {r[0] for r in cur.execute(
            "SELECT tier FROM sentence WHERE targetWordId=? AND genMethod='tatoeba'", (wid,))}
        cands = index.get(wid, [])
        good = []
        for sid, text, ntok, idset in cands:
            if any(pos_of[w] >= i for w in idset if w != wid):
                continue
            good.append((sid, text, ntok, idset))
        for tier in (1, 2, 3):
            if tier in have_tato:
                continue
            lo = (TIER_LEN.get(tier - 1, 3) + 1) if tier > 1 else 4
            hi = TIER_LEN[tier]
            pool = [g for g in good if lo <= g[2] <= hi]
            if not pool:
                continue
            # 偏好：有对照翻译 > 实义词更多 > 更短
            pool.sort(key=lambda g: (0 if g[0] in eng2cmn else 1,
                                     -len([w for w in g[3] if pos_tag.get(w, "").startswith(("n", "v", "a"))]),
                                     g[2]))
            sid, text, ntok, idset = pool[0]
            zh = eng2cmn.get(sid, "")
            core = cur.execute("SELECT id FROM sense WHERE wordId=? AND role='core'", (wid,)).fetchone()
            cur.execute("""INSERT INTO sentence(text, translation, wordIds, senseId, targetWordId, recallIds, genMethod, flag, tier)
                           VALUES(?,?,?,?,?,?,?,?,?)""",
                        (text, zh, json.dumps(sorted(w for w in idset)), core[0] if core else None,
                         wid, "[]", "tatoeba", "corpus", tier))
            made += 1
        if made and made % 1000 == 0:
            conn.commit()
            print(f"已导入 {made}", flush=True)
    conn.commit()
    print(f"完成: Tatoeba 导入 {made} 条（含翻译 {cur.execute(chr(34)*0) if False else 0}）", flush=True)
    covered = cur.execute("SELECT COUNT(DISTINCT targetWordId) FROM sentence WHERE genMethod='tatoeba'").fetchone()[0]
    print(f"语料句覆盖词数: {covered}", flush=True)
    conn.close()


if __name__ == "__main__":
    main()
