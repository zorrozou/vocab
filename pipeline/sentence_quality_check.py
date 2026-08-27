# -*- coding: utf-8 -*-
"""例句质量抽查：随机抽样静态句+个性化句，LLM 评审打分（语法/自然度/真实场景）"""
import json, os, random, re, sqlite3, time, urllib.request
from collections import Counter

BASE = os.environ.get("LLM_BASE_URL", "").rstrip("/")
KEY = os.environ.get("LLM_API_KEY", "")
MODEL = os.environ.get("LLM_MODEL", "glm-4.6")
N = 210
random.seed(7)


def call_llm(prompt):
    req = urllib.request.Request(
        f"{BASE}/chat/completions",
        data=json.dumps({"model": MODEL, "messages": [{"role": "user", "content": prompt}],
                         "thinking": {"type": "disabled"}, "temperature": 0.2,
                         "max_tokens": 500}).encode(),
        headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=90) as r:
        return json.loads(r.read())["choices"][0]["message"]["content"]


conn = sqlite3.connect("/home/ubuntu/vocab-api/data/lexicon_v0.1.sqlite", timeout=30)
rows = conn.execute(
    """SELECT s.text, s.genMethod, e.word FROM sentence s JOIN lexicon_entry e ON e.id=s.targetWordId
       WHERE s.genMethod='tatoeba' OR s.genMethod LIKE 'llm-%' ORDER BY RANDOM() LIMIT ?""", (N,)).fetchall()
conn.close()

pconn = sqlite3.connect("/home/ubuntu/vocab-api/data/personal.db", timeout=30)
prows = pconn.execute("SELECT text, target FROM sentences ORDER BY created DESC LIMIT 40").fetchall()
pconn.close()

samples = [(t, "tatoeba" if g == "tatoeba" else "llm", w) for t, g, w in rows] + \
          [(t, "personal", w) for t, w in prows]

scores = Counter()
low = []
for off in range(0, len(samples), 15):
    batch = samples[off:off + 15]
    prompt = "你是英语教材评审。对下列英语例句逐句打分（1=语法错误或生硬拼凑，3=语法正确但略生硬，5=语法正确且自然地道、像真实生活用语）。只输出编号和分数，格式：1. 5\n" + \
             "\n".join(f"{k+1}. {t}" for k, (t, _, _) in enumerate(batch))
    try:
        out = call_llm(prompt)
    except Exception as e:
        print(f"批次{off} API错误: {e}")
        continue
    for line in out.splitlines():
        m = re.match(r"^(\d+)[.、:：]\s*(\d)", line.strip())
        if not m:
            continue
        k, sc = int(m.group(1)), int(m.group(2))
        if 1 <= k <= len(batch):
            t, src, w = batch[k - 1]
            scores[sc] += 1
            if sc <= 2:
                low.append((sc, src, w, t))
    time.sleep(0.4)

tot = sum(scores.values())
print(f"\n评审 {tot} 句 | 分布: " + " ".join(f"{s}分:{scores[s]}" for s in sorted(scores, reverse=True)))
print(f"低分(≤2): {sum(v for s, v in scores.items() if s <= 2)} 句 = {sum(v for s, v in scores.items() if s <= 2)/max(1,tot)*100:.1f}%")
print(f"高分(≥4): {sum(v for s, v in scores.items() if s >= 4)} 句 = {sum(v for s, v in scores.items() if s >= 4)/max(1,tot)*100:.1f}%")
src_stat = Counter((src, sc >= 4) for _, src, _, _ in low)
print("\n低分样例（前 12）:")
for sc, src, w, t in low[:12]:
    print(f"  [{sc}分|{src}] ({w}) {t}")
