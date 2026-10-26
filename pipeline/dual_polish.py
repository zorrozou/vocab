# -*- coding: utf-8 -*-
"""双模型例句复核（可断点续跑）

主模型初审全部可见例句；次模型只复核初审 ≤3 分的候选。
两模型都给低分才处理：Tatoeba 隐藏，LLM 句由主模型重写、次模型验收；
重写仍不合格则隐藏，绝不留着"结构合法但不像人话"的句子。

环境变量：
  MAIN_LLM_BASE_URL / MAIN_LLM_API_KEY / MAIN_LLM_MODEL
  SECOND_LLM_BASE_URL / SECOND_LLM_API_KEY / SECOND_LLM_MODEL

用法：python3 dual_polish.py --start 1 --end 903 --workers 8
"""
import argparse, json, os, re, sqlite3, sys, threading, time, urllib.request, urllib.parse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sentence_batch import load, toks

ROOT = Path(__file__).resolve().parent
DB = ROOT / "data" / "lexicon_v0.1.sqlite"
TIER_LEN = {1: 16, 2: 18, 3: 22}

MAIN = (os.environ.get("MAIN_LLM_BASE_URL", "").rstrip("/"),
        os.environ.get("MAIN_LLM_API_KEY", ""), os.environ.get("MAIN_LLM_MODEL", ""))
SECOND = (os.environ.get("SECOND_LLM_BASE_URL", "").rstrip("/"),
          os.environ.get("SECOND_LLM_API_KEY", ""), os.environ.get("SECOND_LLM_MODEL", ""))

db_lock = threading.Lock()
stat_lock = threading.Lock()
stats = {"words": 0, "reviewed": 0, "candidates": 0, "rewritten": 0,
         "hidden": 0, "kept": 0, "failed": 0}


def call_llm(cfg, prompt, temperature=0.2, max_tokens=700):
    base, key, model = cfg
    req = urllib.request.Request(
        f"{base}/chat/completions",
        data=json.dumps({"model": model, "messages": [{"role": "user", "content": prompt}],
                         "thinking": {"type": "disabled"}, "temperature": temperature,
                         "max_tokens": max_tokens}).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    for a in range(3):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return json.loads(r.read())["choices"][0]["message"]["content"].strip()
        except Exception:
            if a == 2:
                raise
            time.sleep(2 + a * 2)


def review_prompt(w, sense, rows, indices=None):
    indices = indices or list(range(1, len(rows) + 1))
    lines = "\n".join(f"{new_i}: {rows[old_i - 1][1]}" for new_i, old_i in enumerate(indices, 1))
    return (f"你是英语教材评审。单词 \"{w}\"（词义：{sense[:60]}）有以下例句。\n"
            f"逐句按 1~5 分评价：5=语法正确、搭配地道、像真实生活用语；"
            f"3=能理解但生硬/不常见；1=语法错误、词义误用或牵强拼凑。\n"
            f"重点检查目标词在句中的词性和词义是否正确，不要只看句子是否通顺。\n"
            f"只输出每行 \"编号: 分数\"，不要解释。\n{lines}")


def parse_scores(out, n):
    scores = {}
    for line in out.splitlines():
        m = re.match(r"^(\d+)\s*[::.]\s*(\d)", line.strip())
        if m:
            scores[int(m.group(1))] = int(m.group(2))
    return [scores.get(i, 4) for i in range(1, n + 1)]   # 解析缺失按保留，防止误杀


def single_score(cfg, text, w, sense):
    out = call_llm(cfg, review_prompt(w, sense, [(0, text, 0, "")]))
    return parse_scores(out, 1)[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--start", type=int, required=True)
    ap.add_argument("--end", type=int, required=True)
    ap.add_argument("--workers", type=int, default=8)
    args = ap.parse_args()
    if not all(MAIN) or not all(SECOND):
        raise SystemExit("MAIN_LLM_* 与 SECOND_LLM_* 环境变量必须全部配置")
    conn, seq, pos_of, id2word, word2id, pos_tag, senses_core, vmap = load()
    cur = conn.cursor()
    cur.execute("CREATE TABLE IF NOT EXISTS dual_polish_state(wordId INTEGER PRIMARY KEY, doneAt TEXT)")
    conn.commit()
    tasks = []
    for i in range(args.start, min(args.end, len(seq)) + 1):
        wid = seq[i - 1][0]
        if cur.execute("SELECT 1 FROM dual_polish_state WHERE wordId=?", (wid,)).fetchone():
            continue
        rows = cur.execute(
            """SELECT id, text, tier, genMethod FROM sentence
               WHERE targetWordId=? AND (genMethod LIKE 'llm-%' OR genMethod='tatoeba')
                 AND COALESCE(flag,'') != 'reported' ORDER BY tier""", (wid,)).fetchall()
        if rows:
            tasks.append((i, wid, seq[i - 1][1], rows))
    print(f"双模型复核任务: {len(tasks)} 词（{sum(len(t[3]) for t in tasks)} 句）· {args.workers} 并发", flush=True)

    def validate(text, tier, wid, w):
        ts = toks(text)
        if not (3 <= len(ts) <= TIER_LEN.get(tier, 22)):
            return False
        hit = False
        oov = 0
        for t in ts:
            lemma = vmap.get(t, t)
            if t == w or lemma == w:
                hit = True
            if lemma not in word2id and t not in word2id:
                if (t.endswith("ed") and t[:-2] == w) or (t.endswith("ing") and t[:-3] == w):
                    hit = True
                    continue
                oov += 1
                if oov > 1:
                    return False
        return hit

    def hide(sid):
        with db_lock:
            cur.execute("UPDATE sentence SET flag='reported' WHERE id=?", (sid,))
            conn.commit()
        with stat_lock:
            stats["hidden"] += 1

    def process(task):
        i, wid, w, rows = task
        sense = senses_core.get(wid) or ""
        try:
            first = parse_scores(call_llm(MAIN, review_prompt(w, sense, rows)), len(rows))
            with stat_lock:
                stats["reviewed"] += len(rows)
            cand = [k + 1 for k, sc in enumerate(first) if sc <= 3]
            if not cand:
                with stat_lock:
                    stats["kept"] += len(rows)
            else:
                with stat_lock:
                    stats["candidates"] += len(cand)
                second = parse_scores(call_llm(MAIN if not SECOND else SECOND, review_prompt(w, sense, rows, cand)), len(cand))
                for ci, sc in zip(cand, second):
                    sid, old, tier, method = rows[ci - 1]
                    if sc >= 4:
                        with stat_lock:
                            stats["kept"] += 1
                        continue
                    if method == "tatoeba":
                        hide(sid)
                        continue
                    accepted = False
                    for _ in range(2):
                        prompt = (f"为背单词 App 的单词 \"{w}\"（词义：{sense[:60]}）重写一条英语例句。"
                                  f"目标词必须使用正确词性和词义；真实日常/学习/工作场景，"
                                  f"母语者自然会说，严禁生造搭配或中式英语；"
                                  f"3~{TIER_LEN.get(tier, 22)} 词，其余词用常见高频词。"
                                  f"输出：英文句子 || 中文翻译，一行，不要解释。")
                        out = call_llm(MAIN, prompt, temperature=0.7, max_tokens=300)
                        text, _, zh = out.partition("||")
                        text = text.strip().strip('"')
                        if not validate(text, tier, wid, w):
                            continue
                        if single_score(SECOND, text, w, sense) >= 4:
                            with db_lock:
                                cur.execute("UPDATE sentence SET text=?, translation=?, flag='dual-polished' WHERE id=?",
                                            (text, zh.strip(), sid))
                                conn.commit()
                            with stat_lock:
                                stats["rewritten"] += 1
                            # 预热新音频；失败不阻塞语料修复
                            try:
                                urllib.request.urlopen("http://127.0.0.1:8000/api/v1/tts?text=" +
                                                       urllib.parse.quote(text), timeout=30).read()
                            except Exception:
                                pass
                            accepted = True
                            break
                    if not accepted:
                        hide(sid)
            with db_lock:
                cur.execute("INSERT OR REPLACE INTO dual_polish_state VALUES(?, datetime('now'))", (wid,))
                conn.commit()
            with stat_lock:
                stats["words"] += 1
                if stats["words"] % 50 == 0:
                    print(stats, flush=True)
        except Exception as e:
            with stat_lock:
                stats["failed"] += 1
            print(f"[失败] {i} {w}: {e}", flush=True)

    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        list(ex.map(process, tasks))
    print("双模型复核完成:", stats, flush=True)


if __name__ == "__main__":
    main()
