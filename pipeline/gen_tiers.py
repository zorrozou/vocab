# -*- coding: utf-8 -*-
"""三档例句生成管线 v2（LLM 一次调用产出 3 档，校验器逐档把关）
档位：A 基础 ≤10词(跟读) / B 进阶 ≤16词(含一个从句) / C 挑战 ≤20词(复合结构)
多义词：A/B/C 依次对应核心义项、扩展义项1、扩展义项2（不足则回落同义项）
硬约束（校验器）：长度按档、词汇位置 ≤ 学习位、A 档必含遗忘窗口召回词、目标词必现
用法: python gen_tiers.py --start 31 --end 903 [--dry-run]
"""
import argparse, json, os, re, sqlite3, sys, time, urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sentence_batch import load, toks

ROOT = Path(__file__).resolve().parent
DB = ROOT / "data" / "lexicon_v0.1.sqlite"
NEW_PER_DAY = 10
TIER_LEN = {1: 10, 2: 16, 3: 20}
MAX_RETRY = 3

BASE = os.environ.get("LLM_BASE_URL", "").rstrip("/")
KEY = os.environ.get("LLM_API_KEY", "")
MODEL = os.environ.get("LLM_MODEL", "glm-4.6")


def call_llm(prompt):
    req = urllib.request.Request(
        f"{BASE}/chat/completions",
        data=json.dumps({"model": MODEL, "messages": [{"role": "user", "content": prompt}],
                         "thinking": {"type": "disabled"}, "temperature": 0.8,
                         "max_tokens": 300}).encode(),
        headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())["choices"][0]["message"]["content"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--start", type=int, required=True)
    ap.add_argument("--end", type=int, required=True)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    conn, seq, pos_of, id2word, word2id, pos_tag, senses_core, vmap = load()
    cur = conn.cursor()

    def senses_of(wid):
        return cur.execute(
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

    def validate_tier(text, tier, wid, rid, cap):
        ts = toks(text)
        if not (3 <= len(ts) <= TIER_LEN[tier]):
            return f"档长{len(ts)}>上限{TIER_LEN[tier]}"
        hit_t = hit_r = False
        for t in ts:
            tw = word2id.get(vmap.get(t, t))
            if tw is None:
                return f"词库外:{t}"
            if pos_of[tw] > cap and tw != wid:
                return f"超范围:{t}"
            hit_t |= tw == wid
            hit_r |= (rid is not None and tw == rid)
        if not hit_t:
            return "缺目标词"
        if tier == 1 and rid and not hit_r:
            return "缺召回词"
        return None

    made = skipped = failed = 0
    for i in range(args.start, args.end + 1):
        if i < 1 or i > len(seq):
            break
        wid, w, lv, frq = seq[i - 1]
        have = {r[0] for r in cur.execute(
            "SELECT tier FROM sentence WHERE targetWordId=? AND genMethod='llm-tier-v1'", (wid,))}
        if len(have) >= 3:
            skipped += 1
            continue
        senses = senses_of(wid)
        rid = pick_recall(i)
        rw = id2word[rid] if rid else None
        cap = max(i, 300)
        multi = len(senses) >= 2
        sense_lines = "\n".join(f"  义项{k+1}（{p or '?'}）: {t[:44]}" for k, (_, _, p, t) in enumerate(senses))
        prompt = f"""为背单词 App 的单词 "{w}" 写 3 条英语例句。该词义项如下：
{sense_lines}
要求（逐条严格遵守）：
A: 基础句，≤10 个单词，简单句，适合初学者跟读{f"，必须包含复习词 \"{rw}\"（它对应义项可灵活处理）" if rw else ""}
B: 进阶句，≤16 个单词，必须包含一个从句（when/because/that/which/who 等）
C: 挑战句，≤20 个单词，包含复合结构（从句/非谓语/介词短语组合）
{"多义词要求：A 演示义项1，B 演示义项2，C 演示义项3（无义项3则回到义项1的另一语境）" if multi else "三条都从义项1的不同语境演示"}
其他约束：
- 除目标词和指定复习词外，只用英语最常见的高频简单词（约前 {cap} 词范围）
- 句子必须自然、地道、有意义，不要生硬拼凑
- 输出恰好三行，格式严格为：
A: <句子>
B: <句子>
C: <句子>"""
        if args.dry_run:
            print(f"#{i} {w} 召回[{rw or '-'}] 义项数{len(senses)}\n{prompt}\n{'-'*50}")
            continue

        tiers = {}
        err = None
        for _ in range(MAX_RETRY):
            try:
                out = call_llm(prompt + (f"\n\n上次未通过校验：{err}。请只修正有问题的行。" if err else ""))
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
                text = m.group(2).strip().strip('"')
                e = validate_tier(text, tier, wid, rid, cap)
                if e:
                    err = f"{m.group(1)}行:{e}"
                else:
                    tiers[tier] = text
            if len(tiers) == 3:
                break
        for tier, text in tiers.items():
            if tier in have:
                continue
            sid = senses[min(tier - 1, len(senses) - 1)][0] if multi else senses[0][0]
            cur.execute("""INSERT INTO sentence(text, translation, wordIds, senseId, targetWordId, recallIds, genMethod, flag, tier)
                           VALUES(?,?,?,?,?,?,?,?,?)""",
                        (text, None, json.dumps([wid]), sid, wid,
                         json.dumps([rid] if (rid and tier == 1) else []),
                         "llm-tier-v1", "cold_start" if i <= 300 else None, tier))
        conn.commit()
        if tiers:
            made += 1
            print(f"✓ #{i} {w} ({len(tiers)}/3 档)")
            for t in sorted(tiers):
                print(f"    {'ABC'[t-1]}: {tiers[t]}")
        else:
            failed += 1
            print(f"✗ #{i} {w}: {err}")
        time.sleep(0.4)

    print(f"\n本批: 生成 {made}，跳过 {skipped}，失败 {failed}")


if __name__ == "__main__":
    main()
