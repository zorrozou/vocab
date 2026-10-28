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
import hashlib, json, logging, os, re, secrets, sqlite3, threading, time, urllib.request
from pathlib import Path

logger = logging.getLogger(__name__)

from fastapi import FastAPI, Header, HTTPException, Query, Request
from fastapi.responses import FileResponse, HTMLResponse
from pydantic import BaseModel, Field

from app.auth import identity_by_token, mount_auth, user_by_token
from app.fsrs_config import fsrs_config_key, normalize_fsrs_config
from app.limits import check_rate
from app.tts_patch import patch_edge_tts

patch_edge_tts()   # edge-tts v2 端点迁移补丁（微软 2026-10 迁移致 v1 握手 403）

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
class _ThreadLocalLexicon:
    """词库只读连接不跨线程共享，避免并发请求同时使用同一 SQLite 连接。"""
    def __init__(self):
        self.local = threading.local()

    def execute(self, sql, parameters=()):
        if not hasattr(self.local, "connection"):
            conn = sqlite3.connect(f"file:{LEXICON_DB}?mode=ro", uri=True)
            conn.row_factory = sqlite3.Row
            self.local.connection = conn
        return self.local.connection.execute(sql, parameters)

_lx = _ThreadLocalLexicon()
seq = _lx.execute("SELECT id, word FROM lexicon_entry ORDER BY level, frq").fetchall()
POS_OF = {r["id"]: i for i, r in enumerate(seq, 1)}
WORD2ID = {r["word"]: r["id"] for r in seq}
ID2WORD = {r["id"]: r["word"] for r in seq}
LVL = {r["id"]: r["level"] for r in _lx.execute("SELECT id, level FROM lexicon_entry")}
EXAM = {r["id"]: (r["examTags"] or "") for r in _lx.execute("SELECT id, examTags FROM lexicon_entry")}
SENSE = {r["wordId"]: r["text"] for r in _lx.execute("SELECT wordId, text FROM sense WHERE role='core'")}
PTAG = {r["wordId"]: (r["pos"] or "") for r in _lx.execute("SELECT wordId, pos FROM sense WHERE role='core'")}
VMAP = {r["variant"]: r["lemma"] for r in _lx.execute("SELECT variant, lemma FROM variant_map")}


def lex_lemma(t):
    """词形归一：优先 variant_map，其次常见英文变形兜底。
    避免 asserted/making/running/studies 等合法变形被误判为"词库外"。"""
    if t in VMAP:
        return VMAP[t]
    if t in WORD2ID:
        return t
    cands = []
    if t.endswith("ies") and len(t) > 4:
        cands.append(t[:-3] + "y")
    if t.endswith("ed") and len(t) > 4:
        cands.extend((t[:-2], t[:-1]))
    if t.endswith("ing") and len(t) > 5:
        cands.extend((t[:-3], t[:-3] + "e"))
        if len(t) > 6 and t[-4] == t[-5]:
            cands.append(t[:-4])   # running → run
    if t.endswith("es") and len(t) > 3:
        cands.extend((t[:-2], t[:-1]))
    elif t.endswith("s") and len(t) > 3:
        cands.append(t[:-1])
    for c in cands:
        if c in WORD2ID:
            return c
    return t


def static_sentences(wid):
    """每档一条：Tatoeba 自然语料优先，LLM 生成补缺；template 占位句不对外"""
    rows = _lx.execute(
        """SELECT text, tier, translation FROM sentence s
           WHERE targetWordId=? AND (genMethod LIKE 'llm-%' OR genMethod='tatoeba')
             AND COALESCE(flag,'') != 'reported'
             AND id = (SELECT id FROM sentence s2
                       WHERE s2.targetWordId = s.targetWordId AND s2.tier = s.tier
                         AND (s2.genMethod LIKE 'llm-%' OR s2.genMethod='tatoeba')
                         AND COALESCE(s2.flag,'') != 'reported'
                       ORDER BY CASE s2.genMethod WHEN 'tatoeba' THEN 0
                                  WHEN 'llm-tier-v1' THEN 1 ELSE 2 END,
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
    conn.execute("""CREATE TABLE IF NOT EXISTS sentence_reports(
        word TEXT NOT NULL, text TEXT NOT NULL, user_id INTEGER, device TEXT,
        created REAL NOT NULL)""")
    conn.execute("""CREATE TABLE IF NOT EXISTS personal_jobs(
        id TEXT PRIMARY KEY, device TEXT NOT NULL, date TEXT NOT NULL,
        payload TEXT NOT NULL, status TEXT NOT NULL, created REAL NOT NULL,
        updated REAL NOT NULL, error TEXT, lease_owner TEXT, lease_until REAL)""")
    for column in ("lease_owner TEXT", "lease_until REAL"):
        try:
            conn.execute(f"ALTER TABLE personal_jobs ADD COLUMN {column}")
        except sqlite3.OperationalError:
            pass
    conn.execute("""CREATE TABLE IF NOT EXISTS personal_job_sentences(
        job_id TEXT NOT NULL, target TEXT NOT NULL, recall TEXT, text TEXT NOT NULL,
        zh TEXT, created REAL NOT NULL, PRIMARY KEY(job_id, target))""")
    conn.execute("CREATE INDEX IF NOT EXISTS personal_jobs_owner_date ON personal_jobs(device, date, created)")
    conn.execute("""CREATE TABLE IF NOT EXISTS fsrs_scheduler_versions(
        owner TEXT NOT NULL, scheduler_key TEXT NOT NULL, config_json TEXT NOT NULL,
        created REAL NOT NULL, PRIMARY KEY(owner, scheduler_key))""")
    conn.execute("""CREATE TABLE IF NOT EXISTS guest_credentials(
        token_hash TEXT PRIMARY KEY, created REAL NOT NULL)""")
    conn.execute("""CREATE TABLE IF NOT EXISTS legacy_personal_bindings(
        user_id INTEGER PRIMARY KEY, account_id TEXT NOT NULL)""")
    conn.execute("""CREATE TABLE IF NOT EXISTS legacy_scheduler_bindings(
        user_id INTEGER PRIMARY KEY, account_id TEXT NOT NULL)""")
    try:
        conn.execute("ALTER TABLE sentences ADD COLUMN zh TEXT DEFAULT ''")
    except sqlite3.OperationalError:
        pass
    # 迁移记录和数据写入同一事务；已绑定的旧 ID 永远不能由另一账号认领。
    from app import auth as auth_module
    with sqlite3.connect(auth_module.USERS_DB, timeout=15) as users:
        legacy_users = users.execute("SELECT id, account_id FROM users WHERE legacy_personal=1").fetchall()
    conn.execute("BEGIN IMMEDIATE")
    for uid, account_id in legacy_users:
        if not conn.execute("SELECT 1 FROM legacy_scheduler_bindings WHERE user_id=?", (uid,)).fetchone():
            conn.execute("INSERT INTO legacy_scheduler_bindings(user_id,account_id) VALUES(?,?)", (uid, account_id))
            old_versions = conn.execute("SELECT scheduler_key, config_json, created FROM fsrs_scheduler_versions WHERE owner=?", (f"user:{uid}",)).fetchall()
            for key, config, created in old_versions:
                existing = conn.execute("SELECT config_json FROM fsrs_scheduler_versions WHERE owner=? AND scheduler_key=?", (f"account:{account_id}", key)).fetchone()
                if existing and json.loads(existing[0]) != json.loads(config):
                    raise ValueError("conflicting scheduler snapshot during migration")
                conn.execute("INSERT OR IGNORE INTO fsrs_scheduler_versions(owner,scheduler_key,config_json,created) VALUES(?,?,?,?)", (f"account:{account_id}", key, config, created))
        binding = conn.execute("SELECT account_id FROM legacy_personal_bindings WHERE user_id=?", (uid,)).fetchone()
        if binding:
            continue
        conn.execute("INSERT INTO legacy_personal_bindings(user_id,account_id) VALUES(?,?)", (uid, account_id))
        old_owner, new_owner = f"u{uid}", f"account:{account_id}"
        # 幂等重试比较整个任务载荷，设备字段必须和外层归属一起迁移。
        for table in ("requests", "personal_jobs"):
            for rowid, payload in conn.execute(f"SELECT rowid, payload FROM {table} WHERE device=?", (old_owner,)).fetchall():
                try:
                    data = json.loads(payload)
                    if isinstance(data, dict) and data.get("device") == old_owner:
                        data["device"] = new_owner
                        payload = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
                except (TypeError, ValueError):
                    logger.warning("保留无法解析的旧个性化任务载荷 table=%s rowid=%s", table, rowid)
                conn.execute(f"UPDATE {table} SET device=?, payload=? WHERE rowid=?", (new_owner, payload, rowid))
        conn.execute("UPDATE sentences SET device=? WHERE device=?", (new_owner, old_owner))
    conn.execute("DELETE FROM sentences WHERE created < ?", (time.time() - 7 * 86400,))
    conn.commit()
    conn.close()


def llm(prompt):
    req = urllib.request.Request(
        f"{LLM_BASE}/chat/completions",
        data=json.dumps({"model": LLM_MODEL, "messages": [{"role": "user", "content": prompt}],
                         "thinking": {"type": "disabled"}, "temperature": 0.7,
                         **({"max_tokens": int(os.environ["LLM_MAX_TOKENS"])}
                            if os.environ.get("LLM_MAX_TOKENS") else {})}).encode(),
        headers={"Authorization": f"Bearer {LLM_KEY}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        # 保留多行：三档例句一次返回 A/B/C；单行提示也不受影响。
        return json.loads(r.read())["choices"][0]["message"]["content"].strip().strip('"')


def core_sense(wid, limit=50):
    """生成时只锚定最高频核心义项，避免 apple 被写成俚语“家伙”等边缘用法。"""
    raw = SENSE.get(wid) or ""
    return re.split(r"[,，;；]", raw, maxsplit=1)[0].strip()[:limit]


def validate(cand, target, recall, max_pos, max_len=MAX_LEN):
    ts = toks(cand)
    if not (3 <= len(ts) <= max_len):
        return f"句长{len(ts)}超界"
    hit_t = hit_r = False
    for t in ts:
        lemma = lex_lemma(t)
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


# 交叉评审模型配置（缺省用主模型；生产建议配成另一厂商以消除同模型盲区）
JUDGE_BASE = os.environ.get("LLM_JUDGE_BASE_URL", LLM_BASE).rstrip("/")
JUDGE_KEY = os.environ.get("LLM_JUDGE_API_KEY", LLM_KEY)
JUDGE_MODEL = os.environ.get("LLM_JUDGE_MODEL", LLM_MODEL)


def judge_llm(prompt):
    """评审调用：走独立的评审模型配置（交叉模型，消除同模型自评盲区）"""
    req = urllib.request.Request(
        f"{JUDGE_BASE}/chat/completions",
        data=json.dumps({"model": JUDGE_MODEL, "messages": [{"role": "user", "content": prompt}],
                         "thinking": {"type": "disabled"}, "temperature": 0.2}).encode(),
        headers={"Authorization": f"Bearer {JUDGE_KEY}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())["choices"][0]["message"]["content"].strip()


def quality_check(sentence, target, recall=None):
    """评审（交叉模型 + 分项 rubric）：语法/搭配/语义/场景 各 ≥4 才收"""
    prompt = (f"你是英语教材评审。给这个给中国学生看的英语例句按四个维度打分（各 1~5 整数）：\n"
              f"\"{sentence}\"\n"
              f"目标词：{target}" + (f"，复习词：{recall}" if recall else "") +
              f"\n维度与标准（5=完全达标，1=严重问题）：\n"
              f"语法 = 语法正确；搭配 = 符合母语者习惯、无生造词组或中式英语；"
              f"语义 = 词与词不矛盾不牵强；场景 = 像真实生活中会说的话\n"
              f"只输出四个数字，空格分隔（如：5 5 4 5）。")
    try:
        out = judge_llm(prompt)
        nums = [int(x) for x in re.findall(r"\d", out)][:4]
        return min(nums) if nums else 3
    except Exception:
        return 0   # 评审不可用时不把未知质量当成合格，避免低质句进入缓存


def validate_multi(cand, target, recalls, max_pos, max_len=16):
    """多复习词版校验：目标词 + 每个复习词都必须出现；
    词汇约束带 1500 位过档余量与 1 个词库外容忍（hy4 常用词排序偏后，exam 类词不应误杀）"""
    ts = toks(cand)
    if not (3 <= len(ts) <= max_len):
        return f"句长{len(ts)}超界"
    hit_t = False
    hit_set = set()
    exempt = {target, *recalls}
    oov = 0
    over = 0
    for t in ts:
        lemma = lex_lemma(t)
        wid = WORD2ID.get(lemma)
        if wid is None:
            oov += 1
            if oov > 1:
                return f"词库外词汇:{t}"
            continue
        if POS_OF.get(wid, 10 ** 9) > max_pos + 1500 and lemma not in exempt:
            over += 1
            if over > 2:
                return f"超出学习范围:{t}"
        hit_t |= (t == target or lemma == target)
        if lemma in recalls:
            hit_set.add(lemma)
    if not hit_t:
        return "未出现目标词"
    missing = [r for r in recalls if r not in hit_set]
    if missing:
        return f"未出现复习词:{'/'.join(missing)}"
    return None


def generate(device, date, weak_words, max_pos, job_id=None, job_lease=None):
    """薄弱词定制：每个薄弱词配 1~2 个其他薄弱词，随机组合成真实场景句。
    hy4 等慢速推理模型下按词并行（4 工人），整体耗时不随词数线性增长。"""
    import random as _r
    from concurrent.futures import ThreadPoolExecutor
    conn = sqlite3.connect(PERSONAL_DB, check_same_thread=False)
    ins_lock = threading.Lock()
    rng = _r.Random(f"{device}{date}")

    def insert_sentence(target, recall, text, zh):
        if job_id:
            # 条件检查和写入必须是同一条 SQL，防止租约检查后被其他工人接管。
            conn.execute("""INSERT OR REPLACE INTO personal_job_sentences(job_id, target, recall, text, zh, created)
                SELECT ?,?,?,?,?,? WHERE EXISTS
                (SELECT 1 FROM personal_jobs WHERE id=? AND status='running' AND lease_owner=?)""",
                (job_id, target, recall, text, zh, time.time(), job_id, job_lease))
        else:
            conn.execute("INSERT INTO sentences(device, date, target, recall, text, created, zh) VALUES(?,?,?,?,?,?,?)",
                         (device, date, target, recall, text, time.time(), zh))
        conn.commit()

    def gen_one(target):
        others = [w for w in weak_words if w != target]
        rng.shuffle(others)
        recalls = others[:min(2, len(others))]   # 随机 1~2 个其他薄弱词
        t_sense = core_sense(WORD2ID.get(target, -1))
        r_desc = "、".join(f'"{r}"（{core_sense(WORD2ID.get(r, -1), 20)}）' for r in recalls)
        prompt = (f"为背单词 App 写一条英语例句。要求：\n"
                  f"1. 必须包含目标词 \"{target}\"（核心词义，只使用此义项：{t_sense}）\n"
                  + (f"2. 同时自然地包含这些复习词：{r_desc}\n" if recalls else "") +
                  f"3. 【真实使用场景】描述日常/工作/学习中的真实情境，几个词要自然融入同一情境；"
                  f"【地道】必须使用英语母语者日常真实会说的固定搭配和常用句型，严禁生造词组、中式英语或生硬拼凑\n"
                  f"4. 句长 6~16 个单词，语法正确、表达地道、有意义\n"
                  f"5. 其余用词为常见高频简单词\n"
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
            err = validate_multi(cand, target, recalls, max_pos)
            if not err:
                score = quality_check(cand, target, recalls[0] if recalls else None)
                if score < 4:
                    err = f"自然度评分{score}<4，请换一个更自然、语义不矛盾的场景重写"
                    continue
                with ins_lock:
                    insert_sentence(target, ",".join(recalls) if recalls else None, cand, zh)
                ensure_tts(cand)   # 生成即产音频（本函数已在后台线程，无用户侧延迟）
                return 1
            time.sleep(0.2)
        logger.warning("个性化组合句未通过，改为单词独句：device=%s target=%s reason=%s", device, target, err)
        # 兜底：组合太难就只含目标词
        try:
            out = llm(f"为背单词 App 的单词 \"{target}\"（核心词义，只使用此义项：{t_sense}）写一条英语例句："
                      f"真实日常场景、语法正确、自然地道，6~16 词，常见高频词。"
                      f"必须使用英语母语者日常真实会说的固定搭配，严禁生造词组或中式英语。"
                      f"输出格式：英文句子 || 中文翻译，一行，不要解释。")
            cand, _, zh = out.partition("||")
            cand = cand.strip().strip('"')
            if not validate_multi(cand, target, [], max_pos) and quality_check(cand, target, None) >= 4:
                with ins_lock:
                    insert_sentence(target, None, cand, zh.strip())
                ensure_tts(cand)   # 生成即产音频
                return 1
        except Exception:
            pass
        return 0

    with ThreadPoolExecutor(max_workers=4) as ex:
        made = sum(ex.map(gen_one, weak_words))
    conn.close()
    return made

class PersonalizeIn(BaseModel):
    device: str = Field(min_length=2, max_length=64)   # 登录用户设备号为 "u{uid}" 只有2位，与 GET 端点对齐
    date: str = Field(pattern=r"^\d{4}-\d{2}-\d{2}$")
    new_words: list[str] = Field(default_factory=list, max_length=30)
    weak_words: list[str] = Field(default_factory=list, max_length=30)
    learned_max_pos: int = Field(default=300, ge=1, le=12000)
    sync: bool = False
    replace: bool = False   # True=整日替换批次（自动个性化）；False=单词追加（换一句）
    request_id: str | None = Field(default=None, min_length=8, max_length=64, pattern=r"^[A-Za-z0-9_-]+$")


def personal_owner(device, authorization, guest_token=""):
    """Account credentials or server-issued guest credentials establish ownership."""
    identity = identity_by_token(authorization)
    if authorization:
        if not identity:
            raise HTTPException(401, "未登录或登录已过期")
        return f"account:{identity[1]}"
    if not isinstance(guest_token, str) or not re.fullmatch(r"[a-f0-9]{64}", guest_token):
        raise HTTPException(401, "游客凭证无效，请重新连接")
    digest = hashlib.sha256(guest_token.encode("ascii")).hexdigest()
    with sqlite3.connect(PERSONAL_DB, timeout=15) as conn:
        if not conn.execute("SELECT 1 FROM guest_credentials WHERE token_hash=?", (digest,)).fetchone():
            raise HTTPException(401, "游客凭证无效，请重新连接")
    return f"guest:v2:{digest}"


_PERSONAL_WAKE = threading.Event()
_PERSONAL_WORKER_LOCK = threading.Lock()
_PERSONAL_WORKER = None


def claim_personal_job():
    """事务领取任务；心跳超时的任务可被其他进程重新领取。"""
    import uuid
    conn = sqlite3.connect(PERSONAL_DB, timeout=15)
    try:
        conn.execute("BEGIN IMMEDIATE")
        now = time.time()
        row = conn.execute("""SELECT id, device, date, payload FROM personal_jobs
            WHERE status='queued' OR (status='running' AND COALESCE(lease_until, 0) < ?)
            ORDER BY created LIMIT 1""", (now,)).fetchone()
        if not row:
            conn.commit()
            return None
        lease = uuid.uuid4().hex
        conn.execute("UPDATE personal_jobs SET status='running', updated=?, lease_owner=?, lease_until=?, error=NULL WHERE id=?",
                     (now, lease, now + 120, row[0]))
        conn.commit()
        return (*row, lease)
    finally:
        conn.close()


def run_personal_job(job):
    job_id, device, date, payload, lease = job
    stopped = threading.Event()

    def heartbeat():
        while not stopped.wait(30):
            try:
                with sqlite3.connect(PERSONAL_DB, timeout=15) as conn:
                    now = time.time()
                    conn.execute("UPDATE personal_jobs SET lease_until=?, updated=? WHERE id=? AND status='running' AND lease_owner=?",
                                 (now + 120, now, job_id, lease))
            except Exception:
                logger.exception("个性化任务心跳失败 job=%s", job_id)

    threading.Thread(target=heartbeat, daemon=True).start()
    try:
        data = json.loads(payload)
        words = list(dict.fromkeys(data.get("weak_words") or []))
        generate(device, date, words, data.get("learned_max_pos", 300), job_id=job_id, job_lease=lease)
        with sqlite3.connect(PERSONAL_DB, timeout=15) as conn:
            count = conn.execute("SELECT COUNT(*) FROM personal_job_sentences WHERE job_id=?", (job_id,)).fetchone()[0]
            status = "complete" if count == len(words) else "partial"
            conn.execute("UPDATE personal_jobs SET status=?, updated=?, lease_owner=NULL, lease_until=NULL WHERE id=? AND lease_owner=?",
                         (status, time.time(), job_id, lease))
    except Exception:
        logger.exception("个性化任务失败 job=%s", job_id)
        with sqlite3.connect(PERSONAL_DB, timeout=15) as conn:
            conn.execute("UPDATE personal_jobs SET status='failed', error=?, updated=?, lease_owner=NULL, lease_until=NULL WHERE id=? AND lease_owner=?",
                         ("生成失败，请重试", time.time(), job_id, lease))
    finally:
        stopped.set()


def start_personal_worker():
    global _PERSONAL_WORKER
    with _PERSONAL_WORKER_LOCK:
        if _PERSONAL_WORKER and _PERSONAL_WORKER.is_alive():
            return
        def work():
            while True:
                try:
                    job = claim_personal_job()
                    if job:
                        run_personal_job(job)
                        continue
                except Exception:
                    logger.exception("个性化任务队列异常")
                _PERSONAL_WAKE.wait(2)
                _PERSONAL_WAKE.clear()
        _PERSONAL_WORKER = threading.Thread(target=work, daemon=True, name="personal-job-worker")
        _PERSONAL_WORKER.start()


app = FastAPI(title="vocab-api", version="0.2.0", on_startup=[init_db, start_personal_worker])
mount_auth(app)


@app.middleware("http")
async def no_cache_account_state(request: Request, call_next):
    response = await call_next(request)
    path = request.url.path
    if path == "/api/v1/me/state" or path.startswith("/api/v1/me/state/") or path.startswith("/api/v1/me/fsrs-schedulers"):
        # Include validation and conflict responses: 410 is cacheable by
        # default and can mask a later generation or history change.
        response.headers["Cache-Control"] = "no-store"
    return response


@app.get("/", include_in_schema=False)
def index():
    import secrets
    nonce = secrets.token_urlsafe(24)
    content = (STATIC_DIR / "index.html").read_text(encoding="utf-8")
    content = content.replace("<script>", f'<script nonce="{nonce}">', 1)
    policy = (f"default-src 'self'; script-src 'self' 'nonce-{nonce}'; "
              "style-src 'self' 'unsafe-inline'; img-src 'self' data:; "
              "media-src 'self' blob:; connect-src 'self'; object-src 'none'; "
              "base-uri 'none'; frame-ancestors 'none'; form-action 'self'")
    return HTMLResponse(content, headers={"Content-Security-Policy": policy, "Cache-Control": "no-store",
                                         "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer"})


@app.post("/api/v1/auth/guest")
def issue_guest(request: Request = None):
    """Issue an opaque credential; only its digest is persisted server-side."""
    check_rate(request, "auth")
    credential = secrets.token_hex(32)
    digest = hashlib.sha256(credential.encode("ascii")).hexdigest()
    with sqlite3.connect(PERSONAL_DB, timeout=15) as conn:
        conn.execute("INSERT INTO guest_credentials(token_hash, created) VALUES(?, ?)", (digest, time.time()))
    return {"token": credential}


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
def personalize(body: PersonalizeIn, authorization: str = Header(default=""), x_guest_token: str = Header(default=""), request: Request = None):
    import uuid
    body.device = personal_owner(body.device, authorization, x_guest_token)
    if not body.sync:
        check_rate(request, "personalize")
        with sqlite3.connect(PERSONAL_DB) as conn:
            conn.execute("INSERT INTO requests(device, date, payload, created, processed) VALUES(?,?,?,?,0)",
                         (body.device, body.date, body.model_dump_json(), time.time()))
        return {"queued": True, "date": body.date}
    job_id = body.request_id or uuid.uuid4().hex
    payload = body.model_dump_json()
    now = time.time()
    with sqlite3.connect(PERSONAL_DB, timeout=15) as conn:
        conn.execute("BEGIN IMMEDIATE")
        existing = conn.execute("SELECT device, payload, status FROM personal_jobs WHERE id=?", (job_id,)).fetchone()
        if existing:
            if existing[0] != body.device or json.loads(existing[1]) != json.loads(payload):
                raise HTTPException(409, "任务标识已用于其他请求")
            status = existing[2]
        else:
            # 重复提交相同任务 ID 是轮询恢复，不消耗创建配额。
            check_rate(request, "personalize")
            conn.execute("INSERT INTO personal_jobs(id, device, date, payload, status, created, updated) VALUES(?,?,?,?,?,?,?)",
                         (job_id, body.device, body.date, payload, "queued", now, now))
            status = "queued"
    _PERSONAL_WAKE.set()
    return {"queued": True, "date": body.date, "background": True, "job_id": job_id, "status": status}


@app.get("/api/v1/personalized/job")
def personalized_job(job_id: str = Query(min_length=8, max_length=64),
                     device: str = Query(min_length=2, max_length=64),
                     authorization: str = Header(default=""), x_guest_token: str = Header(default="")):
    owner = personal_owner(device, authorization, x_guest_token)
    with sqlite3.connect(PERSONAL_DB) as conn:
        row = conn.execute("SELECT date, status, error, rowid FROM personal_jobs WHERE id=? AND device=?", (job_id, owner)).fetchone()
        if not row:
            raise HTTPException(404, "任务不存在")
        sentences = conn.execute("SELECT target, recall, text, zh FROM personal_job_sentences WHERE job_id=? ORDER BY created", (job_id,)).fetchall()
        newer = conn.execute("SELECT payload FROM personal_jobs WHERE device=? AND date=? AND rowid>? ORDER BY rowid", (owner, row[0], row[3])).fetchall()
        superseded = any(json.loads(p[0]).get("replace") for p in newer)
    return {"job_id": job_id, "date": row[0], "status": "superseded" if superseded else row[1], "error": row[2],
            "sentences": [{"target": t, "recall": r, "text": x, "zh": z or ""} for t, r, x, z in sentences]}


@app.get("/api/v1/personalized")
def personalized(device: str = Query(min_length=2, max_length=64),
                 date: str = Query(pattern=r"^\d{4}-\d{2}-\d{2}$"),
                 authorization: str = Header(default=""), x_guest_token: str = Header(default="")):
    device = personal_owner(device, authorization, x_guest_token)
    conn = sqlite3.connect(PERSONAL_DB)
    rows = conn.execute(
        "SELECT target, recall, text, zh FROM sentences WHERE device=? AND date=? ORDER BY created",
        (device, date)).fetchall()
    jobs = conn.execute("SELECT id, payload, status FROM personal_jobs WHERE device=? AND date=? ORDER BY created, rowid",
                        (device, date)).fetchall()
    last_replace = -1
    for i, (_, payload, _) in enumerate(jobs):
        if json.loads(payload).get("replace"):
            last_replace = i
    if last_replace >= 0:
        rows = []
    for job_id, _, _ in jobs[max(0, last_replace):]:
        rows.extend(conn.execute("SELECT target, recall, text, zh FROM personal_job_sentences WHERE job_id=? ORDER BY created", (job_id,)).fetchall())
    conn.close()
    return {"device": device, "date": date,
            "status": jobs[-1][2] if jobs else None,
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
            "level": LVL.get(wid), "examTags": EXAM.get(wid) or "",
            "senses": [{"pos": s["pos"], "text": s["text"]} for s in senses],
            "static": static_sentence(wid),
            "sentences": static_sentences(wid)}


@app.get("/api/v1/lexicon/at")
def lexicon_at(pos: int = Query(ge=1), n: int = Query(default=10, ge=1, le=30)):
    """按学习位置取 n 个词（含音标、义项、静态句）"""
    out = []
    cursor = pos
    while cursor <= len(seq) and cursor < pos + 40 and len(out) < n:
        wid = seq[cursor - 1]["id"]
        cursor += 1
        if PTAG.get(wid, "").startswith(CONTENT_POS):
            out.append(word_detail(wid))
    # The scanned range can contain no content words. Returning the scan cursor
    # lets clients advance without confusing that case with end of vocabulary.
    return {"from": pos, "words": out, "next_pos": cursor, "exhausted": cursor > len(seq)}


@app.get("/api/v1/lexicon/word")
def lexicon_word(word: str = Query(min_length=1, max_length=40)):
    """按词形取唯一词条，避免学习位置变化或非实义词占位导致错词/空释义。"""
    wid = WORD2ID.get(word.strip().lower())
    if not wid:
        raise HTTPException(status_code=404, detail="词条不存在")
    return word_detail(wid)


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


# ---------- 例句反馈：用户标记差句 → 隐藏并重生 ----------
@app.post("/api/v1/sentence/report")
def sentence_report(word: str = Query(min_length=1, max_length=40),
                    text: str = Query(min_length=1, max_length=300),
                    device: str = Query(default="", max_length=64),
                    authorization: str = Header(default=""), request: Request = None):
    check_rate(request, "report")
    # 单次“换一句”只是偏好反馈，不允许匿名用户改写公共词库或删除其他人的句子。
    uid = user_by_token(authorization)
    conn = sqlite3.connect(PERSONAL_DB)
    conn.execute("INSERT INTO sentence_reports(word, text, user_id, device, created) VALUES(?,?,?,?,?)",
                 (word, text, uid, device if not uid else None, time.time()))
    conn.commit()
    conn.close()
    return {"ok": True, "reported": 1}


# ---------- 复习 4 选 1 测试 ----------
def _gloss_parts(text):
    """把明确列出的义项分开并统一全角字符；不把语义相近视为已证实相同。"""
    import unicodedata
    result = set()
    for part in re.split(r"[,，;；、/]+", text or ""):
        normalized = re.sub(r"\s+", "", unicodedata.normalize("NFKC", part)).strip(".。:：")
        if normalized:
            result.add(normalized)
    return result


def _gloss_overlaps(left, right):
    for a in left:
        for b in right:
            if a == b or (min(len(a), len(b)) >= 2 and (a in b or b in a)):
                return True
    return False


_QUIZ_GLOSSES = {}
_QUIZ_MEANINGS = {}
for _sense in _lx.execute("SELECT wordId, pos, text, role FROM sense WHERE role IN ('core','ext') ORDER BY senseOrder"):
    _wid = _sense["wordId"]
    _QUIZ_MEANINGS.setdefault(_wid, set()).update(_gloss_parts(_sense["text"]))
    if _sense["role"] == "core" and _wid not in _QUIZ_GLOSSES:
        _QUIZ_GLOSSES[_wid] = ((_sense["pos"] or ""), re.split(r"[,，]", _sense["text"] or "")[0].strip())


def gloss_of(wid):
    """核心义项的首个词义（用于选项短文本）。"""
    return _QUIZ_GLOSSES.get(wid, ("", ""))


@app.get("/api/v1/quiz")
def quiz(pos: int = Query(ge=1), seed: int = 0, mode: str = Query(default="forward")):
    """4 选 1：正确词义 + 3 个同词性、邻近词频（±200 位）的干扰项。
    mode=reverse：反向回想——给中文词义选英文单词（更难，用于稳定度≥14 天的成熟卡）"""
    import random as _r
    if pos > len(seq):
        return {"options": []}
    wid = seq[pos - 1]["id"]
    p, correct = gloss_of(wid)
    if not correct:
        return {"word": ID2WORD[wid], "pos": pos, "options": []}
    pcls = (p or "n")[:1]
    rng = _r.Random(seed or time.time_ns())
    target_meanings = _QUIZ_MEANINGS.get(wid, _gloss_parts(correct))
    selected, selected_meanings, seen = [], [], {wid}
    # 稀有词性先扩大词频窗口，再搜索整个词库；每层仍优先使用邻近候选。
    for radius in (200, 600, 2000, len(seq)):
        candidates = []
        for i in range(max(1, pos - radius), min(len(seq), pos + radius) + 1):
            w2 = seq[i - 1]["id"]
            if w2 in seen:
                continue
            seen.add(w2)
            if not PTAG.get(w2, "").startswith(pcls):
                continue
            _, g = gloss_of(w2)
            parts = _QUIZ_MEANINGS.get(w2, set()) if mode == "reverse" else _gloss_parts(g)
            if not g or not parts or _gloss_overlaps(target_meanings, parts):
                continue
            candidates.append((ID2WORD[w2] if mode == "reverse" else g, parts))
        rng.shuffle(candidates)
        for text, parts in candidates:
            if text == ID2WORD[wid] or text in selected or any(_gloss_overlaps(parts, p) for p in selected_meanings):
                continue
            selected.append(text)
            selected_meanings.append(parts)
            if len(selected) == 3:
                break
        if len(selected) == 3:
            break
    # 极少数词性（例如感叹词）全库候选不足。使用其他词性兜底，
    # 正向题逐项标注实际词性，避免将候选误标为目标词性。
    fallback_pos = {}
    if len(selected) < 3:
        candidates = list(seq)
        rng.shuffle(candidates)
        for row in candidates:
            w2 = row["id"]
            p2, g = gloss_of(w2)
            if w2 == wid or (p2 or "n")[:1] == pcls:
                continue
            parts = _QUIZ_MEANINGS.get(w2, set()) if mode == "reverse" else _gloss_parts(g)
            text = ID2WORD[w2] if mode == "reverse" else g
            if not g or not parts or text == ID2WORD[wid] or text in selected:
                continue
            if _gloss_overlaps(target_meanings, parts) or any(_gloss_overlaps(parts, x) for x in selected_meanings):
                continue
            selected.append(text)
            selected_meanings.append(parts)
            fallback_pos[text] = (p2 or "n")[:1]
            if len(selected) == 3:
                break
    if len(selected) < 3:
        return {"word": ID2WORD[wid], "pos": pos, "mode": mode, "options": [], "reason": "insufficient_distractors"}
    answer = ID2WORD[wid] if mode == "reverse" else correct
    opts = [answer] + selected
    rng.shuffle(opts)
    if mode == "reverse":
        return {"word": answer, "pos": pos, "mode": "reverse", "prompt": f"{pcls}. {correct}",
                "options": [{"text": t, "ok": t == answer} for t in opts]}
    return {"word": ID2WORD[wid], "pos": pos,
            "options": [{"text": f"{fallback_pos.get(t, pcls)}. {t}", "ok": t == answer} for t in opts]}


# ---------- TTS（神经网络语音，带磁盘缓存；edge-tts 失败时 Kokoro 本地兜底）----------
TTS_DIR = DATA_DIR / "tts_cache"
TTS_DIR.mkdir(exist_ok=True)
TTS_VOICE = os.environ.get("TTS_VOICE", "en-US-AriaNeural")

# Kokoro 本地兜底（零第三方依赖：edge-tts 再挂时接管，见 tts_patch.py 注释）
_kokoro = None
_kokoro_lock = threading.Lock()


def kokoro_synth(text, out_path):
    """Kokoro 本地合成（af_heart 女声）→ ffmpeg 转 mp3。模型首次调用时加载。"""
    global _kokoro
    with _kokoro_lock:
        if _kokoro is None:
            from kokoro_onnx import Kokoro
            _kokoro = Kokoro(str(BASE_DIR / "tts_models" / "kokoro-v1.0.onnx"),
                             str(BASE_DIR / "tts_models" / "voices-v1.0.bin"))
        samples, sr = _kokoro.create(text, voice="af_heart", speed=1.0, lang="en-us")
    import soundfile as sf
    wav_path = str(out_path) + ".wav"
    sf.write(wav_path, samples, sr)
    import subprocess
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav_path,
                    "-codec:a", "libmp3lame", "-q:a", "4", str(out_path)], check=True)
    os.unlink(wav_path)


_TTS_LOCKS = {}
_TTS_LOCKS_GUARD = threading.Lock()


def ensure_tts(text, voice=None):
    """同文本串行生成、临时文件原子落盘，杜绝后台预产与首播请求互相误判。"""
    import asyncio as _aio, hashlib as _hl
    import edge_tts
    v = voice or TTS_VOICE
    key = _hl.sha1(f"{v}|{text}".encode()).hexdigest()[:16]
    f = TTS_DIR / f"{key}.mp3"
    with _TTS_LOCKS_GUARD:
        lock = _TTS_LOCKS.setdefault(key, threading.Lock())
    with lock:
        def _ok(path):
            return path.exists() and path.stat().st_size > 500
        if _ok(f):
            return True
        tmp = TTS_DIR / f"{key}.{threading.get_ident()}.tmp.mp3"
        try:
            for attempt in range(2):
                try:
                    _aio.run(edge_tts.Communicate(text, v).save(str(tmp)))
                    if _ok(tmp):
                        os.replace(tmp, f)
                        return True
                except Exception:
                    pass
                time.sleep(1 + attempt)
            try:
                kokoro_synth(text, tmp)
                if _ok(tmp):
                    os.replace(tmp, f)
                    return True
            except Exception as e:
                logger.warning("Kokoro 合成失败：%s", e)
            logger.warning("双路 TTS 均失败：%s", text[:60])
            return False
        finally:
            for path in (tmp, Path(str(tmp) + ".wav")):
                try:
                    path.unlink()
                except FileNotFoundError:
                    pass


@app.get("/api/v1/tts")
def tts(text: str = Query(min_length=1, max_length=200), v: str = "", request: Request = None):
    check_rate(request, "tts")
    import asyncio, hashlib
    import edge_tts
    voice = v if v in ("en-US-AriaNeural", "en-US-GuyNeural", "en-US-JennyNeural", "en-GB-SoniaNeural") else TTS_VOICE
    key = hashlib.sha1(f"{voice}|{text}".encode()).hexdigest()[:16]
    f = TTS_DIR / f"{key}.mp3"
    if not (f.exists() and f.stat().st_size > 500):
        ensure_tts(text, voice)   # edge-tts 重试 2 次 → Kokoro 兜底（保证成功率）
        if not (f.exists() and f.stat().st_size > 500):
            from fastapi import HTTPException
            raise HTTPException(503, "音频生成暂不可用，请稍后重试")
    return FileResponse(f, media_type="audio/mpeg")


# ---------- 例句按需生成（缺句时现场生成并永久缓存进词库）----------
_lxw = sqlite3.connect(LEXICON_DB, check_same_thread=False)


@app.get("/api/v1/sentence/ensure")
def sentence_ensure(word: str = Query(min_length=1, max_length=40), request: Request = None):
    check_rate(request, "sentence")
    wid = WORD2ID.get(word)
    if not wid:
        return {"word": word, "text": ""}
    s = static_sentences(wid)
    if s:
        return {"word": word, "text": s[0]["text"], "cached": True}
    pos = POS_OF[wid]
    cap = max(pos, 300)
    sense = core_sense(wid)
    prompt = (f"为背单词 App 写一条英语例句，要求：\n"
              f"1. 必须包含目标词 \"{word}\"（核心词义，只使用此义项：{sense}）\n"
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
            threading.Thread(target=ensure_tts, args=(cand,), daemon=True).start()   # 生成即产音频（后台，不阻塞响应）
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


# ---------- 巩固句：新词 × 近期薄弱词 共现句（缓存优先，后台生成）----------
_WEAVE_JOBS = set()
_WEAVE_LOCK = threading.Lock()


def _generate_weave_job(key, device, date, word, weak, cap):
    """后台补巩固句，绝不让学习卡同步等待多次 LLM+评审而触发网关 504。"""
    wid, rid = WORD2ID[word], WORD2ID[weak]
    try:
        t_sense, w_sense = core_sense(wid), core_sense(rid, 40)
        prompt = (f"为背单词 App 写一条英语例句。要求：\n"
                  f"1. 必须包含目标词 \"{word}\"（核心词义，只使用此义项：{t_sense}）\n"
                  f"2. 同时自然地包含复习词 \"{weak}\"（核心词义，只使用此义项：{w_sense}），这是学习者最近没记住的词\n"
                  f"3. 【真实使用场景】描述日常/工作/学习中的真实情境，两词自然融入同一情境；"
                  f"【地道】必须使用英语母语者日常真实会说的固定搭配和常用句型，严禁生造词组、中式英语或生硬拼凑\n"
                  f"4. 句长 6~16 个单词，语法正确、表达地道、有意义\n"
                  f"5. 其余用词为常见高频简单词\n"
                  f"6. 输出格式：英文句子 || 中文翻译，一行，不要任何解释")
        err = None
        for _ in range(3):
            try:
                out = llm(prompt + (f"\n\n上次失败原因：{err}，请修正。" if err else ""))
                cand_text, _, zh = out.partition("||")
                cand_text = cand_text.strip().strip('"')
            except Exception as e:
                err = f"API错误:{e}"
                time.sleep(1.5)
                continue
            err = validate_multi(cand_text, word, [weak], cap)
            if not err and quality_check(cand_text, word, weak) >= 4:
                conn = sqlite3.connect(PERSONAL_DB)
                conn.execute("INSERT INTO sentences VALUES(?,?,?,?,?,?,?)",
                             (device, date, word, weak, cand_text, time.time(), zh.strip()))
                conn.commit()
                conn.close()
                ensure_tts(cand_text)
                return
            time.sleep(0.2)
        logger.warning("巩固句生成未通过：device=%s word=%s weak=%s reason=%s", device, word, weak, err)
    finally:
        with _WEAVE_LOCK:
            _WEAVE_JOBS.discard(key)


@app.get("/api/v1/sentence/weave")
def sentence_weave(word: str = Query(min_length=1, max_length=40),
                   weak: str = Query(min_length=1, max_length=40),
                   cap: int = 0, device: str = "anon",
                   authorization: str = Header(default=""), x_guest_token: str = Header(default=""), request: Request = None):
    check_rate(request, "sentence")
    device = personal_owner(device, authorization, x_guest_token)
    wid, rid = WORD2ID.get(word), WORD2ID.get(weak)
    if not wid or not rid or wid == rid:
        return {"text": "", "source": "none"}
    cap = max(POS_OF[wid], 300, cap)
    norm = "REPLACE(REPLACE(REPLACE(wordIds,' ',''),'[',','),']',',')"
    cand = []
    for r in _lx.execute(
            f"SELECT text, genMethod, translation FROM sentence WHERE instr({norm}, ?) > 0 AND instr({norm}, ?) > 0 AND COALESCE(flag,'') != 'reported'",
            (f",{rid},", f",{wid},")).fetchall():
        cand.append((r[0], r[1], r[2]))
    if cand:
        cand.sort(key=lambda x: (0 if x[1] == "tatoeba" else 1, len(x[0])))
        return {"text": cand[0][0], "zh": cand[0][2] or "", "source": "pool"}
    date = today_str()
    conn = sqlite3.connect(PERSONAL_DB)
    row = conn.execute("SELECT text, zh FROM sentences WHERE device=? AND date=? AND target=? AND recall=? ORDER BY created DESC LIMIT 1",
                       (device, date, word, weak)).fetchone()
    conn.close()
    if row:
        return {"text": row[0], "zh": row[1] or "", "source": "generated"}
    key = (device, date, word, weak)
    with _WEAVE_LOCK:
        if key not in _WEAVE_JOBS:
            _WEAVE_JOBS.add(key)
            threading.Thread(target=_generate_weave_job, args=(key, device, date, word, weak, cap), daemon=True).start()
    return {"text": "", "source": "pending", "pending": True}


def today_str():
    from datetime import datetime as _dt
    return _dt.now().strftime("%Y-%m-%d")


# ---------- 新词三句套装：1 条句库句 + 2 条生成句（≥10 词）----------
TIER_RANGE = {1: (3, 10), 2: (10, 16), 3: (10, 20)}


@app.get("/api/v1/sentence/trio")
def sentence_trio(word: str = Query(min_length=1, max_length=40), weak: str = "", cap: int = 0, request: Request = None):
    check_rate(request, "sentence")
    wid = WORD2ID.get(word)
    if not wid:
        return {"word": word, "sentences": []}
    rows = _lx.execute(
        """SELECT text, tier, translation FROM sentence
           WHERE targetWordId=? AND (genMethod LIKE 'llm-%' OR genMethod='tatoeba')
             AND COALESCE(flag,'') != 'reported'
           ORDER BY CASE genMethod WHEN 'tatoeba' THEN 0 ELSE 1 END, id DESC""", (wid,)).fetchall()
    have = {}
    for r in rows:
        have.setdefault(r["tier"], (r["text"], r["translation"] or ""))
    if len(have) >= 3:
        return {"word": word, "sentences": [{"tier": t, "text": have[t][0], "zh": have[t][1]} for t in sorted(have)][:3]}
    pos = POS_OF[wid]
    cap = max(pos, 300, cap)  # 调用方可传入真实学习位置（召回词是用户已学的词）
    sense = core_sense(wid)
    weaks = [x for x in weak.split(",") if x]
    recall = None
    # 薄弱词按概率织入，而不是每个新词的基础句都强行带：
    # 词级确定性抽样约 40%（同一词结果稳定），命中时按目标词轮换薄弱词，兼顾覆盖率
    if weaks and (sum(ord(c) for c in word) + pos) % 100 < 40:
        recall = weaks[(sum(ord(c) for c in word) + pos) % len(weaks)]
    need = [t for t in (1, 2, 3) if t not in have]
    spec = []
    if 1 in need:
        spec.append(f"A: 基础句，3~10 个单词，简单句" + (f"，必须包含复习词 \"{recall}\"" if recall else ""))
    if 2 in need:
        spec.append("B: 进阶句，10~16 个单词，必须含一个从句（when/because/that/which/who 等）")
    if 3 in need:
        spec.append("C: 挑战句，10~20 个单词，含复合结构（从句/非谓语/介词短语组合）")
    prompt = (f"为背单词 App 的单词 \"{word}\"（核心词义，只使用此义项：{sense}）写例句，逐条输出：\n"
              + "\n".join(spec) +
              f"\n其他约束：除目标词和指定复习词外只用英语最常见的高频简单词（约前 {cap} 词范围）；"
              f"必须使用英语母语者日常真实会说的固定搭配和常用句型，严禁生造词组、中式英语或生硬拼凑；句子必须自然、地道、有意义。每行格式严格为 \"A: <英文句子> || <中文翻译>\"，"
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
            tw = WORD2ID.get(lex_lemma(t))
            if tw is None:
                return f"词库外:{t}"
            if POS_OF[tw] > cap_t and lex_lemma(t) not in (word, recall):
                return f"超范围:{t}"
            hit_t |= (lex_lemma(t) == word or t == word)
            hit_r |= recall is not None and lex_lemma(t) == recall
        if not hit_t:
            return "缺目标词"
        if tier == 1 and not hit_r:
            return "缺召回词"
        # 与个性化例句同一质量门：语法/搭配/语义/场景四项最低分 <4 则不落库，
        # 让上层用更自然的场景重试，避免"结构合法但不像人话"的句子进入缓存
        score = quality_check(text, word, recall if tier == 1 else None)
        if score < 4:
            return f"自然度评分{score}<4"
        sid = _lx.execute("SELECT id FROM sense WHERE wordId=? AND role='core'", (wid,)).fetchone()[0]
        _lxw.execute("""INSERT INTO sentence(text, translation, wordIds, senseId, targetWordId, recallIds, genMethod, flag, tier)
                        VALUES(?,?,?,?,?,?,?,?,?)""",
                     (text, zh, json.dumps([wid]), sid, wid,
                      json.dumps([WORD2ID.get(recall)] if recall and tier == 1 else []),
                      "llm-tier-v1", "on_demand", tier))
        have[tier] = (text, zh)
        threading.Thread(target=ensure_tts, args=(text,), daemon=True).start()   # 生成即产音频（后台，不阻塞响应）
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
        single = (f"为背单词 App 的单词 \"{word}\"（核心词义，只使用此义项：{sense}）写一条英语例句：{TIER_DESC[tier]}。"
                  + (f"必须包含复习词 \"{recall}\"。" if recall and tier == 1 else "")
                  + f"其他词用常见高频简单词。必须使用英语母语者日常真实会说的固定搭配，严禁生造词组或中式英语；句子自然地道。输出格式：英文句子 || 中文翻译，一行，不要其他内容。")
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
_FSRS_USER_CACHE = {}


def fsrs_for_user(uid, account_id):
    """按用户加载 FSRS 优化参数；无优化文件/游客使用默认参数。
    文件 mtime 变化时自动重载，无需重启服务。"""
    if not uid:
        return FSRS
    if not account_id:
        raise ValueError("account identity required for optimized FSRS parameters")
    path = DATA_DIR / f"fsrs_optimal_account_{account_id}.json"
    if not path.exists():
        # 只有经迁移记录证明原账号归属时才读取旧的 UID 参数文件。
        from app import auth as auth_module
        with sqlite3.connect(auth_module.USERS_DB, timeout=15) as conn:
            binding = conn.execute("SELECT account_id FROM legacy_state_bindings WHERE user_id=?", (uid,)).fetchone()
        if binding and binding[0] == account_id:
            path = DATA_DIR / f"fsrs_optimal_uid{uid}.json"
    try:
        mtime = path.stat().st_mtime
    except FileNotFoundError:
        return FSRS
    cached = _FSRS_USER_CACHE.get(account_id)
    if cached and cached[0] == (path, mtime):
        return cached[1]
    data = json.loads(path.read_text())
    scheduler = _FsrsScheduler(parameters=data["parameters"], desired_retention=data.get("desired_retention", 0.9))
    _FSRS_USER_CACHE[account_id] = ((path, mtime), scheduler)
    return scheduler


def fsrs_scheduler_config(scheduler):
    """固定算法实现版本和所有会影响调度的参数。"""
    from importlib.metadata import version
    return normalize_fsrs_config({"library": version("fsrs"), "parameters": list(scheduler.parameters),
            "desired_retention": scheduler.desired_retention,
            "learning_steps": [x.total_seconds() for x in scheduler.learning_steps],
            "relearning_steps": [x.total_seconds() for x in scheduler.relearning_steps],
            "maximum_interval": scheduler.maximum_interval})


def fsrs_scheduler_key(scheduler):
    return fsrs_config_key(fsrs_scheduler_config(scheduler))


def fsrs_scheduler_version(uid, requested_key, account_id=None):
    """保存当前参数快照并按账户恢复旧版本；不可证明时拒绝重放。"""
    from datetime import timedelta
    from importlib.metadata import version
    current = fsrs_for_user(uid, account_id)
    config = fsrs_scheduler_config(current)
    current_key = fsrs_config_key(config)
    # 旧客户端可能已持有默认版本，首次升级时为该账户也保存默认快照。
    default_config = fsrs_scheduler_config(FSRS)
    default_key = fsrs_config_key(default_config)
    if uid and not account_id:
        raise ValueError("account identity required for scheduler history")
    owner = f"account:{account_id}" if uid else "guest:default"
    try:
        with sqlite3.connect(PERSONAL_DB, timeout=15) as conn:
            existing = {row[0] for row in conn.execute(
                "SELECT scheduler_key FROM fsrs_scheduler_versions WHERE owner=? AND scheduler_key IN (?,?)",
                (owner, current_key, default_key))}
            for key, item in ((current_key, config), (default_key, default_config)):
                if key not in existing:
                    encoded = json.dumps(item, sort_keys=True, separators=(",", ":"))
                    conn.execute("INSERT OR IGNORE INTO fsrs_scheduler_versions(owner, scheduler_key, config_json, created) VALUES(?,?,?,?)",
                                 (owner, key, encoded, time.time()))
                    existing.add(key)
            if not requested_key or requested_key == current_key:
                return current, current_key
            row = conn.execute("SELECT config_json FROM fsrs_scheduler_versions WHERE owner=? AND scheduler_key=?",
                               (owner, requested_key)).fetchone()
    except sqlite3.Error:
        logger.exception("保存或读取 FSRS 参数版本失败")
        raise HTTPException(503, "无法读取 FSRS 参数历史，请保留本地评分并稍后重试")
    from_state = False
    if not row and uid:
        # 导出的学习状态可以携带指纹校验过的版本；新服务器/新账号恢复后按该账号读取。
        from app import auth as auth_module
        try:
            with sqlite3.connect(auth_module.USERS_DB, timeout=15) as user_conn:
                state_row = user_conn.execute("SELECT state_json FROM account_state WHERE account_id=?", (account_id,)).fetchone()
            state = json.loads(state_row[0]) if state_row else {}
            snapshot = (state.get("fsrsSchedulers") or {}).get(requested_key)
            if snapshot is not None:
                row = (json.dumps(snapshot, sort_keys=True, separators=(",", ":")),)
                from_state = True
        except (sqlite3.Error, ValueError, TypeError, AttributeError):
            logger.exception("读取学习状态中的 FSRS 参数失败")
            raise HTTPException(503, "无法读取 FSRS 参数备份，请保留本地评分并稍后重试")
    if not row:
        raise HTTPException(409, "FSRS 参数版本不可用，无法安全重放旧评分，请先导出进度")
    try:
        old = json.loads(row[0])
        if old.get("library") != version("fsrs") or fsrs_config_key(old) != requested_key:
            raise ValueError("algorithm version or checksum mismatch")
        scheduler = _FsrsScheduler(parameters=old["parameters"], desired_retention=old["desired_retention"],
            learning_steps=tuple(timedelta(seconds=x) for x in old["learning_steps"]),
            relearning_steps=tuple(timedelta(seconds=x) for x in old["relearning_steps"]),
            maximum_interval=old["maximum_interval"])
        if fsrs_scheduler_key(scheduler) != requested_key:
            raise ValueError("scheduler reconstruction mismatch")
        if from_state:
            with sqlite3.connect(PERSONAL_DB, timeout=15) as conn:
                conn.execute("INSERT OR IGNORE INTO fsrs_scheduler_versions(owner, scheduler_key, config_json, created) VALUES(?,?,?,?)",
                             (owner, requested_key, json.dumps(normalize_fsrs_config(old), sort_keys=True, separators=(",", ":")), time.time()))
        return scheduler, requested_key
    except sqlite3.Error:
        logger.exception("恢复 FSRS 参数快照失败")
        raise HTTPException(503, "无法保存 FSRS 参数备份，请保留本地评分并稍后重试")
    except (AttributeError, KeyError, TypeError, ValueError, ArithmeticError, OverflowError):
        logger.exception("FSRS 参数历史无法验证 owner=%s key=%s", owner, requested_key)
        raise HTTPException(409, "FSRS 算法版本不可用，无法安全重放旧评分，请先导出进度")


class FsrsIn(BaseModel):
    is_new: bool = False
    state: int = 1          # 1 Learning / 2 Review / 3 Relearning
    stability: float = 0
    difficulty: float = 0
    due: str | None = None
    rating: int = 3         # 1 Again / 2 Hard / 3 Good / 4 Easy
    step: int | None = None         # Learning/Relearning 的当前步数；必须随卡状态往返，否则永远停在第 0 步
    now: str | None = None          # 模拟时钟（测试用；缺省用真实时间）
    last_review: str | None = None  # 上次复习时间（模拟时钟配套；生产也必须传）
    deterministic: bool = False    # 客户端重放时禁用随机扰动，保证重试结果相同
    scheduler_key: str | None = None


@app.post("/api/v1/fsrs/review")
def fsrs_review(body: FsrsIn, authorization: str = Header(default="")):
    identity = identity_by_token(authorization)
    if authorization and not identity:
        raise HTTPException(401, "未登录或登录已过期")
    uid, account_id = identity if identity else (None, None)
    scheduler, scheduler_key = fsrs_scheduler_version(uid, body.scheduler_key, account_id)
    if body.deterministic:
        scheduler = _FsrsScheduler(parameters=scheduler.parameters,
                                   desired_retention=scheduler.desired_retention,
                                   learning_steps=scheduler.learning_steps,
                                   relearning_steps=scheduler.relearning_steps,
                                   maximum_interval=scheduler.maximum_interval,
                                   enable_fuzzing=False)
    now = None
    if body.now:
        now = datetime.fromisoformat(body.now.replace("Z", "+00:00"))
        if now.tzinfo is None:
            now = now.replace(tzinfo=timezone.utc)
    c = _FsrsCard()
    if not body.is_new:
        c.state = _FsrsState(body.state)
        c.stability = body.stability
        c.difficulty = body.difficulty
        # Learning/Relearning 必须恢复 step；老客户端缺省按第 0 步兼容
        c.step = body.step if body.step is not None else (0 if body.state in (1, 3) else None)
        if body.due:
            d = datetime.fromisoformat(body.due.replace("Z", "+00:00"))
            c.due = d.replace(tzinfo=timezone.utc) if d.tzinfo is None else d
        if body.last_review:
            lr = datetime.fromisoformat(body.last_review.replace("Z", "+00:00"))
            c.last_review = lr.replace(tzinfo=timezone.utc) if lr.tzinfo is None else lr
            # 客户端日志只有日期精度，同日多次复习/时区差可能出现未来时间：钳到 now，防负经过天数
            review_time = now or datetime.now(timezone.utc)
            if c.last_review > review_time:
                c.last_review = review_time
        else:
            c.last_review = now or datetime.now(timezone.utc)
    c, log = scheduler.review_card(c, _FsrsRating(body.rating), review_datetime=now)
    return {"state": c.state.value, "scheduler_key": scheduler_key, "scheduler_config": fsrs_scheduler_config(scheduler),
            "stability": round(c.stability, 3),
            "difficulty": round(c.difficulty, 3),
            "due": c.due.isoformat(),
            "step": c.step,
            "last_review": c.last_review.isoformat() if c.last_review else None,
            "scheduled_days": getattr(log, "scheduled_days", None)}
