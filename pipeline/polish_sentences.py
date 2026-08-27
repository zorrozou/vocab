# -*- coding: utf-8 -*-
"""例句质量打磨批：LLM 评审 + 低分重写（进程池）
对每词每档例句打分 1-5（语法正确/自然地道/真实场景），≤3 分重写。
重写不再强制织入召回词（按用户定稿：有一定概率出现即可）。
产出带中文翻译；校验器过检后原地更新。
用法: run-pipeline ../venv/bin/python -u polish_sentences.py --start 1 --end 903 --workers 8
"""
import argparse, json, os, re, sqlite3, sys, threading, time, urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sentence_batch import load, toks

ROOT = Path(__file__).resolve().parent
DB = ROOT / "data" / "lexicon_v0.1.sqlite"
TIER_LEN = {1: 16, 2: 18, 3: 22}   # 打磨后允许略长（真实场景优先）
BASE = os.environ.get("LLM_BASE_URL", "").rstrip("/")
KEY = os.environ.get("LLM_API_KEY", "")
MODEL = os.environ.get("LLM_MODEL", "glm-4.6")

db_lock = threading.Lock()
counter = threading.Lock()
stats = {"words": 0, "reviewed": 0, "rewritten": 0, "kept": 0, "failed": 0}


def call_llm(prompt, max_tokens=400):
    req = urllib.request.Request(
        f"{BASE}/chat/completions",
        data=json.dumps({"model": MODEL, "messages": [{"role": "user", "content": prompt}],
                         "thinking": {"type": "disabled"}, "temperature": 0.7,
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--start", type=int, required=True)
    ap.add_argument("--end", type=int, required=True)
    ap.add_argument("--workers", type=int, default=8)
    args = ap.parse_args()
    conn, seq, pos_of, id2word, word2id, pos_tag, senses_core, vmap = load()
    cur = conn.cursor()

    tasks = []
    for i in range(args.start, min(args.end, len(seq)) + 1):
        wid = seq[i - 1][0]
        rows = cur.execute(
            """SELECT id, text, tier FROM sentence
               WHERE targetWordId=? AND genMethod LIKE 'llm-%'
                 AND NOT EXISTS (SELECT 1 FROM sentence t
                                 WHERE t.targetWordId=sentence.targetWordId
                                   AND t.tier=sentence.tier AND t.genMethod='tatoeba')
               ORDER BY tier""",
            (wid,)).fetchall()
        if rows:
            tasks.append((i, wid, seq[i - 1][1], rows))
    print(f"打磨任务: {len(tasks)} 词（{sum(len(t[3]) for t in tasks)} 句）· {args.workers} 并发", flush=True)

    def validate(text, tier, wid):
        ts = toks(text)
        if not (3 <= len(ts) <= TIER_LEN.get(tier, 22)):
            return f"长度{len(ts)}"
        oov = 0
        hit = False
        for t in ts:
            tw = word2id.get(vmap.get(t, t))
            if tw is None:
                oov += 1
                if oov > 1:
                    return f"词库外:{t}"
                continue
            hit |= (tw == wid or t == id2word[wid])
        if not hit:
            return "缺目标词"
        return None

    def polish(task):
        i, wid, w, rows = task
        lines = "\n".join(f"{k+1}: {t}" for k, (_, t, _) in enumerate(rows))
        prompt = f"""你是英语教材编辑。以下是单词 "{w}"（词义：{(senses_core.get(wid) or '')[:50]}）的 {len(rows)} 条例句：
{lines}

逐句评审并输出，每行一条，格式严格为：
<序号>: <分数1-5> || <重写句> || <中文翻译>

规则：
- 分数：5=语法正确且自然地道、像真实生活中会说的话；1=语法错误或生硬拼凑
- 重写句：仅当分数≤3时才写，否则写 -；重写句必须仍包含 "{w}"，10~{TIER_LEN.get(rows[0][2], 22)} 词，真实日常场景，除目标词外用常见高频词
- 中文翻译：重写给重写句的翻译；不重写写 -
只输出这些行，不要其他解释。"""
        try:
            out = call_llm(prompt)
        except Exception:
            with counter:
                stats["failed"] += 1
            return
        rew = 0
        for line in out.splitlines():
            m = re.match(r"^(\d+)\s*[::.]\s*(\d)\s*\|\|\s*(.+?)\s*\|\|\s*(.+)$", line.strip())
            if not m:
                continue
            k, score, rewrite, zh = int(m.group(1)), int(m.group(2)), m.group(3), m.group(4)
            if k < 1 or k > len(rows):
                continue
            sid, old_text, tier = rows[k - 1]
            with counter:
                stats["reviewed"] += 1
            if score >= 4 or rewrite == "-":
                with counter:
                    stats["kept"] += 1
                continue
            rewrite = rewrite.strip().strip('"')
            err = validate(rewrite, tier, wid)
            if err:
                with counter:
                    stats["kept"] += 1
                continue
            with db_lock:
                cur.execute("UPDATE sentence SET text=?, translation=?, flag='polished' WHERE id=?",
                            (rewrite, "" if zh == "-" else zh.strip(), sid))
                conn.commit()
            rew += 1
            with counter:
                stats["rewritten"] += 1
        with counter:
            stats["words"] += 1
            if stats["words"] % 100 == 0:
                print(f"[{stats['words']}/{len(tasks)}] 评审 {stats['reviewed']} 重写 {stats['rewritten']}", flush=True)

    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        list(ex.map(polish, tasks))
    print(f"\n打磨完成: {stats['words']} 词 / 评审 {stats['reviewed']} 句 / 重写 {stats['rewritten']} 句 / 保留 {stats['kept']} / API失败 {stats['failed']}", flush=True)


if __name__ == "__main__":
    main()
