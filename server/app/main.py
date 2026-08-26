# -*- coding: utf-8 -*-
"""个性化例句服务 v0.2（vocab-api）
端点：
  GET  /api/v1/health
  GET  /api/v1/demo/daily?pos=N   测试页用：取 N 位置的 5 个新词 + 静态句 + 失败词候选池
  POST /api/v1/personalize        上行最小状态（sync=true 时立即生成）
  GET  /api/v1/personalized       拉取个性化例句
  GET  /api/v1/lexicon/latest|download  词库版本与整包下载
  GET  /                          测试页（static/index.html）
"""
import json, os, re, sqlite3, time, urllib.request
from pathlib import Path

from fastapi import FastAPI, Query
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

BASE_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = BASE_DIR / "data"
DATA_DIR.mkdir(exist_ok=True)
STATIC_DIR = BASE_DIR / "static"
PERSONAL_DB = DATA_DIR / "personal.db"
LEXICON_DB = DATA_DIR / "lexicon_v0.1.sqlite"

LLM_BASE = os.environ.get("LLM_BASE_URL", "https://open.bigmodel.cn/api/paas/v4").rstrip("/")
LLM_KEY = os.environ.get("LLM_API_KEY", "")
LLM_MODEL = os.environ.get("LLM_MODEL", "glm-4.6")
MAX_LEN = 12
CONTENT_POS = ("n", "vt", "vi", "v", "a", "ad")

toks = lambda t: [x.strip("'") for x in re.findall(r"[a-zA-Z']+", t.lower()) if x.strip("'")]

# ---------- 词库（只读）----------
_lx = sqlite3.connect(f"file:{LEXICON_DB}?mode=ro", uri=True, check_same_thread=False)
_lx.row_factory = sqlite3.Row
seq = _lx.execute("SELECT id, word FROM lexicon_entry ORDER BY level, frq").fetchall()
POS_OF = {r["id"]: i for i, r in enumerate(seq, 1)}
WORD2ID = {r["word"]: r["id"] for r in seq}
ID2WORD = {r["id"]: r["word"] for r in seq}
SENSE = {r["wordId"]: r["text"] for r in _lx.execute("SELECT wordId, text FROM sense WHERE role='core'")}
PTAG = {r["wordId"]: (r["pos"] or "") for r in _lx.execute("SELECT wordId, pos FROM sense WHERE role='core'")}
VMAP = {r["variant"]: r["lemma"] for r in _lx.execute("SELECT variant, lemma FROM variant_map")}


def static_sentences(wid):
    """按档位返回 LLM 成品句（每档一条，llm-tier-v1 优先）；template 占位句不对外"""
    rows = _lx.execute(
        """SELECT text, tier, translation FROM sentence s
           WHERE targetWordId=? AND genMethod LIKE 'llm-%'
             AND id = (SELECT id FROM sentence s2
                       WHERE s2.targetWordId = s.targetWordId AND s2.tier = s.tier
                         AND s2.genMethod LIKE 'llm-%'
                       ORDER BY CASE WHEN s2.genMethod='llm-tier-v1' THEN 0 ELSE 1 END,
                                s2.id DESC LIMIT 1)
           ORDER BY tier LIMIT 3""",
        (wid,)).fetchall()
    return [{"tier": r["tier"], "text": r["text"], "zh": r["translation"] or ""} for r in rows]


def static_sentence(wid):
    ss = static_sentences(wid)
    return ss[0]["text"] if ss else ""


def init_db():
    conn = sqlite3.connect(PERSONAL_DB)
    conn.execute("""CREATE TABLE IF NOT EXISTS requests(
        device TEXT, date TEXT, payload TEXT, created REAL, processed INTEGER DEFAULT 0)""")
    try:
        conn.execute("ALTER TABLE requests ADD COLUMN processed INTEGER DEFAULT 0")
    except sqlite3.OperationalError:
        pass
    conn.execute("""CREATE TABLE IF NOT EXISTS sentences(
        device TEXT, date TEXT, target TEXT, recall TEXT, text TEXT, created REAL, zh TEXT DEFAULT '')""")
    try:
        conn.execute("ALTER TABLE sentences ADD COLUMN zh TEXT DEFAULT ''")
    except sqlite3.OperationalError:
        pass
    conn.execute("DELETE FROM sentences WHERE created < ?", (time.time() - 7 * 86400,))
    conn.commit()
    conn.close()


def llm(prompt):
    req = urllib.request.Request(
        f"{LLM_BASE}/chat/completions",
        data=json.dumps({"model": LLM_MODEL, "messages": [{"role": "user", "content": prompt}],
                         "thinking": {"type": "disabled"}, "temperature": 0.7,
                         "max_tokens": 200}).encode(),
        headers={"Authorization": f"Bearer {LLM_KEY}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=45) as r:
        return json.loads(r.read())["choices"][0]["message"]["content"].strip().strip('"').splitlines()[0].strip()


def validate(cand, target, recall, max_pos, max_len=MAX_LEN):
    ts = toks(cand)
    if not (3 <= len(ts) <= max_len):
        return f"句长{len(ts)}超界"
    hit_t = hit_r = False
    for t in ts:
        lemma = VMAP.get(t, t)
        wid = WORD2ID.get(lemma)
        if wid is None:
            return f"词库外词汇:{t}"
        if POS_OF.get(wid, 10 ** 9) > max_pos and lemma not in (target, recall):
            return f"超出学习范围:{t}"
        hit_t |= (t == target or lemma == target)
        hit_r |= (recall is not None and lemma == recall)
    if not hit_t:
        return "未出现目标词"
    if recall and not hit_r:
        return "未出现失败词"
    return None


def assign_recalls(new_words, weak_words, seed):
    """薄弱词概率分配：每个薄弱词出现 1~2 次；最多约一半句子带薄弱词，不是每句都织入"""
    import random as _r
    rng = _r.Random(seed)
    if not weak_words:
        return {}
    pool = weak_words * 2          # 每词最多 2 次
    rng.shuffle(pool)
    targets = new_words[:]
    rng.shuffle(targets)
    cap = min(len(pool), max(1, round(len(targets) * 0.5)))
    return {targets[i]: pool[i] for i in range(cap)}


def generate(device, date, new_words, weak_words, max_pos):
    conn = sqlite3.connect(PERSONAL_DB)
    made = 0
    plan = assign_recalls(new_words, weak_words, f"{device}{date}")
    for target in new_words:
        recall = plan.get(target)   # 可能为 None（该句不织入薄弱词）
        t_sense = (SENSE.get(WORD2ID.get(target, -1)) or "")[:50]
        r_sense = (SENSE.get(WORD2ID.get(recall, -1)) or "")[:40] if recall else ""
        prompt = (f"为背单词 App 写一条英语例句。要求：\n"
                  f"1. 必须包含目标词 \"{target}\"（词义：{t_sense}）\n"
                  + (f"2. 同时自然地包含复习词 \"{recall}\"（词义：{r_sense}）\n" if recall else "") +
                  f"3. 【真实使用场景】描述日常/工作/学习中的真实情境，两个词要融入情境而不是生硬拼凑\n"
                  f"4. 句长 6~16 个单词，语法正确、表达地道、有意义\n"
                  f"5. 除目标词与复习词外，用词为常见高频简单词\n"
                  f"6. 输出格式：英文句子 || 中文翻译，一行，不要任何解释")
        err = None
        for _ in range(3):
            try:
                out = llm(prompt + (f"\n\n上次失败原因：{err}，请修正。" if err else ""))
                cand, _, zh = out.partition("||")
                cand = cand.strip().strip('"')
                zh = zh.strip()
            except Exception as e:
                err = f"API错误:{e}"
                time.sleep(2)
                continue
            err = validate(cand, target, recall, max_pos, max_len=16)
            if not err:
                conn.execute("INSERT INTO sentences VALUES(?,?,?,?,?,?,?)",
                             (device, date, target, recall, cand, time.time(), zh))
                made += 1
                break
            time.sleep(0.2)
    conn.commit()
    conn.close()
    return made


class PersonalizeIn(BaseModel):
    device: str = Field(min_length=6, max_length=64)
    date: str = Field(pattern=r"^\d{4}-\d{2}-\d{2}$")
    new_words: list[str] = Field(default_factory=list, max_length=30)
    weak_words: list[str] = Field(default_factory=list, max_length=30)
    learned_max_pos: int = Field(default=300, ge=1, le=12000)
    sync: bool = False


app = FastAPI(title="vocab-api", version="0.2.0", on_startup=[init_db])


@app.get("/", include_in_schema=False)
def index():
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/api/v1/health")
def health():
    return {"ok": True, "lexicon_words": len(WORD2ID), "llm_ready": bool(LLM_KEY)}


@app.get("/api/v1/demo/daily")
def demo_daily(pos: int = Query(default=1200, ge=1, le=4600)):
    """测试页：取 pos 起的 5 个新词（优先实义词）+ 静态句 + 前 40 位实义词作失败候选池"""
    new_words = []
    for i in range(pos, min(pos + 30, len(seq))):
        wid = seq[i - 1]["id"]
        if len(new_words) >= 5:
            break
        if PTAG.get(wid, "").startswith(CONTENT_POS):
            new_words.append({
                "word": ID2WORD[wid], "pos": i,
                "sense": (SENSE.get(wid) or "")[:40],
                "static": static_sentence(wid)})
    pool = []
    for i in range(max(1, pos - 40), pos):
        wid = seq[i - 1]["id"]
        if PTAG.get(wid, "").startswith(CONTENT_POS):
            pool.append(ID2WORD[wid])
    return {"pos": pos, "new_words": new_words, "weak_pool": pool[-12:]}


@app.post("/api/v1/personalize")
def personalize(body: PersonalizeIn):
    conn = sqlite3.connect(PERSONAL_DB)
    conn.execute("INSERT INTO requests(device, date, payload, created) VALUES(?,?,?,?)",
                 (body.device, body.date, body.model_dump_json(), time.time()))
    conn.commit()
    conn.close()
    out = {"queued": True, "date": body.date}
    if body.sync and body.new_words:
        out["generated"] = generate(body.device, body.date, body.new_words,
                                    body.weak_words, body.learned_max_pos)
    return out


@app.get("/api/v1/personalized")
def personalized(device: str = Query(min_length=6, max_length=64),
                 date: str = Query(pattern=r"^\d{4}-\d{2}-\d{2}$")):
    conn = sqlite3.connect(PERSONAL_DB)
    rows = conn.execute(
        "SELECT target, recall, text, zh FROM sentences WHERE device=? AND date=? ORDER BY created",
        (device, date)).fetchall()
    conn.close()
    return {"device": device, "date": date,
            "sentences": [{"target": t, "recall": r, "text": x, "zh": z or ""} for t, r, x, z in rows]}


@app.get("/api/v1/lexicon/latest")
def lexicon_latest():
    pack = DATA_DIR / "lexicon_v0.1.sqlite"
    return {"version": "0.1.0", "words": len(WORD2ID),
            "size_bytes": pack.stat().st_size if pack.exists() else 0,
            "download": "/api/v1/lexicon/download"}


@app.get("/api/v1/lexicon/download")
def lexicon_download():
    return FileResponse(LEXICON_DB, filename="lexicon_v0.1.sqlite")


def word_detail(wid):
    senses = _lx.execute(
        "SELECT pos, text, role FROM sense WHERE wordId=? AND role IN ('core','ext') ORDER BY senseOrder LIMIT 3",
        (wid,)).fetchall()
    ph = _lx.execute("SELECT phonetic FROM lexicon_entry WHERE id=?", (wid,)).fetchone()
    return {"word": ID2WORD[wid], "pos": POS_OF[wid],
            "phonetic": ph["phonetic"] if ph else "",
            "senses": [{"pos": s["pos"], "text": s["text"]} for s in senses],
            "static": static_sentence(wid),
            "sentences": static_sentences(wid)}


@app.get("/api/v1/lexicon/at")
def lexicon_at(pos: int = Query(ge=1), n: int = Query(default=10, ge=1, le=30)):
    """按学习位置取 n 个词（含音标、义项、静态句）"""
    out = []
    for i in range(pos, min(pos + 40, len(seq) + 1)):
        if len(out) >= n:
            break
        wid = seq[i - 1]["id"]
        if PTAG.get(wid, "").startswith(CONTENT_POS):
            out.append(word_detail(wid))
    return {"from": pos, "words": out}


@app.get("/api/v1/lexicon/band")
def lexicon_band(lo: int = Query(ge=1), hi: int = Query(ge=2),
                 n: int = Query(default=2, ge=1, le=10), seed: int = 0):
    """词频带内随机抽 n 个实义词（定级探测用）"""
    import random as _r
    lo2, hi2 = min(lo, hi), min(max(lo, hi), len(seq))
    pool = [seq[i - 1]["id"] for i in range(lo2, hi2 + 1)
            if PTAG.get(seq[i - 1]["id"], "").startswith(CONTENT_POS)]
    rng = _r.Random(seed or time.time_ns())
    pick = rng.sample(pool, min(n, len(pool)))
    return {"lo": lo2, "hi": hi2, "words": [word_detail(w) for w in pick]}


# ---------- 定级探测词池（一次拉取，答题零网络）----------
@app.get("/api/v1/lexicon/probes")
def lexicon_probes():
    """覆盖 15 个词频带、每带 4 个实义词，供 Day-1 定级一次性拉取"""
    import random as _r
    bands = [250, 500, 750, 1000, 1250, 1500, 1750, 2000,
             2250, 2500, 2750, 3000, 3500, 4000, 4500]
    rng = _r.Random(20260806)
    out = []
    for b in bands:
        pool = [seq[i - 1]["id"] for i in range(max(1, b - 80), min(len(seq), b + 80) + 1)
                if PTAG.get(seq[i - 1]["id"], "").startswith(CONTENT_POS)]
        for wid in rng.sample(pool, min(4, len(pool))):
            d = word_detail(wid)
            out.append({"word": d["word"], "pos": d["pos"],
                        "sense": d["senses"][0]["text"] if d["senses"] else ""})
    return {"words": out}


# ---------- 复习 4 选 1 测试 ----------
def gloss_of(wid):
    """核心义项的首个词义（用于选项短文本）"""
    r = _lx.execute("SELECT pos, text FROM sense WHERE wordId=? AND role='core'", (wid,)).fetchone()
    if not r:
        return "", ""
    first = re.split(r"[,，]", r["text"])[0].strip()
    return (r["pos"] or ""), first


@app.get("/api/v1/quiz")
def quiz(pos: int = Query(ge=1), seed: int = 0):
    """4 选 1：正确词义 + 3 个同词性、邻近词频（±200 位）的干扰项"""
    import random as _r
    if pos > len(seq):
        return {"options": []}
    wid = seq[pos - 1]["id"]
    p, correct = gloss_of(wid)
    if not correct:
        return {"word": ID2WORD[wid], "pos": pos, "options": []}
    pcls = (p or "n")[:1]
    cand = []
    for i in range(max(1, pos - 200), min(len(seq), pos + 200) + 1):
        if i == pos:
            continue
        w2 = seq[i - 1]["id"]
        if not PTAG.get(w2, "").startswith(pcls):
            continue
        _, g = gloss_of(w2)
        if g and g != correct and g not in cand:
            cand.append(g)
    rng = _r.Random(seed or time.time_ns())
    rng.shuffle(cand)
    opts = [correct] + cand[:3]
    rng.shuffle(opts)
    return {"word": ID2WORD[wid], "pos": pos,
            "options": [{"text": f"{pcls}. {t}", "ok": t == correct} for t in opts]}


# ---------- TTS（神经网络语音，带磁盘缓存）----------
TTS_DIR = DATA_DIR / "tts_cache"
TTS_DIR.mkdir(exist_ok=True)
TTS_VOICE = os.environ.get("TTS_VOICE", "en-US-AriaNeural")


@app.get("/api/v1/tts")
def tts(text: str = Query(min_length=1, max_length=200), v: str = ""):
    import asyncio, hashlib
    import edge_tts
    voice = v if v in ("en-US-AriaNeural", "en-US-GuyNeural", "en-US-JennyNeural", "en-GB-SoniaNeural") else TTS_VOICE
    key = hashlib.sha1(f"{voice}|{text}".encode()).hexdigest()[:16]
    f = TTS_DIR / f"{key}.mp3"
    if not f.exists():
        asyncio.run(edge_tts.Communicate(text, voice).save(str(f)))
    return FileResponse(f, media_type="audio/mpeg")


# ---------- 例句按需生成（缺句时现场生成并永久缓存进词库）----------
_lxw = sqlite3.connect(LEXICON_DB, check_same_thread=False)


@app.get("/api/v1/sentence/ensure")
def sentence_ensure(word: str = Query(min_length=1, max_length=40)):
    wid = WORD2ID.get(word)
    if not wid:
        return {"word": word, "text": ""}
    s = static_sentences(wid)
    if s:
        return {"word": word, "text": s[0]["text"], "cached": True}
    pos = POS_OF[wid]
    cap = max(pos, 300)
    sense = (SENSE.get(wid) or "")[:50]
    prompt = (f"为背单词 App 写一条英语例句，要求：\n"
              f"1. 必须包含目标词 \"{word}\"（词义：{sense}）\n"
              f"2. 句长 3~12 个单词，句子自然、地道、简单\n"
              f"3. 其他用词必须是英语最常见的简单高频词\n"
              f"4. 只输出英文例句本身，一行，不要解释")
    err = None
    for _ in range(3):
        try:
            cand = llm(prompt + (f"\n\n上次失败原因：{err}，请修正。" if err else ""))
        except Exception as e:
            err = f"API错误:{e}"
            break
        err = validate(cand, word, None, cap)
        if not err:
            sid = _lx.execute("SELECT id FROM sense WHERE wordId=? AND role='core'", (wid,)).fetchone()[0]
            _lxw.execute("""INSERT INTO sentence(text, translation, wordIds, senseId, targetWordId, recallIds, genMethod, flag)
                            VALUES(?,?,?,?,?,?,?,?)""",
                         (cand, None, json.dumps([wid]), sid, wid, "[]", "llm-api-v1", "on_demand"))
            _lxw.commit()
            return {"word": word, "text": cand, "cached": False}
    return {"word": word, "text": ""}


# ---------- 定级题库（30 道 4 选 1，按用户种子随机抽题，词频带结构固定）----------
@app.get("/api/v1/placement/set")
def placement_set(seed: str = ""):
    import random as _r
    seed_val = seed or str(time.time_ns())
    rng = _r.Random(seed_val)
    bands = [300, 500, 750, 1000, 1250, 1500, 1750, 2000,
             2250, 2500, 2750, 3000, 3500, 4000, 4500]
    items = []
    for b in bands:
        pool = [i for i in range(max(1, b - 80), min(len(seq), b + 80) + 1)
                if PTAG.get(seq[i - 1]["id"], "").startswith(CONTENT_POS)]
        for i in rng.sample(pool, min(2, len(pool))):
            wid = seq[i - 1]["id"]
            p, correct = gloss_of(wid)
            if not correct:
                continue
            pcls = (p or "n")[:1]
            cand = []
            for j in range(max(1, i - 200), min(len(seq), i + 200) + 1):
                if j == i:
                    continue
                w2 = seq[j - 1]["id"]
                if not PTAG.get(w2, "").startswith(pcls):
                    continue
                _, g = gloss_of(w2)
                if g and g != correct and g not in cand:
                    cand.append(g)
            if len(cand) < 3:
                continue
            rng.shuffle(cand)
            opts = [correct] + cand[:3]
            rng.shuffle(opts)
            items.append({"word": ID2WORD[wid], "pos": i,
                          "options": [{"text": f"{pcls}. {t}", "ok": t == correct} for t in opts]})
    return {"words": items[:30], "seed": seed_val}


# ---------- 新词三句套装：1 条句库句 + 2 条生成句（≥10 词）----------
TIER_RANGE = {1: (3, 10), 2: (10, 16), 3: (10, 20)}


@app.get("/api/v1/sentence/trio")
def sentence_trio(word: str = Query(min_length=1, max_length=40), weak: str = "", cap: int = 0):
    wid = WORD2ID.get(word)
    if not wid:
        return {"word": word, "sentences": []}
    rows = _lx.execute(
        "SELECT text, tier, translation FROM sentence WHERE targetWordId=? AND genMethod LIKE 'llm-%'", (wid,)).fetchall()
    have = {}
    for r in rows:
        have.setdefault(r["tier"], (r["text"], r["translation"] or ""))
    if len(have) >= 3:
        return {"word": word, "sentences": [{"tier": t, "text": have[t][0], "zh": have[t][1]} for t in sorted(have)][:3]}
    pos = POS_OF[wid]
    cap = max(pos, 300, cap)  # 调用方可传入真实学习位置（召回词是用户已学的词）
    sense = (SENSE.get(wid) or "")[:50]
    weaks = [x for x in weak.split(",") if x]
    recall = None
    if weaks:
        # 按目标词轮换薄弱词，保证全部薄弱词都被覆盖而不是总重复前几个
        recall = weaks[(sum(ord(c) for c in word) + pos) % len(weaks)]
    need = [t for t in (1, 2, 3) if t not in have]
    spec = []
    if 1 in need:
        spec.append(f"A: 基础句，3~10 个单词，简单句" + (f"，必须包含复习词 \"{recall}\"" if recall else ""))
    if 2 in need:
        spec.append("B: 进阶句，10~16 个单词，必须含一个从句（when/because/that/which/who 等）")
    if 3 in need:
        spec.append("C: 挑战句，10~20 个单词，含复合结构（从句/非谓语/介词短语组合）")
    prompt = (f"为背单词 App 的单词 \"{word}\"（词义：{sense}）写例句，逐条输出：\n"
              + "\n".join(spec) +
              f"\n其他约束：除目标词和指定复习词外只用英语最常见的高频简单词（约前 {cap} 词范围）；"
              f"句子必须自然、地道、有意义。每行格式严格为 \"A: <英文句子> || <中文翻译>\"，"
              f"输出恰好 {len(spec)} 行，不要其他解释。")
    err = None

    def try_insert(tier, text, zh=""):
        lo, hi = TIER_RANGE[tier]
        ts = toks(text)
        if not (lo <= len(ts) <= hi):
            return f"长度{len(ts)}词(要求{lo}~{hi})"
        cap_t = cap if tier == 1 else cap + 500   # 进阶/挑战档放宽近前方词
        hit_t = hit_r = (recall is None)
        for t in ts:
            tw = WORD2ID.get(VMAP.get(t, t))
            if tw is None:
                return f"词库外:{t}"
            if POS_OF[tw] > cap_t and VMAP.get(t, t) not in (word, recall):
                return f"超范围:{t}"
            hit_t |= (VMAP.get(t, t) == word or t == word)
            hit_r |= recall is not None and VMAP.get(t, t) == recall
        if not hit_t:
            return "缺目标词"
        if tier == 1 and not hit_r:
            return "缺召回词"
        sid = _lx.execute("SELECT id FROM sense WHERE wordId=? AND role='core'", (wid,)).fetchone()[0]
        _lxw.execute("""INSERT INTO sentence(text, translation, wordIds, senseId, targetWordId, recallIds, genMethod, flag, tier)
                        VALUES(?,?,?,?,?,?,?,?,?)""",
                     (text, zh, json.dumps([wid]), sid, wid,
                      json.dumps([WORD2ID.get(recall)] if recall and tier == 1 else []),
                      "llm-tier-v1", "on_demand", tier))
        have[tier] = (text, zh)
        return None

    labels = {1: "A", 2: "B", 3: "C"}
    # 第一轮：合并输出（一次调用解析多行）
    try:
        out = llm(prompt)
        for line in out.splitlines():
            m = re.match(r"^([ABC])[::.]\s*(.+)$", line.strip())
            if m:
                tier = "ABC".index(m.group(1)) + 1
                if tier in need:
                    body, _, zh = m.group(2).partition("||")
                    e = try_insert(tier, body.strip().strip('"'), zh.strip())
                    if e:
                        err = f"{m.group(1)}行:{e}"
    except Exception as e:
        err = f"API错误:{e}"
    # 第二轮：缺档逐档单独生成（每档最多 2 次）
    TIER_DESC = {1: "基础句，3~10 个单词，简单句", 2: "进阶句，10~16 个单词，含一个从句（when/because/that/which/who 等）",
                 3: "挑战句，10~20 个单词，含复合结构（从句/非谓语/介词短语组合）"}
    for tier in need:
        if tier in have:
            continue
        single = (f"为背单词 App 的单词 \"{word}\"（词义：{sense}）写一条英语例句：{TIER_DESC[tier]}。"
                  + (f"必须包含复习词 \"{recall}\"。" if recall and tier == 1 else "")
                  + f"其他词用常见高频简单词。句子自然地道。输出格式：英文句子 || 中文翻译，一行，不要其他内容。")
        for _ in range(2):
            try:
                cand = llm(single).strip().strip('"').splitlines()[0].strip()
                cand = re.sub(r"^[ABC][::.]\s*", "", cand)
                body, _, zh = cand.partition("||")
            except Exception as e:
                err = f"API错误:{e}"
                break
            e = try_insert(tier, body.strip(), zh.strip())
            if not e:
                break
            err = f"{labels[tier]}行:{e}"
    _lxw.commit()
    return {"word": word,
            "sentences": [{"tier": t, "text": have[t][0], "zh": have[t][1]} for t in sorted(have)][:3],
            "err": err if len(have) < 3 else None}




# ---------- FSRS 调度（官方 py-fsrs，FSRS-6 默认参数，保持率 0.9）----------
from datetime import datetime, timezone

from fsrs import Card as _FsrsCard, Rating as _FsrsRating, Scheduler as _FsrsScheduler, State as _FsrsState

FSRS = _FsrsScheduler(desired_retention=0.9)


class FsrsIn(BaseModel):
    is_new: bool = False
    state: int = 1          # 1 Learning / 2 Review / 3 Relearning
    stability: float = 0
    difficulty: float = 0
    due: str | None = None
    rating: int = 3         # 1 Again / 2 Hard / 3 Good / 4 Easy


@app.post("/api/v1/fsrs/review")
def fsrs_review(body: FsrsIn):
    c = _FsrsCard()
    if not body.is_new:
        c.state = _FsrsState(body.state)
        c.stability = body.stability
        c.difficulty = body.difficulty
        if body.due:
            d = datetime.fromisoformat(body.due.replace("Z", "+00:00"))
            c.due = d.replace(tzinfo=timezone.utc) if d.tzinfo is None else d
        c.last_review = datetime.now(timezone.utc)
    c, log = FSRS.review_card(c, _FsrsRating(body.rating))
    return {"state": c.state.value,
            "stability": round(c.stability, 3),
            "difficulty": round(c.difficulty, 3),
            "due": c.due.isoformat(),
            "scheduled_days": getattr(log, "scheduled_days", None)}
