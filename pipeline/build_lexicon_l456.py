# -*- coding: utf-8 -*-
"""L4~L6 词包构建（追加进 lexicon_v0.1.sqlite）
L4: cet6 增量（不在库）按 frq 取前 1500
L5: ielts/toefl 增量（不在库）按 frq 取前 3000
L6: frq 8000~12000 且不在库，全部收录
"""
import csv, sqlite3, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_lexicon_ecdict import norm_word, split_senses

ROOT = Path(__file__).resolve().parent
CSV_PATH = ROOT / "data" / "ecdict.csv"
DB_PATH = ROOT / "data" / "lexicon_v0.1.sqlite"

CAPS = {"cet6": 1500, "ieltstoefl": 3000, "l6": 10 ** 9}


def main():
    conn = sqlite3.connect(DB_PATH, timeout=30)
    cur = conn.cursor()
    existing = {r[0] for r in cur.execute("SELECT word FROM lexicon_entry")}
    max_id = cur.execute("SELECT MAX(id) FROM lexicon_entry").fetchone()[0]
    print(f"现有词条: {len(existing)}")

    pools = {"cet6": [], "ieltstoefl": [], "l6": []}
    seen = set()
    with open(CSV_PATH, encoding="utf-8") as f:
        for row in csv.DictReader(f):
            w = norm_word(row["word"])
            if not w or " " in w or w in existing or w in seen:
                continue
            frq = int(row["frq"]) if row["frq"].isdigit() else None
            bnc = int(row["bnc"]) if row["bnc"].isdigit() else None
            tags = (row["tag"] or "").split()
            senses = split_senses(row["translation"])
            if not senses:
                continue
            rec = dict(word=w, phonetic=row["phonetic"].strip(), pos=row["pos"].strip(),
                       collins=row["collins"], oxford=row["oxford"], tags=" ".join(tags),
                       bnc=bnc, frq=frq, senses=senses, full=row["translation"].strip(),
                       exchange=row["exchange"].strip())
            if "cet6" in tags and frq:
                pools["cet6"].append(rec)
            elif ("ielts" in tags or "toefl" in tags) and frq:
                pools["ieltstoefl"].append(rec)
            elif frq and 8000 <= frq <= 12000:
                pools["l6"].append(rec)
            seen.add(w)

    for key in pools:
        pools[key].sort(key=lambda e: (e["frq"] or 99999, e["bnc"] or 99999))

    level_of = {"cet6": 4, "ieltstoefl": 5, "l6": 6}
    next_id = max_id
    for key, level in level_of.items():
        taken = pools[key][:CAPS[key]]
        for e in taken:
            next_id += 1
            cur.execute("""INSERT INTO lexicon_entry
                (id, word, phonetic, pos, collins, oxford, examTags, bnc, frq, level, translationFull, source)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""",
                (next_id, e["word"], e["phonetic"], e["pos"], e["collins"] or None,
                 e["oxford"] or None, e["tags"], e["bnc"], e["frq"], level, e["full"], "ecdict-l456"))
            order = 0
            normal = [(p, t) for p, t, d in e["senses"] if not d]
            domain = [(p, t) for p, t, d in e["senses"] if d]
            for k, (p, t) in enumerate(normal):
                order += 1
                role = "core" if k == 0 else ("ext" if k <= 2 else "detail")
                cur.execute("INSERT INTO sense(wordId, senseOrder, pos, text, role) VALUES(?,?,?,?,?)",
                            (next_id, order, p, t, role))
            for p, t in domain:
                order += 1
                cur.execute("INSERT INTO sense(wordId, senseOrder, pos, text, role) VALUES(?,?,?,?,?)",
                            (next_id, order, p, t, "domain"))
        print(f"L{level}（{key}）: 入库 {len(taken)} 词")

    conn.commit()
    for lv in (1, 2, 3, 4, 5, 6):
        n = cur.execute("SELECT COUNT(*) FROM lexicon_entry WHERE level=?", (lv,)).fetchone()[0]
        print(f"  L{lv}: {n}")
    print("总词量:", cur.execute("SELECT COUNT(*) FROM lexicon_entry").fetchone()[0])
    conn.close()


if __name__ == "__main__":
    main()
