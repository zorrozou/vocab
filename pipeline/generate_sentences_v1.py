# -*- coding: utf-8 -*-
"""例句生成管线 v1：模板引擎 + 校验器
为 L1 每个词生成"保证型"例句：包含遗忘偏移窗口内的近期生词（召回词），
其余词汇全部来自已学序列位置。每条必须通过校验器硬检才入库。
"""
import json, random, re, sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DB = ROOT / "data" / "lexicon_v0.1.sqlite"
NEW_PER_DAY = 10
RECALL_WINDOWS = [(1, 5), (7, 10)]  # (天数, 容差): D1±5, D7±10 → 位置窗口
MAX_LEN = 12
COLD_START = 300  # 前 300 词历史词汇薄，标 flag 供人工预编补充

POS_MAP = {"n": "n", "v": "v", "vt": "vt", "vi": "vi", "a": "a", "adj": "a",
           "ad": "ad", "adv": "ad", "prep": "prep", "conj": "conj", "pron": "pron",
           "num": "num", "int": "int", "art": "art", "abbr": "other"}


def toks(text):
    return [t.strip("'") for t in re.findall(r"[a-zA-Z']+", text.lower()) if t.strip("'")]


def main():
    conn = sqlite3.connect(DB)
    cur = conn.cursor()
    # ---- 学习序列（L1，按词频）----
    seq = cur.execute(
        "SELECT id, word FROM lexicon_entry WHERE level=1 ORDER BY frq").fetchall()
    pos_of = {}   # id -> 1-based 位置
    for i, (wid, w) in enumerate(seq, start=1):
        pos_of[wid] = i
    id2word = {wid: w for wid, w in seq}
    word2id = {w: wid for wid, w in seq}

    # 词性（core 义项）
    pos_tag = {}
    for wid, p in cur.execute("SELECT wordId, pos FROM sense WHERE role='core'"):
        pos_tag[wid] = POS_MAP.get((p or "").strip(), "other")
    # 词形归并
    vmap = {v: l for v, l in cur.execute("SELECT variant, lemma FROM variant_map")}

    def resolve(token):
        w = vmap.get(token, token)
        return word2id.get(w)

    # ---- 模板：key = (新词词性, 召回词词性) ----
    T = {
        ("n", "n"):  ["The {N} and the {R} are here.", "My {N} is near the {R}."],
        ("n", "a"):  ["The {N} is very {R}."],
        ("n", "vt"): ["We {R} the {N} every day.", "They {R} my {N}."],
        ("n", "v"):  ["We {R} the {N} every day."],
        ("n", "vi"): ["We {R} with the {N}."],
        ("n", "ad"): ["The {N} is here {R}."],
        ("vt", "n"): ["I {N} the {R} every day."],
        ("vt", "a"): ["I {N} it {R}."],
        ("v", "n"):  ["I {N} the {R} every day."],
        ("vi", "n"): ["I {N} with the {R}."],
        ("vi", "ad"): ["I {N} {R}."],
        ("a", "n"):  ["The {R} is {N}."],
        ("a", "vt"): ["They {R} the {N} one."],
        ("ad", "n"): ["They like the {R} {N}."],
        ("ad", "vt"): ["They {R} {N} every day."],
        ("ad", "vi"): ["They {R} {N}."],
        ("prep", "n"): ["We go {N} the {R}."],
        ("num", "n"): ["I have {N} {R} here."],
    }

    rng = random.Random(20260806)
    cur.execute("DROP TABLE IF EXISTS sentence")
    cur.execute("""CREATE TABLE sentence(
        id INTEGER PRIMARY KEY, text TEXT NOT NULL, translation TEXT,
        wordIds TEXT NOT NULL, senseId INTEGER, targetWordId INTEGER NOT NULL,
        recallIds TEXT, genMethod TEXT NOT NULL, flag TEXT)""")

    stats = dict(gen=0, solo=0, cold=0, fail=0)
    fails = {}
    samples = []
    recall_used = {}  # wid -> 最近被用作召回的位置

    def pick_recall(i, p_new):
        """在遗忘偏移窗口内选兼容性最好的召回词"""
        for days, tol in RECALL_WINDOWS:
            lo, hi = i - days * NEW_PER_DAY - tol, i - days * NEW_PER_DAY + tol
            cands = []
            for j in range(max(1, lo), min(i - 1, hi) + 1):
                rwid = seq[j - 1][0]
                rp = pos_tag.get(rwid, "other")
                if (p_new, rp) not in T:
                    continue
                last = recall_used.get(rwid, -999)
                cands.append((last, rwid, rp))
            if cands:
                cands.sort()
                return cands[0][1], cands[0][2]
        return None, None

    def validate(text, new_id, recall_id, i):
        ts = toks(text)
        if not (3 <= len(ts) <= MAX_LEN):
            return False, "len"
        ids = []
        hit_new = hit_recall = False
        for t in ts:
            wid = resolve(t)
            if wid is None:
                return False, f"unknown:{t}"
            if pos_of[wid] > i:
                return False, f"future:{t}"
            ids.append(wid)
            if wid == new_id:
                hit_new = True
            if recall_id and wid == recall_id:
                hit_recall = True
        if not hit_new:
            return False, "no_new"
        if recall_id and not hit_recall:
            return False, "no_recall"
        return True, sorted(set(ids))

    for i, (wid, w) in enumerate(seq, start=1):
        p_new = pos_tag.get(wid, "other")
        flag = "cold_start" if i <= COLD_START else None
        rid, rp = pick_recall(i, p_new)
        made = None
        if rid:
            for tpl in T[(p_new, rp)]:
                cand = tpl.replace("{N}", w).replace("{R}", id2word[rid])
                ok, res = validate(cand, wid, rid, i)
                if ok:
                    made = (cand, res, rid)
                    break
        if made is None:
            # 无召回兜底：单独成句（冷启动或兼容失败）
            solo = {
                "n": "The {N} is here.", "vt": "I {N} it every day.", "v": "I {N} it every day.",
                "vi": "I {N} every day.", "a": "It is very {N}.", "ad": "They come here {N}.",
                "prep": "It is {N} the box.", "num": "I have {N} books.",
            }.get(p_new)
            if solo:
                cand = solo.replace("{N}", w)
                ok, res = validate(cand, wid, None, i)
                if ok:
                    made = (cand, res, None)
                    stats["solo"] += 1
        if made is None:
            stats["fail"] += 1
            fails.setdefault(p_new, []).append(w)
            continue
        text, ids, rid = made
        if rid:
            recall_used[rid] = i
            stats["gen"] += 1
        sense_id = cur.execute(
            "SELECT id FROM sense WHERE wordId=? AND role='core'", (wid,)).fetchone()[0]
        cur.execute("""INSERT INTO sentence(text, translation, wordIds, senseId, targetWordId, recallIds, genMethod, flag)
                       VALUES(?,?,?,?,?,?,?,?)""",
                    (text, None, json.dumps(ids), sense_id, wid,
                     json.dumps([rid] if rid else []), "template-v1", flag))
        if i in (30, 120, 310, 450, 600, 750, 903) or (rid and len(samples) < 6 and i > 350):
            samples.append((i, w, pos_tag.get(wid), text, id2word.get(rid) if rid else None))

    conn.commit()

    total = len(seq)
    print("=" * 64)
    print("例句生成管线 v1 · 覆盖率报告（L1）")
    print("=" * 64)
    print(f"L1 词条: {total}")
    print(f"含召回词的保证型例句: {stats['gen']}（{stats['gen']/total*100:.0f}%）")
    print(f"单独成句（无召回兜底）: {stats['solo']}")
    print(f"生成失败（待 LLM/人工）: {stats['fail']}，按词性: " +
          ", ".join(f"{k}:{len(v)}" for k, v in sorted(fails.items(), key=lambda x: -len(x[1]))))
    print(f"其中冷启动区(≤{COLD_START}): {cur.execute(chr(39)+chr(39)) if False else cur.execute('SELECT COUNT(*) FROM sentence WHERE flag=?', ('cold_start',)).fetchone()[0]} 句")

    print("\n抽样检查:")
    for i, w, p, text, rw in samples:
        print(f"  #{i:>3} {w:<12}({p or '?'}) 召回[{rw or '-'}]  {text}")

    print("\n失败词抽样（每词性前5）:")
    for k, v in sorted(fails.items(), key=lambda x: -len(x[1])):
        print(f"  {k}: {', '.join(v[:5])}")
    conn.close()
    print(f"\n已写入: {DB} [sentence 表]")


if __name__ == "__main__":
    main()
