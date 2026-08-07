# -*- coding: utf-8 -*-
"""存量例句中文翻译回填：批量调 LLM，每批 15 句，逐条对齐更新"""
import json, os, re, sqlite3, sys, time, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DB = ROOT / "data" / "lexicon_v0.1.sqlite"
BASE = os.environ.get("LLM_BASE_URL", "").rstrip("/")
KEY = os.environ.get("LLM_API_KEY", "")
MODEL = os.environ.get("LLM_MODEL", "glm-4.6")
BATCH = 15


def call_llm(prompt):
    req = urllib.request.Request(
        f"{BASE}/chat/completions",
        data=json.dumps({"model": MODEL, "messages": [{"role": "user", "content": prompt}],
                         "thinking": {"type": "disabled"}, "temperature": 0.3,
                         "max_tokens": 800}).encode(),
        headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=90) as r:
        return json.loads(r.read())["choices"][0]["message"]["content"]


def main():
    conn = sqlite3.connect(DB, timeout=30)
    cur = conn.cursor()
    rows = cur.execute(
        "SELECT id, text FROM sentence WHERE (translation IS NULL OR translation='') AND genMethod LIKE 'llm-%' ORDER BY id").fetchall()
    print(f"待翻译: {len(rows)} 句")
    done = fail = 0
    for off in range(0, len(rows), BATCH):
        batch = rows[off:off + BATCH]
        prompt = "把下列英语例句逐条翻译成中文（简洁自然）。输出严格为编号行，与输入一一对应：\n" + \
                 "\n".join(f"{k+1}. {t}" for k, (_, t) in enumerate(batch)) + \
                 "\n格式：1. 中文翻译"
        try:
            out = call_llm(prompt)
        except Exception as e:
            print(f"批次 {off} API错误: {e}")
            time.sleep(3)
            continue
        lines = {}
        for line in out.splitlines():
            m = re.match(r"^(\d+)[.、:：]\s*(.+)$", line.strip())
            if m:
                lines[int(m.group(1))] = m.group(2).strip()
        for k, (sid, t) in enumerate(batch, 1):
            zh = lines.get(k, "").strip()
            if zh:
                cur.execute("UPDATE sentence SET translation=? WHERE id=?", (zh, sid))
                done += 1
            else:
                fail += 1
        conn.commit()
        print(f"批次 {off//BATCH + 1}: 累计 {done} 句")
        time.sleep(0.5)
    print(f"完成: 翻译 {done}，失败 {fail}")
    conn.close()


if __name__ == "__main__":
    main()
