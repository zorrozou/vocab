# -*- coding: utf-8 -*-
"""真实词库构建管线 v0.2（ECDICT 全量）
产出 data/lexicon_v0.1.sqlite：
  lexicon_entry  L1(frq 1-1000) + L2(1001-3000) + L3(cet4 增量，按 frq 取前 2000)
  sense          义项表：core=核心义项, ext=高频扩展义项(≤2), domain=领域义项(只查不学)
  variant_map    词形归并表（lemma.en.txt + exchange 字段）
并打印校验报告（对应《词库建设方案》§5 的词条部分；例句覆盖待 Tatoeba 导入后另验）。
"""
import csv, json, re, sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CSV_PATH = ROOT / "data" / "ecdict.csv"
LEMMA_PATH = ROOT / "data" / "lemma.en.txt"
DB_PATH = ROOT / "data" / "lexicon_v0.1.sqlite"
GOOGLE_1K = ROOT / "data" / "google-10000.txt"

L3_CAP = 2000
DOMAIN_RE = re.compile(r"\[[^\]]{1,6}\]")
POS_RE = re.compile(r"^([a-z]{1,4}|vi|vt|adj|adv|abbr|prep|conj|pron|num|int|art)\.\s*")


def norm_word(w):
    return w.strip().lower()


def split_senses(text):
    """translation 多行 -> [(pos, sense_text, is_domain)]，按出现顺序
    ECDICT 用字面 \\n 转义（非真换行）分隔义项行，需先还原。"""
    out = []
    lines = (text or "").replace("\\r", "").replace("\\n", "\n").splitlines()
    for line in lines:
        line = line.strip()
        if not line:
            continue
        is_domain = bool(DOMAIN_RE.search(line))
        line_clean = DOMAIN_RE.sub("", line).strip()
        pos = ""
        m = POS_RE.match(line_clean)
        if m:
            pos = m.group(1)
            line_clean = line_clean[m.end():]
        line_clean = line_clean.strip(" ,;；")
        if not line_clean:
            continue
        out.append((pos, line_clean, is_domain))
    return out


def main():
    # ---------- 1. 读取 lemma 归并表 ----------
    variant2lemma = {}
    for line in LEMMA_PATH.read_text(encoding="utf-8", errors="ignore").splitlines():
        if not line or line.startswith(";") or "->" not in line:
            continue
        left, right = line.split("->", 1)
        lemma = norm_word(left.split("/")[0])
        for v in right.split(","):
            v = norm_word(v.strip().strip("'"))
            if v and v != lemma:
                variant2lemma[v] = lemma

    # ---------- 2. 扫描 ECDICT，筛选 L1~L3 ----------
    entries = []          # dicts
    seen = set()
    n_rows = n_frq = 0
    with open(CSV_PATH, encoding="utf-8") as f:
        for row in csv.DictReader(f):
            n_rows += 1
            w = norm_word(row["word"])
            if not w or " " in w or w in seen:
                continue
            frq = int(row["frq"]) if row["frq"].isdigit() else None
            bnc = int(row["bnc"]) if row["bnc"].isdigit() else None
            if frq:
                n_frq += 1
            tags = (row["tag"] or "").split()
            level = None
            if frq and frq <= 1000:
                level = 1
            elif frq and frq <= 3000:
                level = 2
            elif "cet4" in tags:
                level = 3  # 先全收，后面按 frq 截断
            if level is None:
                continue
            senses = split_senses(row["translation"])
            if not senses:
                continue
            seen.add(w)
            entries.append(dict(
                word=w, phonetic=row["phonetic"].strip(), pos=row["pos"].strip(),
                collins=row["collins"], oxford=row["oxford"],
                tags=" ".join(tags), bnc=bnc, frq=frq, level=level,
                senses=senses, full=row["translation"].strip(),
                exchange=row["exchange"].strip(),
            ))

    # L3 截断：按 frq（无 frq 用 bnc 兜底）排序取前 L3_CAP
    l3 = [e for e in entries if e["level"] == 3]
    l3.sort(key=lambda e: (e["frq"] or 99999, e["bnc"] or 99999))
    l3_keep = set(id(e) for e in l3[:L3_CAP])
    entries = [e for e in entries if e["level"] != 3 or id(e) in l3_keep]
    entries.sort(key=lambda e: (e["frq"] or 99999, e["bnc"] or 99999))

    # ---------- 3. 写库 ----------
    if DB_PATH.exists():
        DB_PATH.unlink()
    conn = sqlite3.connect(DB_PATH)
    cur = conn.cursor()
    cur.execute("""CREATE TABLE lexicon_entry(
        id INTEGER PRIMARY KEY, word TEXT UNIQUE NOT NULL, phonetic TEXT, pos TEXT,
        collins INTEGER, oxford INTEGER, examTags TEXT, bnc INTEGER, frq INTEGER,
        level INTEGER NOT NULL, translationFull TEXT, source TEXT)""")
    cur.execute("""CREATE TABLE sense(
        id INTEGER PRIMARY KEY, wordId INTEGER NOT NULL, senseOrder INTEGER NOT NULL,
        pos TEXT, text TEXT NOT NULL, role TEXT NOT NULL)""")  # role: core/ext/domain
    cur.execute("""CREATE TABLE variant_map(
        variant TEXT PRIMARY KEY, lemma TEXT NOT NULL)""")
    cur.execute("CREATE INDEX idx_sense_word ON sense(wordId)")
    cur.execute("CREATE INDEX idx_entry_level_rank ON lexicon_entry(level, frq)")

    word2id = {}
    for i, e in enumerate(entries, start=1):
        cur.execute("""INSERT INTO lexicon_entry
            (id, word, phonetic, pos, collins, oxford, examTags, bnc, frq, level, translationFull, source)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""",
            (i, e["word"], e["phonetic"], e["pos"], e["collins"] or None, e["oxford"] or None,
             e["tags"], e["bnc"], e["frq"], e["level"], e["full"], "ecdict-1.0-base"))
        word2id[e["word"]] = i
        order = 0
        normal = [(p, t) for p, t, d in e["senses"] if not d]
        domain = [(p, t) for p, t, d in e["senses"] if d]
        for k, (p, t) in enumerate(normal):
            order += 1
            role = "core" if k == 0 else ("ext" if k <= 2 else "detail")
            cur.execute("INSERT INTO sense(wordId, senseOrder, pos, text, role) VALUES(?,?,?,?,?)",
                        (i, order, p, t, role))
        for p, t in domain:
            order += 1
            cur.execute("INSERT INTO sense(wordId, senseOrder, pos, text, role) VALUES(?,?,?,?,?)",
                        (i, order, p, t, "domain"))

    # 词形归并：lemma.en.txt 全集 + exchange 自映射
    vm = {}
    for v, l in variant2lemma.items():
        if l in word2id:
            vm[v] = l
    for e in entries:
        for part in e["exchange"].split("/"):
            if ":" not in part:
                continue
            t, w = part.split(":", 1)
            if t in ("p", "d", "i", "3", "s", "r", "t") and w:
                vm.setdefault(norm_word(w), e["word"])
    vm.pop("", None)
    cur.executemany("INSERT OR IGNORE INTO variant_map(variant, lemma) VALUES(?,?)",
                    sorted(vm.items()))
    conn.commit()

    # ---------- 4. 校验报告 ----------
    q = lambda sql, *a: cur.execute(sql, a).fetchone()[0]
    print("=" * 56)
    print("词库构建校验报告  lexicon_v0.1.sqlite")
    print("=" * 56)
    print(f"ECDICT 扫描: {n_rows} 行，其中带 frq 词频: {n_frq}")
    for lv, name in ((1, "L1 核心"), (2, "L2 进阶"), (3, "L3 四级增量")):
        print(f"{name}: {q('SELECT COUNT(*) FROM lexicon_entry WHERE level=?', lv)} 词")
    total = q("SELECT COUNT(*) FROM lexicon_entry")
    print(f"合计: {total} 词")
    n_sense = q("SELECT COUNT(*) FROM sense")
    n_core = q("SELECT COUNT(*) FROM sense WHERE role='core'")
    n_ext = q("SELECT COUNT(*) FROM sense WHERE role='ext'")
    n_domain = q("SELECT COUNT(*) FROM sense WHERE role='domain'")
    n_detail = q("SELECT COUNT(*) FROM sense WHERE role='detail'")
    print(f"义项总数: {n_sense}（core {n_core} / ext {n_ext} / detail {n_detail} / domain {n_domain}）")
    multi = q("SELECT COUNT(DISTINCT wordId) FROM (SELECT wordId FROM sense WHERE role IN ('core','ext') GROUP BY wordId HAVING COUNT(*)>1)")
    print(f"多义词（≥2 义项）: {multi} 词，占 {multi/total*100:.0f}%")
    print(f"缺音标: {q('SELECT COUNT(*) FROM lexicon_entry WHERE phonetic=%s' % repr(''))} 词")
    print(f"词形归并表: {q('SELECT COUNT(*) FROM variant_map')} 条（runs→run 类映射）")

    print("\n考纲标签分布（L1~L3 内）:")
    for tag in ("gk", "cet4", "cet6", "ky", "ielts", "toefl"):
        n = q("SELECT COUNT(*) FROM lexicon_entry WHERE examTags LIKE ?", f"%{tag}%")
        print(f"  {tag}: {n}")

    # L1 与 Google 词频前 1000 的重合 sanity check
    g1k = [w.strip() for w in GOOGLE_1K.read_text().splitlines()][:1000]
    hit = sum(1 for w in g1k if w in word2id and word2id[w])
    print(f"\nSanity: Google 词频前1000 与 L1~L3 重合 {hit}/1000")

    print("\n多义词抽样（core / ext）:")
    for w in ("run", "bank", "time", "get", "light", "book"):
        if w not in word2id:
            continue
        rows = cur.execute(
            "SELECT role, pos, text FROM sense WHERE wordId=? AND role IN ('core','ext') ORDER BY senseOrder",
            (word2id[w],)).fetchall()
        print(f"  {w}: " + " | ".join(f"[{r}:{p or '-'}] {t[:28]}" for r, p, t in rows[:4]))

    print("\n词形归并抽样:")
    for v in ("runs", "drinks", "mountains", "went", "children", "better"):
        r = cur.execute("SELECT lemma FROM variant_map WHERE variant=?", (v,)).fetchone()
        print(f"  {v} → {r[0] if r else '✗ 未收录'}")

    conn.close()
    print(f"\n数据库: {DB_PATH}  ({DB_PATH.stat().st_size/1024/1024:.1f} MB)")


if __name__ == "__main__":
    main()
