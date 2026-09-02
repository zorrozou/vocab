# -*- coding: utf-8 -*-
"""三档例句生成管线 v3 · 进程池版
任务队列共享：N 个工人各自取下一个词，完成一个补一个（ThreadPoolExecutor）
LLM 调用天然 IO 等待，10 并发约 2~3 词/秒
用法: python gen_tiers_pool.py --start 904 --end 10991 [--workers 10] [--dry-run]
"""
import argparse, json, os, re, sqlite3, sys, threading, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sentence_batch import load, toks

ROOT = Path(__file__).resolve().parent
DB = ROOT / "data" / "lexicon_v0.1.sqlite"
NEW_PER_DAY = 10
TIER_LEN = {1: 10, 2: 16, 3: 20}
TIER_DESC = {1: "基础句，3~10 个单词，简单句",
             2: "进阶句，10~16 个单词，含一个从句（when/because/that/which/who 等）",
             3: "挑战句，10~20 个单词，含复合结构（从句/非谓语/介词短语组合）"}

BASE = os.environ.get("LLM_BASE_URL", "").rstrip("/")
KEY = os.environ.get("LLM_API_KEY", "")
MODEL = os.environ.get("LLM_MODEL", "glm-4.6")

db_lock = threading.Lock()
counter_lock = threading.Lock()
stats = {"made": 0, "skipped": 0, "failed": 0, "calls": 0}


def call_llm(prompt, max_tokens=300):
    req = urllib.request.Request(
        f"{BASE}/chat/completions",
        data=json.dumps({"model": MODEL, "messages": [{"role": "user", "content": prompt}],
                         "thinking": {"type": "disabled"}, "temperature": 0.8,
                         "max_tokens": max_tokens}).encode(),
        headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                with counter_lock:
                    stats["calls"] += 1
                return json.loads(r.read())["choices"][0]["message"]["content"]
        except Exception as e:
            if attempt == 2:
                raise
            time.sleep(2 + attempt * 2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--start", type=int, required=True)
    ap.add_argument("--end", type=int, required=True)
    ap.add_argument("--workers", type=int, default=10)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    conn, seq, pos_of, id2word, word2id, pos_tag, senses_core, vmap = load()
    cur = conn.cursor()

    senses_cache = {}
    for wid, w, lv, frq in seq:
        senses_cache[wid] = cur.execute(
            "SELECT id, role, pos, text FROM sense WHERE wordId=? AND role IN ('core','ext') ORDER BY senseOrder LIMIT 3",
            (wid,)).fetchall()

    def pick_recall(i):
        for days, tol in ((1, 5), (7, 10)):
            lo, hi = i - days * NEW_PER_DAY - tol, i - days * NEW_PER_DAY + tol
            pool = [seq[j - 1][0] for j in range(max(1, lo), min(i - 1, hi) + 1)]
            pool.sort(key=lambda r: 0 if (pos_tag.get(r) or "").startswith(("n", "v", "a")) else 1)
            if pool:
                return pool[0]
        return None

    # 任务列表：跳过已满三档的词
    tasks = []
    for i in range(args.start, min(args.end, len(seq)) + 1):
        wid = seq[i - 1][0]
        if not senses_cache.get(wid):
            stats["skipped"] += 1
            continue
        n = cur.execute("SELECT COUNT(*) FROM sentence WHERE targetWordId=? AND genMethod='llm-tier-v1'", (wid,)).fetchone()[0]
        if n >= 3:
            stats["skipped"] += 1
        else:
            tasks.append(i)
    print(f"任务: {len(tasks)} 词待生成（跳过已满 {stats['skipped']}）· 并发 {args.workers}")

    def gen_one(i):
        wid, w, lv, frq = seq[i - 1]
        senses = senses_cache[wid]
        rid = pick_recall(i)
        rw = id2word[rid] if rid else None
        cap = max(i, 300)
        multi = len(senses) >= 2
        sense_lines = "\n".join(f"  义项{k+1}（{p or '?'}）: {t[:44]}" for k, (_, _, p, t) in enumerate(senses))
        prompt = f"""为背单词 App 的单词 "{w}" 写 3 条英语例句。该词义项如下：
{sense_lines}
要求（逐条严格遵守）：
A: 基础句，≤10 个单词，简单句，适合初学者跟读{f"，必须包含复习词 \"{rw}\"" if rw else ""}
B: 进阶句，≤16 个单词，必须包含一个从句（when/because/that/which/who 等）
C: 挑战句，≤20 个单词，包含复合结构（从句/非谓语/介词短语组合）
{"多义词要求：A 演示义项1，B 演示义项2，C 演示义项3（无义项3则回到义项1的另一语境）" if multi else "三条都从义项1的不同语境演示"}
其他约束：
- 除目标词和指定复习词外，只用英语最常见的高频简单词（约前 {cap} 词范围）
- 必须使用英语母语者日常真实会说的固定搭配和常用句型，严禁生造词组、中式英语或生硬拼凑；句子自然、地道、有意义
- 输出恰好三行，格式严格为：
A: <英文句子> || <中文翻译>
B: <英文句子> || <中文翻译>
C: <英文句子> || <中文翻译>"""
        if args.dry_run:
            print(f"#{i} {w} 召回[{rw or '-'}]\n{prompt}\n{'-'*40}")
            return

        def validate(text, tier):
            ts = toks(text)
            if not (3 <= len(ts) <= TIER_LEN[tier]):
                return f"档长{len(ts)}>上限{TIER_LEN[tier]}"
            cap_t = cap if tier == 1 else cap + 500  # 进阶/挑战档放宽近前方词
            hit_t = hit_r = False
            for t in ts:
                tw = word2id.get(vmap.get(t, t))
                if tw is None:
                    return f"词库外:{t}"
                if pos_of[tw] > cap_t and tw != wid:
                    return f"超范围:{t}"
                hit_t |= tw == wid
                hit_r |= (rid is not None and tw == rid)
            if not hit_t:
                return "缺目标词"
            if tier == 1 and rid and not hit_r:
                return "缺召回词"
            return None

        made_here = 0
        err = None
        for _ in range(3):
            try:
                out = call_llm(prompt + (f"\n\n上次未通过校验：{err}。请只修正问题行。" if err else ""))
            except Exception as e:
                err = f"API错误:{e}"
                time.sleep(2)
                continue
            tiers = {}
            for line in out.splitlines():
                m = re.match(r"^([ABC])[::.]\s*(.+)$", line.strip())
                if not m:
                    continue
                tier = "ABC".index(m.group(1)) + 1
                body, _, zh = m.group(2).partition("||")
                text = body.strip().strip('"')
                e = validate(text, tier)
                if e:
                    err = f"{m.group(1)}行:{e}"
                else:
                    tiers[tier] = (text, zh.strip())
            if tiers:
                with db_lock:
                    have = {r[0] for r in cur.execute(
                        "SELECT tier FROM sentence WHERE targetWordId=? AND genMethod='llm-tier-v1'", (wid,))}
                    for tier, (text, zh) in tiers.items():
                        if tier in have:
                            continue
                        sid = senses[min(tier - 1, len(senses) - 1)][0] if multi else senses[0][0]
                        cur.execute("""INSERT INTO sentence(text, translation, wordIds, senseId, targetWordId, recallIds, genMethod, flag, tier)
                                       VALUES(?,?,?,?,?,?,?,?,?)""",
                                    (text, zh, json.dumps([wid]), sid, wid,
                                     json.dumps([rid] if (rid and tier == 1) else []),
                                     "llm-tier-v1", "cold_start" if i <= 300 else None, tier))
                        made_here += 1
                    conn.commit()
            if made_here or tiers:
                break
        with counter_lock:
            stats["made" if made_here else "failed"] += 1
            done = stats["made"] + stats["failed"]
            if done % 50 == 0 or made_here:
                print(f"[{done}/{len(tasks)}] {'✓' if made_here else '✗'} #{i} {w} ({made_here}档) {err or ''}", flush=True)

    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        list(ex.map(gen_one, tasks))

    print(f"\n完成: 生成 {stats['made']}，失败 {stats['failed']}，跳过 {stats['skipped']}，LLM 调用 {stats['calls']} 次")


if __name__ == "__main__":
    main()
