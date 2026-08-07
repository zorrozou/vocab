# -*- coding: utf-8 -*-
"""缺档补齐 + 失败重试收尾批（进程池 + 逐级放宽 + 音频同步产出）
任务：所有未满三档的词。每词重试直到成功：
  尝试1-2：严格（词汇 ≤ cap，结构要求）
  尝试3-4：词汇放宽（tier2 +800 / tier3 +1500）
  尝试5-6：全词库词汇
  尝试7+：降低结构要求（保留长度与目标词）
每生成一句立刻产出其 TTS 音频（临时文件+原子改名）
用法: python gen_fill_pool.py [--workers 8]
"""
import argparse, asyncio, hashlib, json, os, re, sqlite3, sys, threading, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import edge_tts

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sentence_batch import load, toks

ROOT = Path(__file__).resolve().parent
DB = ROOT / "data" / "lexicon_v0.1.sqlite"
TTS_DIR = ROOT / "data" / "tts_cache"
TTS_DIR.mkdir(exist_ok=True)
NEW_PER_DAY = 10
TIER_LEN = {1: 10, 2: 16, 3: 20}
TIER_DESC = {1: "基础句，3~10 个单词，简单句",
             2: "进阶句，10~16 个单词，含一个从句（when/because/that/which/who 等）",
             3: "挑战句，10~20 个单词，含复合结构（从句/非谓语/介词短语组合）"}
VOICE = os.environ.get("TTS_VOICE", "en-US-AriaNeural")
BLACKLIST = {"n't"}  # 碎片词条，不作为学习目标
BASE = os.environ.get("LLM_BASE_URL", "").rstrip("/")
KEY = os.environ.get("LLM_API_KEY", "")
MODEL = os.environ.get("LLM_MODEL", "glm-4.6")

db_lock = threading.Lock()
counter_lock = threading.Lock()
stats = {"done_words": 0, "sentences": 0, "audios": 0, "stuck": 0}


def call_llm(prompt, max_tokens=200):
    req = urllib.request.Request(
        f"{BASE}/chat/completions",
        data=json.dumps({"model": MODEL, "messages": [{"role": "user", "content": prompt}],
                         "thinking": {"type": "disabled"}, "temperature": 0.85,
                         "max_tokens": max_tokens}).encode(),
        headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    for a in range(3):
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                return json.loads(r.read())["choices"][0]["message"]["content"]
        except Exception:
            if a == 2:
                raise
            time.sleep(2 + a * 2)


def tts(text):
    key = hashlib.sha1(f"{VOICE}|{text}".encode()).hexdigest()[:16]
    f = TTS_DIR / f"{key}.mp3"
    if f.exists():
        return
    tmp = TTS_DIR / f"{key}.{os.getpid()}{threading.get_ident()}.tmp"
    try:
        asyncio.run(edge_tts.Communicate(text, VOICE).save(str(tmp)))
        os.replace(tmp, f)
        with counter_lock:
            stats["audios"] += 1
    except Exception:
        try:
            tmp.unlink(missing_ok=True)
        except Exception:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workers", type=int, default=8)
    args = ap.parse_args()
    conn, seq, pos_of, id2word, word2id, pos_tag, senses_core, vmap = load()
    cur = conn.cursor()

    senses_cache = {}
    for wid, w, lv, frq in seq:
        senses_cache[wid] = cur.execute(
            "SELECT id, role, pos, text FROM sense WHERE wordId=? AND role IN ('core','ext') ORDER BY senseOrder LIMIT 3",
            (wid,)).fetchall()

    tasks = []
    for i, (wid, w, lv, frq) in enumerate(seq, 1):
        if not senses_cache.get(wid) or w in BLACKLIST:
            continue
        have = {r[0] for r in cur.execute(
            "SELECT tier FROM sentence WHERE targetWordId=? AND genMethod='llm-tier-v1'", (wid,))}
        miss = [t for t in (1, 2, 3) if t not in have]
        if miss:
            tasks.append((i, wid, w, miss))
    print(f"补齐任务: {len(tasks)} 词（缺档合计 {sum(len(m) for *_, m in tasks)} 句）· {args.workers} 并发", flush=True)

    def pick_recall(i):
        for days, tol in ((1, 5), (7, 10)):
            lo, hi = i - days * NEW_PER_DAY - tol, i - days * NEW_PER_DAY + tol
            pool = [seq[j - 1][0] for j in range(max(1, lo), min(i - 1, hi) + 1)]
            pool.sort(key=lambda r: 0 if (pos_tag.get(r) or "").startswith(("n", "v", "a")) else 1)
            if pool:
                return pool[0]
        return None

    def validate(text, tier, wid, rid, cap, pos, allow_oov=0):
        ts = toks(text)
        if not (3 <= len(ts) <= TIER_LEN[tier]):
            return f"长度{len(ts)}"
        hit_t = hit_r = False
        oov = 0
        for t in ts:
            tw = word2id.get(vmap.get(t, t))
            if tw is None:
                oov += 1
                if oov > allow_oov:
                    return f"词库外:{t}"
                continue
            if pos_of[tw] > cap and tw != wid:
                return f"超范围:{t}"
            hit_t |= (tw == wid or t == id2word[wid])   # 目标词本身若是词形变体（her→she），按原词命中
            hit_r |= (rid is not None and tw == rid)
        if not hit_t:
            return "缺目标词"
        if tier == 1 and rid and not hit_r:
            return "缺召回词"
        return None

    def gen_word(task):
        i, wid, w, miss = task
        senses = senses_cache[wid]
        rid = pick_recall(i)
        rw = id2word[rid] if rid else None
        multi = len(senses) >= 2
        sense_txt = senses[0][3][:50]
        base_cap = max(i, 300)

        for tier in miss:
            desc = TIER_DESC[tier]
            inserted = False
            for attempt in range(1, 10):
                if attempt <= 2:
                    cap, relax = base_cap, ""
                elif attempt <= 4:
                    cap, relax = base_cap + (800 if tier == 2 else 1500), ""
                elif attempt <= 6:
                    cap, relax = 10991, "词汇可用全词库任意常见词。"
                else:
                    cap, relax = 10991, "只需是一句自然、有意义的英语句子即可，不必满足从句等结构要求。"
                eff_rid = rid if (tier == 1 and attempt <= 4) else None  # 后期放宽召回硬性要求
                prompt = (f"为背单词 App 的单词 \"{w}\"（词义：{sense_txt}）写一条英语例句：{desc}。"
                          + (f"必须包含复习词 \"{rw}\"。" if rw and tier == 1 and attempt <= 4 else "")
                          + ("" if multi else "演示该词最常见义项。")
                          + f"其他约束：句子自然、地道、有意义；{relax}"
                          + "输出格式：英文句子 || 中文翻译，一行，不要其他内容。")
                try:
                    out = call_llm(prompt)
                except Exception:
                    time.sleep(2)
                    continue
                body, _, zh = out.strip().strip('"').splitlines()[0].partition("||")
                text = re.sub(r"^[ABC][::.]\s*", "", body).strip()
                err = validate(text, tier, wid, eff_rid, cap, pos_of,
                               allow_oov=1 if attempt >= 7 else 0)
                if err:
                    continue
                with db_lock:
                    sid = senses[min(tier - 1, len(senses) - 1)][0] if multi else senses[0][0]
                    cur.execute("""INSERT INTO sentence(text, translation, wordIds, senseId, targetWordId, recallIds, genMethod, flag, tier)
                                   VALUES(?,?,?,?,?,?,?,?,?)""",
                                (text, zh.strip(), json.dumps([wid]), sid, wid,
                                 json.dumps([eff_rid] if (eff_rid and tier == 1) else []),
                                 "llm-tier-v1", "fill_pass", tier))
                    conn.commit()
                with counter_lock:
                    stats["sentences"] += 1
                tts(text)
                inserted = True
                break
            if not inserted:
                with counter_lock:
                    stats["stuck"] += 1
                    print(f"⚠ #{i} {w} tier{tier} 九次未过", flush=True)
        with counter_lock:
            stats["done_words"] += 1
            if stats["done_words"] % 100 == 0:
                print(f"[{stats['done_words']}/{len(tasks)}] 句+{stats['sentences']} 音+{stats['audios']}", flush=True)

    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        list(ex.map(gen_word, tasks))

    print(f"\n收尾完成: 词 {stats['done_words']}，新句 {stats['sentences']}，新音频 {stats['audios']}，仍失败 {stats['stuck']}", flush=True)


if __name__ == "__main__":
    main()
