# -*- coding: utf-8 -*-
"""LLM 例句量产工厂（OpenAI 兼容接口：GLM / DeepSeek / Moonshot / Qwen …）
从环境变量读凭证，绝不打印：
  LLM_API_KEY   必填，API token
  LLM_BASE_URL  默认 https://open.bigmodel.cn/api/paas/v4（GLM）
  LLM_MODEL     默认 glm-4.6（按实际模型名设置，如 glm-5.2 / deepseek-chat …）
用法:
  python llm_sentence_factory.py --start 1 --end 40          # 按学习序列位置量产
  python llm_sentence_factory.py --dry-run --start 1 --end 5 # 只打印 prompt 不调用
流程: 出工单(新词+召回词+约束) → 调 API → 校验器全检 → 失败带原因重试(≤3) → 入库 llm-api-v1
"""
import argparse, json, os, re, sqlite3, sys, time, urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sentence_batch import load, toks  # 复用词库加载与分词

ROOT = Path(__file__).resolve().parent
DB = ROOT / "data" / "lexicon_v0.1.sqlite"
NEW_PER_DAY = 10
MAX_LEN = 12
MAX_RETRY = 3

BASE = os.environ.get("LLM_BASE_URL", "https://open.bigmodel.cn/api/paas/v4").rstrip("/")
KEY = os.environ.get("LLM_API_KEY", "")
MODEL = os.environ.get("LLM_MODEL", "glm-4.6")


def call_llm(messages, temperature=0.7):
    req = urllib.request.Request(
        f"{BASE}/chat/completions",
        data=json.dumps({"model": MODEL, "messages": messages,
                         "thinking": {"type": "disabled"},
                         "temperature": temperature, "max_tokens": 200}).encode(),
        headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())["choices"][0]["message"]["content"].strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--start", type=int, required=True)
    ap.add_argument("--end", type=int, required=True)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--cold", action="store_true",
                    help="冷启动模式：词汇约束放宽为前 300 高频词（用于位置 1~300）")
    args = ap.parse_args()
    if not args.dry_run and not KEY:
        sys.exit("请设置 LLM_API_KEY 环境变量（不要写在代码或聊天记录里）")

    conn, seq, pos_of, id2word, word2id, pos_tag, senses, vmap = load()
    cur = conn.cursor()
    made = skipped = failed = 0

    for i in range(args.start, args.end + 1):
        if i < 1 or i > len(seq):
            break
        wid, w, lv, frq = seq[i - 1]
        done = cur.execute(
            "SELECT 1 FROM sentence WHERE targetWordId=? AND genMethod LIKE 'llm-%'", (wid,)).fetchone()
        if done:
            skipped += 1
            continue
        # 召回词：遗忘偏移窗口内优先实义词
        recall = None
        for days, tol in ((1, 5), (7, 10)):
            lo, hi = i - days * NEW_PER_DAY - tol, i - days * NEW_PER_DAY + tol
            pool = [seq[j - 1][0] for j in range(max(1, lo), min(i - 1, hi) + 1)]
            pool.sort(key=lambda r: 0 if (pos_tag.get(r) or "").startswith(("n", "v", "a")) else 1)
            if pool:
                recall = pool[0]
                break
        rw = id2word[recall] if recall else None
        vocab_cap = 300 if args.cold else i  # 冷启动区放宽到前 300 词

        prompt = f"""为背单词 App 写一条英语例句，要求：
1. 必须包含目标词 "{w}"（词义：{(senses.get(wid) or '')[:50]}）
2. {"必须同时包含复习词 " + repr(rw) + "（词义：" + (senses.get(recall) or '')[:40] + "）" if rw else "目标词单独成句"}
3. 句长 3~12 个单词，句子自然、地道、简单
4. 除了目标词，其他用词必须是英语中最常见的前 {vocab_cap} 个高频词范围内的简单词
5. 只输出英文例句本身，一行，不要任何解释"""
        if args.dry_run:
            print(f"#{i} {w} 召回[{rw or '-'}]\n{prompt}\n")
            continue

        text, err = None, None
        for attempt in range(MAX_RETRY):
            msgs = [{"role": "user", "content": prompt + (f"\n\n上次失败原因：{err}，请修正。" if err else "")}]
            try:
                cand = call_llm(msgs).strip().strip('"').splitlines()[0].strip()
            except Exception as e:
                err = f"API错误:{e}"
                time.sleep(2)
                continue
            # ---- 校验器（与 sentence_batch 同规则）----
            ts = toks(cand)
            ids, err = [], None
            if not (3 <= len(ts) <= MAX_LEN):
                err = f"句长{len(ts)}超界"
            hit_new = hit_recall = False
            for t in ts:
                tw = word2id.get(vmap.get(t, t))
                if tw is None:
                    err = err or f"词库外词汇:{t}"
                else:
                    if pos_of[tw] > vocab_cap:
                        err = err or f"用了未学词:{t}"
                    ids.append(tw)
                    hit_new |= tw == wid
                    hit_recall |= (recall is not None and tw == recall)
            if not hit_new:
                err = err or "未出现目标词"
            if recall and not hit_recall:
                err = err or "未出现召回词"
            if not err:
                text, ok_ids = cand, ids
                break
        if text is None:
            print(f"✗ #{i} {w}: {err}")
            failed += 1
            continue
        sense_id = cur.execute(
            "SELECT id FROM sense WHERE wordId=? AND role='core'", (wid,)).fetchone()[0]
        cur.execute("DELETE FROM sentence WHERE targetWordId=? AND genMethod='template-v1'", (wid,))
        cur.execute("""INSERT INTO sentence(text, translation, wordIds, senseId, targetWordId, recallIds, genMethod, flag)
                       VALUES(?,?,?,?,?,?,?,?)""",
                    (text, None, json.dumps(sorted(set(ok_ids))), sense_id, wid,
                     json.dumps([recall] if recall else []), "llm-api-v1", "cold_start" if args.cold else None))
        conn.commit()
        print(f"✓ #{i} {w}: {text}")
        made += 1
        time.sleep(0.4)

    n = cur.execute("SELECT COUNT(*) FROM sentence WHERE genMethod LIKE 'llm-%'").fetchone()[0]
    print(f"\n本批: 入库 {made}，跳过 {skipped}，失败 {failed}；sentence 表 LLM 句累计 {n}")
    conn.close()


if __name__ == "__main__":
    main()
