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
        conn.execute("""INSERT INTO user_state(user_id, state_json, updated_at) VALUES(?,?,?)
                        ON CONFLICT(user_id) DO UPDATE SET state_json=excluded.state_json,
                        updated_at=excluded.updated_at""",
                     (uid, _j.dumps(body, ensure_ascii=False), time.time()))
        conn.commit()
        conn.close()
        return {"ok": True}
