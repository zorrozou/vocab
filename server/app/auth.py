# -*- coding: utf-8 -*-
"""多用户账号体系与进度同步（vocab-api 扩展）
users.db：users / tokens / user_state
密码：PBKDF2-SHA256 10 万次迭代；token：32 字节随机，仅存哈希
"""
import hashlib, os, re, secrets, sqlite3, time
from pathlib import Path

from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

BASE_DIR = Path(__file__).resolve().parent.parent
USERS_DB = BASE_DIR / "data" / "users.db"

USERNAME_RE = re.compile(r"^[A-Za-z0-9_]{3,20}$")  # 用户名仅 ASCII
TOKEN_TTL = 30 * 86400


def init_users():
    conn = sqlite3.connect(USERS_DB)
    conn.execute("""CREATE TABLE IF NOT EXISTS users(
        id INTEGER PRIMARY KEY, username TEXT UNIQUE COLLATE NOCASE,
        nickname TEXT, password_hash TEXT, salt TEXT,
        created_at REAL, last_login_at REAL)""")
    conn.execute("""CREATE TABLE IF NOT EXISTS tokens(
        token_hash TEXT PRIMARY KEY, user_id INTEGER, expires_at REAL, revoked INTEGER DEFAULT 0)""")
    conn.execute("""CREATE TABLE IF NOT EXISTS user_state(
        user_id INTEGER PRIMARY KEY, state_json TEXT, updated_at REAL)""")
    conn.commit()
    conn.close()


def hash_pwd(pwd, salt):
    return hashlib.pbkdf2_hmac("sha256", pwd.encode(), bytes.fromhex(salt), 100_000).hex()


def make_token(conn, uid):
    token = secrets.token_urlsafe(32)
    conn.execute("INSERT INTO tokens VALUES(?,?,?,0)",
                 (hashlib.sha256(token.encode()).hexdigest(), uid, time.time() + TOKEN_TTL))
    conn.commit()
    return token


def user_by_token(authorization):
    """从 Authorization: Bearer 头解析用户；无/无效 → None"""
    if not authorization or not authorization.startswith("Bearer "):
        return None
    th = hashlib.sha256(authorization[7:].encode()).hexdigest()
    conn = sqlite3.connect(USERS_DB)
    row = conn.execute(
        "SELECT user_id FROM tokens WHERE token_hash=? AND revoked=0 AND expires_at>?",
        (th, time.time())).fetchone()
    conn.close()
    return row[0] if row else None


class RegisterIn(BaseModel):
    username: str = Field(min_length=3, max_length=20)
    password: str = Field(min_length=8, max_length=64)
    nickname: str = Field(default="", max_length=30)


class LoginIn(BaseModel):
    username: str
    password: str


def _log_key(entry):
    import json as _j
    return _j.dumps(entry, ensure_ascii=False, sort_keys=True)


def merge_learning_states(old, new):
    """多设备学习状态字段级合并，避免旧设备整包覆盖新进度。

    规则：
    - log：精确事件计数取最大值（同一事件不重复，真实重复学习不丢失）
    - cards：按该词最近学习日期选较新的卡；同日取活动较多的一侧，平局取新写入
    - posterior/probeCount：取累计探测证据更多的一份
    - pointer：同一 frontier 只前进；frontier 变化视为重新定级，接受新游标
    - pendingNew/personalized：按词合并；settings 取新写入的用户意图
    """
    if not old:
        return new
    if not new:
        return old
    import json as _j
    from collections import Counter

    out = dict(new)
    old_logs = old.get("log") or []
    new_logs = new.get("log") or []
    ca, cb = Counter(_log_key(x) for x in old_logs), Counter(_log_key(x) for x in new_logs)
    merged_logs = []
    for key in ca.keys() | cb.keys():
        entry = _j.loads(key)
        merged_logs.extend([entry] * max(ca[key], cb[key]))
    merged_logs.sort(key=lambda x: (x.get("d", ""), x.get("word", ""), x.get("kind", ""), x.get("rating", 0)))
    out["log"] = merged_logs

    # 每个词在两边的最近学习日/活动次数，用于选卡
    def activity(logs):
        result = {}
        for x in logs:
            if x.get("kind") not in ("learn", "review"):
                continue
            w = x.get("word")
            if not w:
                continue
            day = x.get("d", "")
            prev = result.get(w)
            if prev is None or day > prev[0]:
                result[w] = (day, 1)
            elif day == prev[0]:
                result[w] = (day, prev[1] + 1)
        return result

    ao, an = activity(old_logs), activity(new_logs)
    old_cards = old.get("cards") or {}
    new_cards = new.get("cards") or {}
    cards = {}
    for w in old_cards.keys() | new_cards.keys():
        oc, nc = old_cards.get(w), new_cards.get(w)
        if oc is None:
            cards[w] = nc
        elif nc is None:
            cards[w] = oc
        else:
            oa, na = ao.get(w, ("", 0)), an.get(w, ("", 0))
            if oa[0] > na[0] or (oa[0] == na[0] and oa[1] > na[1]):
                cards[w] = oc
            else:
                cards[w] = nc
    out["cards"] = cards

    # 后验不能取平均：保留证据更多的一侧。
    # 但重新定级是显式重置：placementResetAt 更新（或新客户端清空 posterior/probeCount）时，
    # 必须接受新后验，绝不能用"旧探测次数更多"把重测撤销。
    old_reset = float(old.get("placementResetAt") or 0)
    new_reset = float(new.get("placementResetAt") or 0)
    explicit_reset = (new_reset > old_reset or
                      (new.get("posterior") is None and int(new.get("probeCount", 0)) == 0 and old.get("posterior") is not None))
    if explicit_reset:
        out["posterior"] = new.get("posterior")
        out["probeCount"] = int(new.get("probeCount", 0))
        out["track"] = new.get("track")
        if new_reset <= old_reset:
            out["placementResetAt"] = time.time()
    elif int(old.get("probeCount", 0)) > int(new.get("probeCount", 0)):
        out["posterior"] = old.get("posterior")
        out["probeCount"] = old.get("probeCount", 0)
    else:
        out["posterior"] = new.get("posterior")
        out["probeCount"] = new.get("probeCount", 0)
    out["placementResetAt"] = max(old_reset, float(out.get("placementResetAt") or 0))

    if old.get("frontier") == new.get("frontier"):
        out["pointer"] = max(int(old.get("pointer", 1)), int(new.get("pointer", 1)))
    else:
        out["frontier"] = new.get("frontier")
        out["pointer"] = new.get("pointer", 1)
    out["calibrated"] = bool(old.get("calibrated") or new.get("calibrated"))

    pending = list(old.get("pendingNew") or [])
    seen = {x.get("word") for x in pending}
    pending.extend(x for x in (new.get("pendingNew") or []) if x.get("word") not in seen)
    out["pendingNew"] = pending

    personal = dict(old.get("personalized") or {})
    personal.update(new.get("personalized") or {})
    out["personalized"] = personal

    # 日期型字段取较新；对应计数/说明跟随同一天的一侧
    for field in ("lastDay", "quizDay", "weaveDay", "personalizedDay"):
        if str(old.get(field) or "") > str(new.get(field) or ""):
            out[field] = old.get(field)
            for linked in ("weaveCount", "personalizedWeak"):
                if field == "weaveDay" and linked == "weaveCount" or field == "personalizedDay" and linked == "personalizedWeak":
                    out[linked] = old.get(linked)
    if not explicit_reset and str((old.get("track") or {}).get("evalDay") or "") > str((new.get("track") or {}).get("evalDay") or ""):
        out["track"] = old.get("track")
    out["streak"] = max(int(old.get("streak", 0)), int(new.get("streak", 0)))
    out["v"] = max(int(old.get("v", 1)), int(new.get("v", 1)))
    return out


def mount_auth(app: FastAPI):
    init_users()

    @app.post("/api/v1/auth/register")
    def register(body: RegisterIn):
        if not USERNAME_RE.match(body.username):
            raise HTTPException(400, "用户名仅允许字母/数字/下划线，3~20 位")
        conn = sqlite3.connect(USERS_DB)
        if conn.execute("SELECT 1 FROM users WHERE username=?", (body.username,)).fetchone():
            conn.close()
            raise HTTPException(409, "用户名已被占用")
        salt = secrets.token_hex(16)
        cur = conn.execute(
            "INSERT INTO users(username, nickname, password_hash, salt, created_at, last_login_at) VALUES(?,?,?,?,?,?)",
            (body.username, body.nickname or body.username, hash_pwd(body.password, salt), salt,
             time.time(), time.time()))
        uid = cur.lastrowid
        token = make_token(conn, uid)
        conn.close()
        return {"token": token, "user": {"id": uid, "username": body.username,
                                         "nickname": body.nickname or body.username}}

    @app.post("/api/v1/auth/login")
    def login(body: LoginIn):
        conn = sqlite3.connect(USERS_DB)
        row = conn.execute("SELECT id, nickname, password_hash, salt FROM users WHERE username=?",
                           (body.username,)).fetchone()
        if not row or hash_pwd(body.password, row[3]) != row[2]:
            conn.close()
            raise HTTPException(401, "用户名或密码错误")
        conn.execute("UPDATE users SET last_login_at=? WHERE id=?", (time.time(), row[0]))
        token = make_token(conn, row[0])
        conn.close()
        return {"token": token, "user": {"id": row[0], "username": body.username, "nickname": row[1]}}

    @app.post("/api/v1/auth/logout")
    def logout(authorization: str = Header(default="")):
        if authorization.startswith("Bearer "):
            th = hashlib.sha256(authorization[7:].encode()).hexdigest()
            conn = sqlite3.connect(USERS_DB)
            conn.execute("UPDATE tokens SET revoked=1 WHERE token_hash=?", (th,))
            conn.commit()
            conn.close()
        return {"ok": True}

    @app.get("/api/v1/me/state")
    def get_state(authorization: str = Header(default="")):
        uid = user_by_token(authorization)
        if not uid:
            raise HTTPException(401, "未登录或登录已过期")
        conn = sqlite3.connect(USERS_DB)
        row = conn.execute("SELECT state_json, updated_at FROM user_state WHERE user_id=?",
                           (uid,)).fetchone()
        conn.close()
        if not row:
            return {"state": None}
        import json as _j
        return {"state": _j.loads(row[0]), "updated_at": row[1]}

    @app.put("/api/v1/me/state")
    def put_state(body: dict, authorization: str = Header(default="")):
        uid = user_by_token(authorization)
        if not uid:
            raise HTTPException(401, "未登录或登录已过期")
        import json as _j
        conn = sqlite3.connect(USERS_DB)
        # 多设备字段级合并：不再让旧设备用整包覆盖另一台设备已经产生的学习记录
        row = conn.execute("SELECT state_json FROM user_state WHERE user_id=?", (uid,)).fetchone()
        if row:
            try:
                body = merge_learning_states(_j.loads(row[0]), body)
            except Exception:
                pass   # 存档异常不阻塞保存
        conn.execute("""INSERT INTO user_state(user_id, state_json, updated_at) VALUES(?,?,?)
                        ON CONFLICT(user_id) DO UPDATE SET state_json=excluded.state_json,
                        updated_at=excluded.updated_at""",
                     (uid, _j.dumps(body, ensure_ascii=False), time.time()))
        conn.commit()
        conn.close()
        return {"ok": True}
