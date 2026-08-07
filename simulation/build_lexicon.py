# -*- coding: utf-8 -*-
"""词库构建管线 v0.1（原型验证）
数据源：Google ngram 词频表（原型用；生产环境替换为 ECDICT frq/考纲标签）
产出：data/lexicon.sqlite（lexicon_entry + sentence 两表）+ 校验报告 + 例句召回查询演示
"""
import json, random, re, sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DB = ROOT / "data" / "lexicon.sqlite"
DEMO_SLICE = 3000  # L1: 1-1000, L2: 1001-3000

# ---- 冷启动预编例句（目标词, 例句, 中文） ----
SENTENCES = [
    ("time",   "We had a good time at the party.", "我们在聚会上玩得很开心。"),
    ("time",   "What time is it now?", "现在几点了？"),
    ("people", "Many people like to read books.", "许多人喜欢读书。"),
    ("way",    "This is the best way to learn.", "这是最好的学习方法。"),
    ("day",    "I work hard every day.", "我每天都很努力。"),
    ("man",    "The man in the blue shirt is my teacher.", "穿蓝衬衫的那个人是我的老师。"),
    ("thing",  "The first thing to do is to make a plan.", "第一件事是制定一个计划。"),
    ("world",  "The world is a big place.", "世界很大。"),
    ("life",   "Life is short, so use your time well.", "生命短暂，所以好好利用你的时间。"),
    ("year",   "We go to the mountains every year.", "我们每年都去山里。"),
    ("school", "My school is near my house.", "我的学校在我家附近。"),
    ("water",  "He drinks a lot of water in the morning.", "他早上喝很多水。"),
]

def tokens(text):
    return [t.strip("'") for t in re.findall(r"[a-zA-Z']+", text.lower()) if t.strip("'")]

def main():
    words = [w.strip() for w in (ROOT / "data" / "google-10000.txt").read_text().splitlines() if w.strip()]
    slice_words = words[:DEMO_SLICE]

    if DB.exists():
        DB.unlink()
    conn = sqlite3.connect(DB)
    cur = conn.cursor()
    cur.execute("""CREATE TABLE lexicon_entry(
        id INTEGER PRIMARY KEY, word TEXT UNIQUE NOT NULL,
        frqRank INTEGER NOT NULL, level INTEGER NOT NULL, source TEXT NOT NULL)""")
    cur.execute("""CREATE TABLE sentence(
        id INTEGER PRIMARY KEY, text TEXT NOT NULL, translation TEXT,
        wordIds TEXT NOT NULL, level INTEGER, targetWordId INTEGER NOT NULL)""")
    cur.execute("CREATE INDEX idx_entry_rank ON lexicon_entry(frqRank)")

    entries = []
    for rank, w in enumerate(slice_words, start=1):
        level = 1 if rank <= 1000 else 2
        entries.append((w, rank, level, "google-ngram-demo"))
    cur.executemany("INSERT INTO lexicon_entry(word, frqRank, level, source) VALUES(?,?,?,?)", entries)
    conn.commit()

    word2id = {w: i for i, w in cur.execute("SELECT id, word FROM lexicon_entry")}
    rankOf = {w: r for _, w, r, _, _ in [(e[0], e[0], e[1], 0, 0) for e in entries]}
    rankOf = {w: r for (w, r, _, _) in entries}

    extras = set()
    for target, text, zh in SENTENCES:
        ids = []
        for t in tokens(text):
            if t in word2id:
                ids.append(word2id[t])
            else:
                extras.add(t)
        if target not in word2id:
            print(f"!! 目标词 {target} 不在切片中，跳过: {text}")
            continue
        cur.execute("INSERT INTO sentence(text, translation, wordIds, level, targetWordId) VALUES(?,?,?,?,?)",
                    (text, zh, json.dumps(sorted(set(ids))), 1, word2id[target]))
    conn.commit()

    # ---------- 校验报告 ----------
    print("=== 词库构建校验 ===")
    for lv in (1, 2):
        n = cur.execute("SELECT COUNT(*) FROM lexicon_entry WHERE level=?", (lv,)).fetchone()[0]
        print(f"L{lv} 词条数: {n}")
    ns = cur.execute("SELECT COUNT(*) FROM sentence").fetchone()[0]
    print(f"例句数: {ns}（演示切片；生产要求每词 ≥2 句）")
    if extras:
        print(f"例句中未落入切片的词（视为专名/词形，生产环境需 lemma 归并）: {sorted(extras)}")

    covered = cur.execute("SELECT COUNT(DISTINCT targetWordId) FROM sentence").fetchone()[0]
    print(f"已覆盖目标词: {covered} / 1000 (L1)")

    # ---------- 例句召回查询演示 ----------
    print("\n=== 例句召回演示（学习位置：已学前 2000 词，学新词时选句） ===")
    learned = {i for i, r in cur.execute("SELECT id, frqRank FROM lexicon_entry WHERE frqRank<=2000")}
    rankById = {i: r for i, r in cur.execute("SELECT id, frqRank FROM lexicon_entry")}

    def risk(wid):  # 演示占位：生产环境由 FSRS 的 R 给出
        r = rankById[wid]
        return 0.1 if r <= 500 else (0.4 if r <= 1500 else 0.8)

    rng = random.Random(42)
    for target in ("water", "life", "school"):
        tid = word2id[target]
        rows = cur.execute("SELECT text, wordIds FROM sentence WHERE targetWordId=?", (tid,)).fetchall()
        passed = []
        for text, wids in rows:
            wids = json.loads(wids)
            if all(w in learned for w in wids) and len(tokens(text)) <= 12:
                score = sum(risk(w) for w in wids if w != tid)
                passed.append((text, round(score, 2)))
        if not passed:
            print(f"  {target}: 无满足硬过滤的例句")
            continue
        total = sum(s for _, s in passed)
        pick = rng.choices(passed, weights=[s or 0.01 for _, s in passed])[0]
        for text, s in passed:
            mark = " <-- 选中" if (text, s) == pick else ""
            print(f"  [{target}] score={s:.2f}  {text}{mark}")

    conn.close()
    print(f"\n数据库: {DB}")

if __name__ == "__main__":
    main()
