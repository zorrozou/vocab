# -*- coding: utf-8 -*-
"""例句生产环路：spec 出工单 → LLM 撰写 → validate 全检入库
用法:
  python sentence_batch.py spec    生成 data/batch_jobs.json（本批工单）
  python sentence_batch.py validate  校验 data/batch_authored.json 并入库（llm-claude-v1）
"""
import json, re, sqlite3, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DB = ROOT / "data" / "lexicon_v0.1.sqlite"
JOBS = ROOT / "data" / "batch_jobs.json"
AUTH = ROOT / "data" / "batch_authored.json"
NEW_PER_DAY = 10
MAX_LEN = 12

# 本批演示：模板质量差的词 + 模板失败的虚词（覆盖各词性）
BATCH_WORDS = ["try", "read", "boy", "maybe", "toward", "able", "involve", "somebody",
               "it", "have", "of", "and", "not", "be", "with", "people", "way", "the"]


def toks(text):
    return [t.strip("'") for t in re.findall(r"[a-zA-Z']+", text.lower()) if t.strip("'")]


def load():
    conn = sqlite3.connect(DB, timeout=30, check_same_thread=False)
    cur = conn.cursor()
    seq = cur.execute("SELECT id, word, level, frq FROM lexicon_entry ORDER BY level, frq").fetchall()
    pos_of = {wid: i for i, (wid, w, lv, f) in enumerate(seq, start=1)}
    id2word = {wid: w for wid, w, lv, f in seq}
    word2id = {w: wid for wid, w, lv, f in seq}
    pos_tag = {wid: (p or "other") for wid, p in cur.execute(
        "SELECT wordId, pos FROM sense WHERE role='core'")}
    senses = {wid: t for wid, t in cur.execute(
        "SELECT wordId, text FROM sense WHERE role='core'")}
    vmap = {v: l for v, l in cur.execute("SELECT variant, lemma FROM variant_map")}
    return conn, seq, pos_of, id2word, word2id, pos_tag, senses, vmap


def cmd_spec():
    conn, seq, pos_of, id2word, word2id, pos_tag, senses, vmap = load()
    jobs = []
    for w in BATCH_WORDS:
        wid = word2id.get(w)
        if not wid:
            print(f"!! {w} 不在词库"); continue
        i = pos_of[wid]
        recall = None
        for days, tol in ((1, 5), (7, 10)):
            lo, hi = i - days * NEW_PER_DAY - tol, i - days * NEW_PER_DAY + tol
            pool = [seq[j - 1][0] for j in range(max(1, lo), min(i - 1, hi) + 1)]
            # 优先实义词便于造句
            pool.sort(key=lambda r: 0 if (pos_tag.get(r) or "").startswith(("n", "v", "a")) else 1)
            if pool:
                recall = pool[0]
                break
        jobs.append(dict(
            word=w, pos=pos_tag.get(wid), sense=(senses.get(wid) or "")[:60],
            position=i,
            recall=(id2word[recall] if recall else None),
            recall_sense=(senses.get(recall) or "")[:40] if recall else None,
            rule=f"句长3-12词；只能用位置≤{i - 1}的已学词 + 新词本身"
                 + (f"；句中必须出现召回词 {id2word[recall]}" if recall else "；本词单独成句"),
        ))
    JOBS.write_text(json.dumps(jobs, ensure_ascii=False, indent=1))
    print(f"工单已生成 {len(jobs)} 条 → {JOBS}")
    for j in jobs:
        print(f"  #{j['position']:>3} {j['word']:<10}({j['pos']}) 召回[{j['recall'] or '-'}] {j['sense'][:30]}")
    conn.close()


def cmd_validate():
    conn, seq, pos_of, id2word, word2id, pos_tag, senses, vmap = load()
    cur = conn.cursor()
    jobs = {j["word"]: j for j in json.loads(JOBS.read_text())}
    auth = json.loads(AUTH.read_text())
    passed = failed = 0
    for w, text in auth.items():
        j = jobs.get(w)
        if not j:
            print(f"!! {w} 无工单"); failed += 1; continue
        wid = word2id[w]
        i = j["position"]
        rid = word2id.get(j["recall"]) if j["recall"] else None
        ts = toks(text)
        err = None
        ids = []
        if not (3 <= len(ts) <= MAX_LEN):
            err = f"句长 {len(ts)} 超界"
        hit_new = hit_recall = False
        for t in ts:
            lemma = vmap.get(t, t)
            tw = word2id.get(lemma)
            if tw is None:
                err = err or f"词库外词汇: {t}"
            else:
                if pos_of[tw] > i:
                    err = err or f"用了未学词: {t}(#{pos_of[tw]})"
                ids.append(tw)
                hit_new |= (tw == wid)
                hit_recall |= (rid is not None and tw == rid)
        if not hit_new:
            err = err or "未出现新词"
        if rid and not hit_recall:
            err = err or f"未出现召回词 {j['recall']}"
        if err:
            print(f"✗ {w:<10} {text}\n    → {err}")
            failed += 1
            continue
        sense_id = cur.execute("SELECT id FROM sense WHERE wordId=? AND role='core'", (wid,)).fetchone()[0]
        cur.execute("DELETE FROM sentence WHERE targetWordId=? AND genMethod='template-v1'", (wid,))
        cur.execute("""INSERT INTO sentence(text, translation, wordIds, senseId, targetWordId, recallIds, genMethod, flag)
                       VALUES(?,?,?,?,?,?,?,?)""",
                    (text.strip(), None, json.dumps(sorted(set(ids))), sense_id, wid,
                     json.dumps([rid] if rid else []), "llm-claude-v1", None))
        print(f"✓ {w:<10} {text.strip()}")
        passed += 1
    conn.commit()
    print(f"\n本批结果: 通过 {passed}，驳回 {failed}")
    n = cur.execute("SELECT COUNT(*) FROM sentence WHERE genMethod='llm-claude-v1'").fetchone()[0]
    print(f"sentence 表累计 LLM 句: {n}")
    conn.close()


if __name__ == "__main__":
    (cmd_spec if len(sys.argv) > 1 and sys.argv[1] == "spec" else cmd_validate)()
