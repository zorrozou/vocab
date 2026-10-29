# -*- coding: utf-8 -*-
"""多用户账号体系与进度同步（vocab-api 扩展）
users.db：users / tokens / user_state
密码：Argon2id；旧 PBKDF2 密码在成功登录时升级；token 仅存哈希
"""
import base64, copy, hashlib, json, os, re, secrets, sqlite3, threading, time
from contextlib import contextmanager
from argon2 import PasswordHasher, extract_parameters
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError
from argon2.low_level import Type
from pathlib import Path

from fastapi import FastAPI, Header, HTTPException, Query, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from app.posterior_evidence import anchor as anchor_posterior, validate as validate_posterior, merge as merge_posterior, replay as replay_posterior, canonicalize as canonicalize_posterior
from app.streak_evidence import anchor as anchor_streak, validate as validate_streak, merge as merge_streak, calculate as calculate_streak
from app.limits import check_rate
from app import daily_study, delta_staging, state_segments, state_verification_cache
from app.fsrs_config import fsrs_config_key, normalize_fsrs_config
from app.state_changes import PAGE_BYTES as CHANGE_PAGE_BYTES, MAX_STAGED_OPERATIONS, apply_upload_ops, record_change, validate_upload_ops

BASE_DIR = Path(__file__).resolve().parent.parent
USERS_DB = BASE_DIR / "data" / "users.db"

USERNAME_RE = re.compile(r"^[A-Za-z0-9_]{3,20}$")  # 用户名仅 ASCII
TOKEN_TTL = 30 * 86400
MAX_STATE_BYTES = 8 * 1024 * 1024
# Experimental, explicitly enabled incremental path. Keep below the snapshot
# envelope limit and retain the legacy 8 MiB fence on every old endpoint.
MAX_LARGE_DELTA_STATE_BYTES = 14 * 1024 * 1024
SNAPSHOT_PAGE_BYTES = 128 * 1024
SNAPSHOT_MAX_BYTES = 16 * 1024 * 1024
SNAPSHOT_GLOBAL_BYTES = 128 * 1024 * 1024
SNAPSHOT_TTL_SECONDS = 600
SNAPSHOT_MAX_PER_ACCOUNT = 3
SNAPSHOT_MAX_KEYS_PER_ACCOUNT = 64
DELTA_MAX_BYTES = 2 * 1024 * 1024
DELTA_MAX_RECEIPTS = 256
DELTA_RECEIPT_TTL = 7 * 86400


def init_users():
    conn = sqlite3.connect(USERS_DB, timeout=15)
    conn.execute("BEGIN IMMEDIATE")
    daily_study.initialize(conn)
    conn.execute("""CREATE TABLE IF NOT EXISTS users(
        id INTEGER PRIMARY KEY, username TEXT UNIQUE COLLATE NOCASE,
        nickname TEXT, password_hash TEXT, salt TEXT,
        created_at REAL, last_login_at REAL)""")
    conn.execute("""CREATE TABLE IF NOT EXISTS tokens(
        token_hash TEXT PRIMARY KEY, user_id INTEGER, expires_at REAL, revoked INTEGER DEFAULT 0)""")
    conn.execute("""CREATE TABLE IF NOT EXISTS user_state(
        user_id INTEGER PRIMARY KEY, state_json TEXT, updated_at REAL)""")
    conn.execute("""CREATE TABLE IF NOT EXISTS user_state_backups(
        id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL,
        state_json TEXT NOT NULL, created_at REAL NOT NULL, reason TEXT NOT NULL)""")
    conn.execute("CREATE INDEX IF NOT EXISTS user_state_backups_owner ON user_state_backups(user_id, id)")
    # 旧库迁移在同一个写事务中完成，防止多个服务进程给同一账号分配不同标识。
    if "account_id" not in {row[1] for row in conn.execute("PRAGMA table_info(users)")}:
        conn.execute("ALTER TABLE users ADD COLUMN account_id TEXT")
    if "legacy_personal" not in {row[1] for row in conn.execute("PRAGMA table_info(users)")}:
        conn.execute("ALTER TABLE users ADD COLUMN legacy_personal INTEGER NOT NULL DEFAULT 0")
        # 只有升级时已经存在、尚无新身份的账号可以认领旧的 UID 命名空间。
        conn.execute("UPDATE users SET legacy_personal=1 WHERE account_id IS NULL")
    migrating_tokens = "account_id" not in {row[1] for row in conn.execute("PRAGMA table_info(tokens)")}
    if migrating_tokens:
        conn.execute("ALTER TABLE tokens ADD COLUMN account_id TEXT")
    for (uid,) in conn.execute("SELECT id FROM users WHERE account_id IS NULL").fetchall():
        conn.execute("UPDATE users SET account_id=? WHERE id=?", (secrets.token_hex(16), uid))
    conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS users_account_id ON users(account_id)")
    conn.execute("""CREATE TABLE IF NOT EXISTS account_state(
        account_id TEXT PRIMARY KEY, state_json TEXT NOT NULL, updated_at REAL NOT NULL,
        state_revision INTEGER NOT NULL DEFAULT 1)""")
    # Existing account rows are one immutable initial revision. The migration is
    # inside the same write transaction as the other identity migrations.
    if "state_revision" not in {row[1] for row in conn.execute("PRAGMA table_info(account_state)")}:
        conn.execute("ALTER TABLE account_state ADD COLUMN state_revision INTEGER NOT NULL DEFAULT 1")
    if "segments_version" not in {row[1] for row in conn.execute("PRAGMA table_info(account_state)")}:
        conn.execute("ALTER TABLE account_state ADD COLUMN segments_version INTEGER NOT NULL DEFAULT 0")
    state_segments.initialize(conn)
    conn.execute("""CREATE TABLE IF NOT EXISTS account_state_backups(
        id INTEGER PRIMARY KEY AUTOINCREMENT, account_id TEXT NOT NULL,
        state_json TEXT NOT NULL, created_at REAL NOT NULL, reason TEXT NOT NULL)""")
    conn.execute("CREATE INDEX IF NOT EXISTS account_state_backups_owner ON account_state_backups(account_id, id)")
    conn.execute("""CREATE TABLE IF NOT EXISTS account_state_snapshots(
        snapshot_id TEXT PRIMARY KEY, account_id TEXT NOT NULL, state_revision INTEGER NOT NULL,
        restore_epoch INTEGER NOT NULL, payload BLOB NOT NULL, digest TEXT NOT NULL,
        created_at REAL NOT NULL, expires_at REAL NOT NULL)""")
    if "request_key" not in {row[1] for row in conn.execute("PRAGMA table_info(account_state_snapshots)")}:
        conn.execute("ALTER TABLE account_state_snapshots ADD COLUMN request_key TEXT")
    if "retired" not in {row[1] for row in conn.execute("PRAGMA table_info(account_state_snapshots)")}:
        conn.execute("ALTER TABLE account_state_snapshots ADD COLUMN retired INTEGER NOT NULL DEFAULT 0")
    if "representation" not in {row[1] for row in conn.execute("PRAGMA table_info(account_state_snapshots)")}:
        conn.execute("ALTER TABLE account_state_snapshots ADD COLUMN representation TEXT NOT NULL DEFAULT 'enriched'")
    conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS account_state_snapshots_request ON account_state_snapshots(account_id, request_key) WHERE request_key IS NOT NULL")
    conn.execute("CREATE INDEX IF NOT EXISTS account_state_snapshots_owner ON account_state_snapshots(account_id, expires_at)")
    conn.execute("CREATE INDEX IF NOT EXISTS account_state_snapshots_expiry ON account_state_snapshots(expires_at)")
    conn.execute("""CREATE TABLE IF NOT EXISTS account_state_changes(
        account_id TEXT NOT NULL, revision INTEGER NOT NULL, base_revision INTEGER NOT NULL,
        restore_epoch INTEGER NOT NULL, reset INTEGER NOT NULL, payload BLOB NOT NULL,
        digest TEXT NOT NULL, created_at REAL NOT NULL, PRIMARY KEY(account_id, revision))""")
    conn.execute("CREATE INDEX IF NOT EXISTS account_state_changes_age ON account_state_changes(created_at)")
    conn.execute("""CREATE TABLE IF NOT EXISTS account_state_change_compact(
        account_id TEXT NOT NULL, revision INTEGER NOT NULL, payload BLOB NOT NULL,
        digest TEXT NOT NULL, PRIMARY KEY(account_id, revision))""")
    conn.execute("""CREATE TRIGGER IF NOT EXISTS account_state_changes_compact_delete
        AFTER DELETE ON account_state_changes BEGIN
        DELETE FROM account_state_change_compact WHERE account_id=OLD.account_id AND revision=OLD.revision;
        END""")
    conn.execute("""CREATE TABLE IF NOT EXISTS account_state_batches(
        account_id TEXT NOT NULL, batch_id TEXT NOT NULL, request_hash TEXT NOT NULL,
        generation TEXT NOT NULL, base_revision INTEGER NOT NULL, revision INTEGER NOT NULL,
        restore_epoch INTEGER NOT NULL, updated_at REAL NOT NULL, created_at REAL NOT NULL,
        PRIMARY KEY(account_id,batch_id))""")
    conn.execute("CREATE INDEX IF NOT EXISTS account_state_batches_age ON account_state_batches(created_at)")
    conn.execute("""CREATE TABLE IF NOT EXISTS account_restore_receipts(
        account_id TEXT NOT NULL, batch_id TEXT NOT NULL, request_hash TEXT NOT NULL,
        generation TEXT NOT NULL, base_revision INTEGER NOT NULL, revision INTEGER NOT NULL,
        old_epoch INTEGER NOT NULL, new_epoch INTEGER NOT NULL, updated_at REAL NOT NULL, created_at REAL NOT NULL,
        payload_sha256 TEXT NOT NULL,
        PRIMARY KEY(account_id,batch_id))""")
    if "payload_sha256" not in {row[1] for row in conn.execute("PRAGMA table_info(account_restore_receipts)")}:
        conn.execute("ALTER TABLE account_restore_receipts ADD COLUMN payload_sha256 TEXT NOT NULL DEFAULT ''")
    conn.execute("CREATE INDEX IF NOT EXISTS account_restore_receipts_age ON account_restore_receipts(created_at)")
    conn.execute("""CREATE TABLE IF NOT EXISTS account_guarded_restore_receipts(
        account_id TEXT NOT NULL, batch_id TEXT NOT NULL, request_hash TEXT NOT NULL,
        generation TEXT NOT NULL, revision INTEGER NOT NULL, updated_at REAL NOT NULL,
        state_json TEXT NOT NULL, state_sha256 TEXT NOT NULL, created_at REAL NOT NULL, PRIMARY KEY(account_id,batch_id))""")
    if "state_sha256" not in {row[1] for row in conn.execute("PRAGMA table_info(account_guarded_restore_receipts)")}:
        conn.execute("ALTER TABLE account_guarded_restore_receipts ADD COLUMN state_sha256 TEXT NOT NULL DEFAULT ''")
    conn.execute("CREATE INDEX IF NOT EXISTS account_guarded_restore_receipts_age ON account_guarded_restore_receipts(created_at)")
    conn.execute("""CREATE TABLE IF NOT EXISTS account_checkpoint_receipts(
        account_id TEXT NOT NULL, batch_id TEXT NOT NULL, request_hash TEXT NOT NULL,
        generation TEXT NOT NULL, base_revision INTEGER NOT NULL, revision INTEGER NOT NULL,
        old_epoch INTEGER NOT NULL, new_epoch INTEGER NOT NULL, updated_at REAL NOT NULL, created_at REAL NOT NULL,
        PRIMARY KEY(account_id,batch_id))""")
    conn.execute("CREATE INDEX IF NOT EXISTS account_checkpoint_receipts_age ON account_checkpoint_receipts(created_at)")
    delta_staging.initialize(conn)
    conn.execute("CREATE TABLE IF NOT EXISTS sync_metadata(id INTEGER PRIMARY KEY CHECK(id=1), generation TEXT NOT NULL)")
    conn.execute("INSERT OR IGNORE INTO sync_metadata(id,generation) VALUES(1,?)", (secrets.token_hex(16),))
    conn.execute("""CREATE TABLE IF NOT EXISTS legacy_state_bindings(
        user_id INTEGER PRIMARY KEY, account_id TEXT NOT NULL)""")
    # 原表保留作为只读恢复依据，迁移记录与新表写入同一事务。
    for uid, account_id in conn.execute("SELECT id, account_id FROM users WHERE legacy_personal=1").fetchall():
        if conn.execute("SELECT 1 FROM legacy_state_bindings WHERE user_id=?", (uid,)).fetchone():
            continue
        conn.execute("INSERT INTO legacy_state_bindings(user_id, account_id) VALUES(?,?)", (uid, account_id))
        conn.execute("INSERT INTO account_state(account_id,state_json,updated_at) SELECT ?,state_json,updated_at FROM user_state WHERE user_id=?", (account_id, uid))
        conn.execute("INSERT INTO account_state_backups(id,account_id,state_json,created_at,reason) SELECT id,?,state_json,created_at,reason FROM user_state_backups WHERE user_id=?", (account_id, uid))
    # 仅升级前的现有令牌绑定当前账号；后续重启绝不重新绑定失效令牌。
    if migrating_tokens:
        conn.execute("""UPDATE tokens SET account_id=(SELECT account_id FROM users WHERE users.id=tokens.user_id)
                        WHERE account_id IS NULL""")
    conn.commit()
    conn.close()


def hash_pwd(pwd, salt):
    return hashlib.pbkdf2_hmac("sha256", pwd.encode(), bytes.fromhex(salt), 100_000).hex()


# Bound expensive memory-hard operations per worker. The reverse proxy must also limit traffic.
_PASSWORD_SLOTS = threading.BoundedSemaphore(4)
_PASSWORD_HASHER = PasswordHasher(time_cost=2, memory_cost=19456, parallelism=1, hash_len=32, salt_len=16, type=Type.ID)
_DUMMY_PASSWORD_HASH = "$argon2id$v=19$m=19456,t=2,p=1$dm9jYWItZHVtbXktc2FsdA$Yo/tHaByeHC8VXyX/BZIEZp0ptAQ3Znhaa31+JHph3A"


@contextmanager
def password_slot():
    if not _PASSWORD_SLOTS.acquire(blocking=False):
        raise HTTPException(503, "认证繁忙，请稍后重试", headers={"Retry-After": "1"})
    try:
        yield
    finally:
        _PASSWORD_SLOTS.release()


def verify_password_record(password, record):
    """Verify current or legacy hashes; malformed/missing records use a dummy cost."""
    stored, salt = (record[2], record[3]) if record else (None, None)
    if isinstance(stored, str) and stored.startswith("$argon2id$"):
        try:
            params = extract_parameters(stored)
            # Never let a corrupted database request unbounded memory or CPU.
            if (params.type != Type.ID or params.version != 19 or not 8 <= params.memory_cost <= 65536
                or not 1 <= params.time_cost <= 5 or not 1 <= params.parallelism <= 4
                or not 8 <= params.salt_len <= 64 or not 16 <= params.hash_len <= 64):
                raise InvalidHashError("unsupported parameters")
            valid = _PASSWORD_HASHER.verify(stored, password)
            return bool(valid), _PASSWORD_HASHER.check_needs_rehash(stored)
        except VerifyMismatchError:
            return False, False
        except (InvalidHashError, VerificationError, ValueError):
            pass
    else:
        legacy = False
        try:
            legacy = bool(record and isinstance(stored, str) and re.fullmatch(r"[a-f0-9]{64}", stored)
                          and isinstance(salt, str) and re.fullmatch(r"[a-f0-9]{32}", salt)
                          and secrets.compare_digest(hash_pwd(password, salt), stored))
        except (TypeError, ValueError):
            pass
        # Equalize missing and legacy account paths with one current-cost verification.
        try:
            _PASSWORD_HASHER.verify(_DUMMY_PASSWORD_HASH, password)
        except VerifyMismatchError:
            pass
        return legacy, legacy
    try:
        _PASSWORD_HASHER.verify(_DUMMY_PASSWORD_HASH, password)
    except VerifyMismatchError:
        pass
    return False, False


def make_token(conn, uid):
    token = secrets.token_urlsafe(32)
    row = conn.execute("SELECT account_id FROM users WHERE id=?", (uid,)).fetchone()
    if not row or not row[0]:
        raise RuntimeError("account identity missing")
    conn.execute("INSERT INTO tokens(token_hash,user_id,expires_at,revoked,account_id) VALUES(?,?,?,0,?)",
                 (hashlib.sha256(token.encode()).hexdigest(), uid, time.time() + TOKEN_TTL, row[0]))
    conn.commit()
    return token


def identity_by_token(authorization):
    """原子解析令牌与其绑定的账号身份；无/无效 → None。"""
    if not authorization or not authorization.startswith("Bearer "):
        return None
    th = hashlib.sha256(authorization[7:].encode()).hexdigest()
    conn = sqlite3.connect(USERS_DB)
    row = conn.execute(
        "SELECT t.user_id, u.account_id FROM tokens t JOIN users u ON u.id=t.user_id AND u.account_id=t.account_id "
        "WHERE t.token_hash=? AND t.revoked=0 AND t.expires_at>?",
        (th, time.time())).fetchone()
    conn.close()
    return row


def user_by_token(authorization):
    """从 Authorization: Bearer 头解析用户；无/无效 → None。"""
    identity = identity_by_token(authorization)
    return identity[0] if identity else None


class RegisterIn(BaseModel):
    username: str = Field(min_length=3, max_length=20)
    password: str = Field(min_length=8, max_length=64)
    nickname: str = Field(default="", max_length=30)


class LoginIn(BaseModel):
    username: str = Field(min_length=1, max_length=20)
    password: str = Field(min_length=1, max_length=64)


class RestoreIn(BaseModel):
    state: dict
    expected_updated_at: float | None = None


class CheckpointIn(BaseModel):
    expected_updated_at: float

class GuardedRestoreIn(RestoreIn):
    generation: str
    state_revision: str

class IdempotentGuardedRestoreIn(GuardedRestoreIn):
    batch_id: str

class GuardedCheckpointIn(CheckpointIn):
    generation: str
    state_revision: str


class SchedulerResolveIn(BaseModel):
    generation: str
    keys: list[str] = Field(max_length=256)


def validate_state_revision(value):
    if not isinstance(value, int) or isinstance(value, bool) or not 1 <= value <= 2**63 - 1:
        raise HTTPException(409, "学习状态修订号无效，请先备份并联系管理员")
    return value


def next_state_revision(value):
    """Advance a stored-state revision without SQLite integer overflow."""
    if validate_state_revision(value) == 2**63 - 1:
        raise HTTPException(409, "学习状态修订号已耗尽，请先备份并联系管理员")
    return value + 1


def serialize_state(state, max_bytes=MAX_STATE_BYTES):
    import json
    try:
        encoded = json.dumps(state, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    except (ValueError, TypeError):
        raise HTTPException(422, "学习状态包含无效数据")
    if len(encoded.encode("utf-8")) > max_bytes:
        raise HTTPException(413, "学习状态超过同步大小上限，本地进度已保留")
    return encoded


def load_verified_state(conn, account_id, raw, revision):
    """Use segmented state only when it matches its revision and full mirror."""
    try:
        value = state_segments.read(conn, account_id, revision, raw)
        return value if value is not None else json.loads(raw)
    except (state_segments.SegmentError, json.JSONDecodeError, UnicodeError, RecursionError) as error:
        raise HTTPException(409, "学习状态分段校验失败，请先导出并联系管理员") from error


def prepare_uploaded_state(body, max_bytes=MAX_STATE_BYTES):
    """Apply the same validation and canonicalization to both upload paths."""
    serialize_state(body, max_bytes)
    validate_fsrs_schedulers(body)
    validate_settings_versions(body)
    validate_placement_version(body)
    validate_personal_versions(body)
    validate_knowledge_evidence(body)
    validate_band_evidence(body)
    body = canonicalize_posterior(body)
    validate_streak(body)
    # A legacy pair without evidence must also be anchorable. Otherwise the
    # write succeeds but a later snapshot fails while deriving its baseline.
    anchor_streak(body)
    merge_log_events(body.get("log") or [], [])
    return filter_rejected_personalized(body)


def validate_fsrs_schedulers(state):
    """备份携带的参数快照必须与指纹一致，不能覆盖其他版本。"""
    versions = state.get("fsrsSchedulers")
    if versions is None:
        return {}
    if not isinstance(versions, dict) or len(versions) > 256:
        raise HTTPException(422, "FSRS 参数快照格式无效")
    checked = {}
    for key, config in versions.items():
        try:
            if not isinstance(key, str) or not re.fullmatch(r"[0-9a-f]{64}", key):
                raise ValueError("invalid key")
            normalized = normalize_fsrs_config(config)
            if fsrs_config_key(normalized) != key:
                raise ValueError("snapshot hash mismatch")
            checked[key] = normalized
        except (ValueError, TypeError, OverflowError):
            raise HTTPException(422, "FSRS 参数快照无效或校验失败")
    return checked


def validate_settings_versions(state):
    """版本随字段独立合并；版本一致却值不同视为冲突。"""
    versions = state.get("settingsVersions")
    settings = state.get("settings") or {}
    if versions is None:
        return {}
    if not isinstance(versions, dict) or len(versions) > 32 or not isinstance(settings, dict):
        raise HTTPException(422, "设置版本格式无效")
    for key, version in versions.items():
        if (not isinstance(key, str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,63}", key)
            or key not in settings or not isinstance(version, dict)
            or set(version) != {"counter", "device"}
            or not isinstance(version["counter"], int) or isinstance(version["counter"], bool)
            or not 1 <= version["counter"] <= 2**53 - 1
            or not isinstance(version["device"], str)
            or not re.fullmatch(r"[a-z0-9-]{1,64}", version["device"])):
            raise HTTPException(422, "设置版本格式无效")
    return versions


def validate_placement_version(state):
    version = state.get("placementVersion")
    if version is None:
        return None
    if (not isinstance(version, dict) or set(version) != {"counter", "device", "id"}
        or not isinstance(version["counter"], int) or isinstance(version["counter"], bool)
        or not 1 <= version["counter"] <= 2**53 - 1
        or not isinstance(version["device"], str) or not re.fullmatch(r"[a-z0-9-]{1,64}", version["device"])
        or not isinstance(version["id"], str) or not re.fullmatch(r"[a-f0-9-]{8,64}", version["id"])):
        raise HTTPException(422, "定级版本格式无效")
    return version


def validate_rejected_personalized(state):
    rejected = state.get("rejectedPersonalized")
    if rejected is None:
        return {}
    if not isinstance(rejected, dict):
        raise HTTPException(422, "已拒绝例句记录格式无效")
    for word, texts in rejected.items():
        if (not isinstance(word, str) or not 1 <= len(word) <= 100 or not isinstance(texts, list)
            or any(not isinstance(text, str) or not 1 <= len(text) <= 2000 for text in texts)):
            raise HTTPException(422, "已拒绝例句记录格式无效")
    return rejected


def validate_personal_versions(state):
    def check(word, version):
        if (not isinstance(word, str) or not 1 <= len(word) <= 100 or not isinstance(version, dict)
            or set(version) != {"counter", "device", "deleted"}
            or not isinstance(version["counter"], int) or isinstance(version["counter"], bool)
            or not 1 <= version["counter"] <= 2**53 - 1
            or not isinstance(version["device"], str) or not re.fullmatch(r"[a-z0-9-]{1,64}", version["device"])
            or not isinstance(version["deleted"], bool)):
            raise HTTPException(422, "个性化例句版本格式无效")
    versions = state.get("personalVersions") or {}
    personal = state.get("personalized") or {}
    if not isinstance(versions, dict) or not isinstance(personal, dict):
        raise HTTPException(422, "个性化例句版本格式无效")
    for word, version in versions.items():
        check(word, version)
        value = personal.get(word)
        if version["deleted"] and word in personal or not version["deleted"] and (not isinstance(value, dict) or not isinstance(value.get("text"), str)):
            raise HTTPException(422, "个性化例句版本与内容不一致")
    for job in state.get("personalJobs") or []:
        if not isinstance(job, dict) or job.get("personalVersions") is None:
            continue
        job_versions = job["personalVersions"]
        if not isinstance(job_versions, dict) or len(job_versions) > 30:
            raise HTTPException(422, "个性化任务版本格式无效")
        for word, version in job_versions.items():
            check(word, version)
            if version["deleted"] or word not in (job.get("weakWords") or []):
                raise HTTPException(422, "个性化任务版本格式无效")
    return versions


def validate_knowledge_evidence(state):
    import math
    ledgers = state.get("knowledgeEvidence")
    if ledgers is None:
        return {}
    knowledge = state.get("knowledge") or {}
    if not isinstance(ledgers, dict) or not isinstance(knowledge, dict):
        raise HTTPException(422, "词级证据格式无效")
    seen = set()
    for word, ledger in ledgers.items():
        if (not isinstance(word, str) or not 1 <= len(word) <= 100 or not isinstance(ledger, dict)
            or set(ledger) != {"baseId", "base", "events"} or not isinstance(ledger["base"], dict)
            or not isinstance(ledger["baseId"], str) or not re.fullmatch(r"(?:empty|[a-f0-9-]{8,64})", ledger["baseId"])
            or not isinstance(ledger["events"], dict) or not isinstance(knowledge.get(word), dict)):
            raise HTTPException(422, "词级证据格式无效")
        base, events, value = ledger["base"], ledger["events"], knowledge[word]
        for key in ("a", "b"):
            number = base.get(key)
            if not isinstance(number, (int, float)) or isinstance(number, bool) or not math.isfinite(number) or not 0 <= number <= 2**53 - 1:
                raise HTTPException(422, "词级证据基线无效")
        if ledger["baseId"] == "empty" and (base["a"] != 0 or base["b"] != 0):
            raise HTTPException(422, "词级证据基线无效")
        pos = base.get("pos")
        if pos is not None and (not isinstance(pos, int) or isinstance(pos, bool) or not 0 <= pos <= 12000):
            raise HTTPException(422, "词级证据基线无效")
        a, b = base["a"], base["b"]
        for event_id, event in events.items():
            if (not isinstance(event_id, str) or not re.fullmatch(r"[a-f0-9-]{8,64}", event_id)
                or event_id in seen or not isinstance(event, dict) or set(event) != {"device", "at", "ok", "pos"}
                or not isinstance(event["device"], str) or not re.fullmatch(r"[a-z0-9-]{1,64}", event["device"])
                or not isinstance(event["at"], str) or not 1 <= len(event["at"]) <= 64
                or not isinstance(event["ok"], bool) or not isinstance(event["pos"], int) or isinstance(event["pos"], bool)
                or not 0 <= event["pos"] <= 12000):
                raise HTTPException(422, "词级证据事件无效")
            seen.add(event_id)
            if event["ok"]: a += 1
            else: b += 1
        for key, expected in (("a", a), ("b", b)):
            actual = value.get(key)
            if (not isinstance(actual, (int, float)) or isinstance(actual, bool) or not math.isfinite(actual)
                or not 0 <= actual <= 2**53 - 1 or expected > 2**53 - 1
                or not math.isclose(actual, expected, rel_tol=1e-12, abs_tol=1e-9)):
                raise HTTPException(409, "词级证据与统计不一致，请先导出进度并重新加载")
    return ledgers


def anchor_legacy_knowledge(state):
    """在服务器上为旧统计创建持久基线；只在同一数据库事务内调用。"""
    import uuid
    validate_knowledge_evidence(state)
    knowledge = state.get("knowledge") or {}
    if not isinstance(knowledge, dict):
        raise HTTPException(422, "词级证据格式无效")
    ledgers = dict(state.get("knowledgeEvidence") or {})
    added = False
    for word, value in knowledge.items():
        if word in ledgers:
            continue
        if not isinstance(value, dict):
            raise HTTPException(422, "词级证据基线无效")
        base = {"a":value.get("a", 0), "b":value.get("b", 0)}
        if value.get("pos") is not None: base["pos"] = value["pos"]
        baseline = "empty" if base["a"] == 0 and base["b"] == 0 else uuid.uuid4().hex
        ledgers[word] = {"baseId":baseline, "base":base, "events":{}}
        added = True
    if not added:
        return state, False
    result = {**state, "knowledgeEvidence":ledgers}
    validate_knowledge_evidence(result)
    return result, True


def merge_knowledge_evidence(old, new):
    left, right = validate_knowledge_evidence(old), validate_knowledge_evidence(new)
    old_values, new_values = old.get("knowledge") or {}, new.get("knowledge") or {}
    merged = _merge_evidence_maps(old_values, new_values) or {}
    out = {}
    for word in left.keys() | right.keys():
        a, b = left.get(word), right.get(word)
        if a and b:
            if a["baseId"] != b["baseId"] or any(a["base"].get(key) != b["base"].get(key) for key in ("a", "b")):
                raise HTTPException(409, "词级证据基线不同，无法安全合并，请先导出进度")
            events = dict(a["events"])
            for event_id, event in b["events"].items():
                if event_id in events and events[event_id] != event:
                    raise HTTPException(409, "词级证据事件冲突，请先导出进度")
                events[event_id] = event
            positions = [p for p in (a["base"].get("pos"), b["base"].get("pos")) if p is not None]
            base = {"a": a["base"]["a"], "b": a["base"]["b"]}
            if positions: base["pos"] = min(positions)
        else:
            ledger, legacy = (a, new_values) if a else (b, old_values)
            base, events = dict(ledger["base"]), dict(ledger["events"])
            legacy_value = legacy.get(word)
            if legacy_value is not None and (ledger["baseId"] != "empty" or not isinstance(legacy_value, dict) or
                any(legacy_value.get(key, 0) != 0 for key in ("a", "b"))):
                raise HTTPException(409, "旧设备的词级证据无法验证，请先导出进度并升级客户端")
        out[word] = {"baseId": (a or b)["baseId"], "base": base, "events": events}
        positions = ([base["pos"]] if base.get("pos") is not None else []) + [event["pos"] for event in events.values()]
        merged[word] = {"a": base["a"] + sum(event["ok"] for event in events.values()),
                        "b": base["b"] + sum(not event["ok"] for event in events.values())}
        if positions: merged[word]["pos"] = min(positions)
    validate_knowledge_evidence({"knowledge": merged, "knowledgeEvidence": out})
    return merged, out


def validate_band_evidence(state):
    ledgers = state.get("bandEvidence")
    view = {"knowledge": state.get("bandStats"), "knowledgeEvidence": ledgers}
    bands = validate_knowledge_evidence(view)
    knowledge = validate_knowledge_evidence(state)
    events = {event_id: event for ledger in knowledge.values() for event_id, event in ledger["events"].items()}
    for band, ledger in bands.items():
        if band not in {"0", "1", "2", "3", "4", "5"}:
            raise HTTPException(422, "分档证据格式无效")
        for event_id, event in ledger["events"].items():
            pos = event["pos"]
            expected = next((i for i, (lo, hi) in enumerate(((1,2000),(2001,4000),(4001,6000),(6001,8000),(8001,10000),(10001,10987))) if lo <= pos <= hi), 5)
            if str(expected) != band or events.get(event_id) != event:
                raise HTTPException(409, "分档证据与词级事件不一致，请先导出进度")
    return bands


def anchor_legacy_evidence(state):
    state, knowledge_added = anchor_legacy_knowledge(state)
    validate_band_evidence(state)
    view = {"knowledge": state.get("bandStats"), "knowledgeEvidence": state.get("bandEvidence")}
    anchored, band_added = anchor_legacy_knowledge(view)
    if band_added:
        state = {**state, "bandEvidence": anchored["knowledgeEvidence"]}
    validate_band_evidence(state)
    state, posterior_added = anchor_posterior(state)
    state, streak_added = anchor_streak(state)
    return state, knowledge_added or band_added or posterior_added or streak_added


def merge_band_evidence(old, new):
    left = {"knowledge": old.get("bandStats"), "knowledgeEvidence": old.get("bandEvidence")}
    right = {"knowledge": new.get("bandStats"), "knowledgeEvidence": new.get("bandEvidence")}
    values, ledgers = merge_knowledge_evidence(left, right)
    # 档位只存 a/b；pos 属于词级事件，不是档位属性。
    for value in values.values():
        value.pop("pos", None)
    return (values if values or old.get("bandStats") is not None or new.get("bandStats") is not None else None), ledgers


def filter_rejected_personalized(state):
    rejected = validate_rejected_personalized(state)
    personal = state.get("personalized")
    if personal is None:
        return state
    if not isinstance(personal, dict):
        raise HTTPException(422, "个性化例句格式无效")
    kept = {word: value for word, value in personal.items()
        if not isinstance(value, dict) or value.get("text") not in rejected.get(word, [])}
    versions = dict(state.get("personalVersions") or {})
    for word in personal.keys() - kept.keys():
        if word in versions:
            versions[word] = {**versions[word], "deleted": True}
    result = {**state, "personalized": kept}
    if versions: result["personalVersions"] = versions
    return result


def merge_versioned_personal(old, new):
    a, b = old.get("personalized") or {}, new.get("personalized") or {}
    va, vb = validate_personal_versions(old), validate_personal_versions(new)
    merged, versions = {}, {}
    for word in a.keys() | b.keys() | va.keys() | vb.keys():
        left, right = va.get(word), vb.get(word)
        if left and right:
            lv, rv = (left["counter"], left["device"]), (right["counter"], right["device"])
            if lv == rv:
                if left["deleted"] != right["deleted"]:
                    use_left = left["deleted"]
                elif not left["deleted"] and ({**a[word], "recall": a[word].get("recall") or "", "zh": a[word].get("zh") or ""} !=
                                               {**b[word], "recall": b[word].get("recall") or "", "zh": b[word].get("zh") or ""}):
                    raise HTTPException(409, "个性化例句版本冲突，请先导出进度并重新加载")
                else:
                    use_left = True
            else:
                use_left = lv > rv
        else:
            use_left = bool(left) or (not right and word not in b)
        values, version = (a, left) if use_left else (b, right)
        if version:
            versions[word] = version
        if word in values and (not version or not version["deleted"]):
            merged[word] = values[word]
    return merged, versions


def merge_versioned_settings(old, new):
    a, b = old.get("settings") or {}, new.get("settings") or {}
    va, vb = validate_settings_versions(old), validate_settings_versions(new)
    if not isinstance(a, dict) or not isinstance(b, dict):
        raise HTTPException(422, "设置格式无效")
    merged, versions = {}, {}
    for key in a.keys() | b.keys():
        left, right = va.get(key), vb.get(key)
        if left and right:
            lv, rv = (left["counter"], left["device"]), (right["counter"], right["device"])
            if lv == rv and (type(a[key]) is not type(b[key]) or a[key] != b[key]):
                raise HTTPException(409, "设置版本冲突，请先导出进度并重新加载")
            use_left = lv >= rv
        else:
            use_left = bool(left) or (not right and key not in b)
        source, version = (a, left) if use_left else (b, right)
        if key in source:
            merged[key] = source[key]
        if version:
            versions[key] = version
    return merged, versions


def enrich_fsrs_schedulers(state, account_id):
    """把本账户已记录且被卡片引用的版本附到下载状态，不修改原档。"""
    import json
    from app.main import PERSONAL_DB
    versions = dict(state.get("fsrsSchedulers") or {}) if isinstance(state.get("fsrsSchedulers"), dict) else {}
    needed = set()
    cards = state.get("cards")
    if not isinstance(cards, dict):
        return state
    for card in cards.values():
        if not isinstance(card, dict):
            continue
        for field in ("fsrsHistory", "pendingFsrs"):
            group = card.get(field)
            if not isinstance(group, dict):
                continue
            if isinstance(group.get("schedulerKey"), str): needed.add(group["schedulerKey"])
            for event in group.get("events") or []:
                if isinstance(event, dict) and isinstance(event.get("schedulerKey"), str):
                    needed.add(event["schedulerKey"])
    missing = sorted(key for key in needed - versions.keys() if re.fullmatch(r"[0-9a-f]{64}", key))
    # 8 MiB 同步状态上限之内仍对版本数施加独立上限。
    missing = missing[:max(0, 256 - len(versions))]
    if not missing:
        return state
    try:
        placeholders = ",".join("?" for _ in missing)
        with sqlite3.connect(PERSONAL_DB, timeout=15) as conn:
            rows = conn.execute(f"SELECT scheduler_key, config_json FROM fsrs_scheduler_versions WHERE owner=? AND scheduler_key IN ({placeholders})",
                                (f"account:{account_id}", *missing)).fetchall()
        for key, raw in rows:
            try:
                config = normalize_fsrs_config(json.loads(raw))
                if fsrs_config_key(config) == key:
                    versions[key] = config
            except (TypeError, ValueError, OverflowError):
                continue
    except sqlite3.Error:
        # 状态本身仍可下载；缺少的快照会在重放时明确报错。
        return state
    if versions != (state.get("fsrsSchedulers") or {}):
        return {**state, "fsrsSchedulers": versions}
    return state


def load_owned_scheduler_versions(account_id, keys):
    """Read only explicitly requested keys from the account's parameter store."""
    if not keys:
        return []
    from app.main import PERSONAL_DB
    conn = sqlite3.connect(PERSONAL_DB, timeout=15)
    try:
        placeholders = ','.join('?' for _ in keys)
        return conn.execute(f"SELECT scheduler_key,config_json FROM fsrs_scheduler_versions WHERE owner=? AND scheduler_key IN ({placeholders})",
                            (f"account:{account_id}", *keys)).fetchall()
    finally:
        conn.close()


def validate_restore_state(state, max_bytes=MAX_STATE_BYTES):
    """备份恢复只接受学习状态对象；未知字段保留，以兼容后续版本。"""
    if not isinstance(state.get("v"), int) or isinstance(state.get("v"), bool) or state["v"] < 1:
        raise HTTPException(422, "备份缺少有效版本")
    for key, typ in (("cards", dict), ("log", list), ("pendingNew", list), ("settings", dict)):
        if not isinstance(state.get(key), typ):
            raise HTTPException(422, f"备份字段 {key} 无效")
    if "__proto__" in state:
        raise HTTPException(422, "备份包含无效字段")
    def is_int(value):
        return isinstance(value, int) and not isinstance(value, bool)
    def is_number(value):
        import math
        return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
    for word, card in state["cards"].items():
        if not isinstance(word, str) or not isinstance(card, dict):
            raise HTTPException(422, "备份中的卡片格式无效")
        for key in ("stage", "lt", "pos", "easyStreak"):
            if card.get(key) is not None and not is_int(card[key]):
                raise HTTPException(422, "备份中的卡片格式无效")
        if card.get("due") is not None and not isinstance(card["due"], str):
            raise HTTPException(422, "备份中的卡片日期无效")
        fsrs = card.get("fsrs")
        if fsrs is not None and (not isinstance(fsrs, dict) or not is_int(fsrs.get("state")) or
                                 not is_number(fsrs.get("stability")) or not is_number(fsrs.get("difficulty"))):
            raise HTTPException(422, "备份中的 FSRS 状态无效")
    for entry in state["log"]:
        if (not isinstance(entry, dict) or not isinstance(entry.get("d"), str) or
            not isinstance(entry.get("word"), str) or not isinstance(entry.get("kind"), str) or
            not is_int(entry.get("rating"))):
            raise HTTPException(422, "备份中的学习记录无效")
    for entry in state["pendingNew"]:
        if not isinstance(entry, dict) or not isinstance(entry.get("word"), str) or not is_int(entry.get("pos")):
            raise HTTPException(422, "备份中的待学词无效")
    for key in ("newPerDay", "dailyCap", "notifyHour"):
        if state["settings"].get(key) is not None and not is_int(state["settings"][key]):
            raise HTTPException(422, "备份中的设置无效")
    for key in ("frontier", "pointer", "probeCount", "streak"):
        if state.get(key) is not None and not is_int(state[key]):
            raise HTTPException(422, "备份中的进度无效")
    if state.get("calibrated") is not None and not isinstance(state["calibrated"], bool):
        raise HTTPException(422, "备份中的定级状态无效")
    validate_fsrs_schedulers(state)
    validate_settings_versions(state)
    validate_placement_version(state)
    validate_rejected_personalized(state)
    validate_personal_versions(state)
    validate_knowledge_evidence(state)
    validate_band_evidence(state)
    validate_posterior(state)
    validate_streak(state)
    merge_log_events(state["log"], [])
    serialize_state(state, max_bytes)


def _log_key(entry):
    import json as _j
    return _j.dumps(entry, ensure_ascii=False, sort_keys=True)


def merge_log_events(old, new):
    """New events use unique IDs; legacy records retain their existing count semantics."""
    import json as _j
    from collections import Counter
    identified, legacy = {}, [Counter(), Counter()]
    for index, entries in enumerate((old, new)):
        for entry in entries:
            if not isinstance(entry, dict):
                raise HTTPException(422, "学习记录格式无效")
            event_id = entry.get("eventId")
            if event_id is None:
                legacy[index][_log_key(entry)] += 1
                continue
            if not isinstance(event_id, str) or not re.fullmatch(r"[a-f0-9-]{8,64}", event_id):
                raise HTTPException(422, "学习记录标识无效")
            if event_id in identified and identified[event_id] != entry:
                raise HTTPException(409, "学习记录标识冲突，请先导出进度")
            identified[event_id] = entry
    merged = list(identified.values())
    for key in legacy[0].keys() | legacy[1].keys():
        merged.extend([_j.loads(key)] * max(legacy[0][key], legacy[1][key]))
    return merged


def _merge_evidence_maps(old, new):
    """v2.0 字段合并：缺字段的一端不能清空另一端；每词/每档保留证据更多的一侧。"""
    if not old:
        return new
    if not new:
        return old
    out = dict(old)
    for key, nv in new.items():
        ov = out.get(key)
        if ov is None:
            out[key] = nv
            continue
        old_total = (ov.get("a", 0) or 0) + (ov.get("b", 0) or 0)
        new_total = (nv.get("a", 0) or 0) + (nv.get("b", 0) or 0)
        if new_total >= old_total:
            out[key] = nv
    return out


def _history_base_key(base):
    """忽略评分字段，比较能决定 FSRS 起点的输入。"""
    from datetime import datetime, timezone
    if not isinstance(base, dict):
        raise HTTPException(409, "评分历史缺少有效起点")
    if base.get("is_new"):
        return (True,)
    def instant(value):
        if value is None:
            return None
        try:
            result = datetime.fromisoformat(value.replace("Z", "+00:00"))
            if result.tzinfo is None:
                raise ValueError("missing timezone")
            return result.astimezone(timezone.utc)
        except (AttributeError, TypeError, ValueError, OverflowError):
            raise HTTPException(409, "评分历史中的日期无效")
    return (False, base.get("state", 1), base.get("stability", 0), base.get("difficulty", 0),
            instant(base.get("due")), base.get("step"), instant(base.get("last_review")))


def _fsrs_state_key(fsrs):
    """双端对可选空字段和 lastReview 的编码不同，但调度状态可以等价。"""
    if not fsrs:
        return None
    return _history_base_key({"state": fsrs.get("state"), "stability": fsrs.get("stability"),
        "difficulty": fsrs.get("difficulty"), "due": fsrs.get("due"), "step": fsrs.get("step"),
        "last_review": fsrs.get("lastReview") or fsrs.get("last_review")})


def _history_events(history):
    from datetime import datetime, timezone
    if not isinstance(history, dict) or not isinstance(history.get("events"), list):
        raise HTTPException(409, "评分历史格式无效")
    events = {}
    for event in history["events"]:
        if not isinstance(event, dict) or not isinstance(event.get("id"), str) or not event["id"] or len(event["id"]) > 128:
            raise HTTPException(409, "评分历史的事件标识无效")
        if not isinstance(event.get("rating"), int) or isinstance(event["rating"], bool) or event["rating"] not in (1, 2, 3, 4):
            raise HTTPException(409, "评分历史中的评分无效")
        try:
            at = datetime.fromisoformat(event["at"].replace("Z", "+00:00"))
            if at.tzinfo is None:
                raise ValueError("missing timezone")
            at = at.astimezone(timezone.utc)
        except (KeyError, AttributeError, TypeError, ValueError, OverflowError):
            raise HTTPException(409, "评分历史中的日期无效")
        if event.get("schedulerKey") is not None and not isinstance(event["schedulerKey"], str):
            raise HTTPException(409, "评分历史的参数版本无效")
        if event["id"] in events and events[event["id"]][1] != event:
            raise HTTPException(409, "同一评分标识对应不同的事件")
        events[event["id"]] = (at, event)
    return events


def _event_core(event):
    return {k: v for k, v in event.items() if k != "schedulerKey"}


def _card_history_events(card, history):
    """迁移历史默认参数到每个事件；尚未应用的事件可暂时没有版本。"""
    events = _history_events(history)
    pending = card.get("pendingFsrs")
    queued = _history_events(pending) if pending else {}
    if not set(queued) <= set(events):
        raise HTTPException(409, "待同步评分与历史不一致")
    applied = set(card.get("appliedFsrs") or [])
    output = {}
    for event_id, (at, event) in events.items():
        pending_event = queued[event_id][1] if event_id in queued else None
        if pending_event is not None and _event_core(pending_event) != _event_core(event):
            raise HTTPException(409, "待同步评分与历史不一致")
        if event_id not in applied and pending_event is None:
            raise HTTPException(409, "评分历史中有既未应用也未排队的事件")
        explicit = [event.get("schedulerKey"), pending_event.get("schedulerKey") if pending_event else None]
        if any(x and not isinstance(x, str) for x in explicit):
            raise HTTPException(409, "评分历史的参数版本无效")
        versions = {x for x in explicit if x}
        if not versions:
            # 旧客户端将版本放在批次级别；新事件的显式版本优先于旧历史的默认值。
            defaults = [pending.get("schedulerKey") if pending_event else None,
                        history.get("schedulerKey") if event_id in applied else None]
            if any(x and not isinstance(x, str) for x in defaults):
                raise HTTPException(409, "评分历史的参数版本无效")
            versions = {x for x in defaults if x}
        if len(versions) > 1:
            raise HTTPException(409, "同一评分对应不同的 FSRS 参数")
        normalized = _event_core(event)
        if versions:
            normalized["schedulerKey"] = next(iter(versions))
        output[event_id] = (at, normalized)
    return output, applied


def _history_replay_verified(card, events):
    proof = card.get("fsrsReplayVersions")
    return isinstance(proof, dict) and all(pair[1].get("schedulerKey") and
        proof.get(event_id) == pair[1].get("schedulerKey") for event_id, pair in events.items())


def _merge_histories(old_card, new_card, selected):
    """共享起点的分叉合并成可重放队列；不能证明安全的分叉返回冲突。"""
    oh, nh = old_card.get("fsrsHistory"), new_card.get("fsrsHistory")
    if not oh and not nh:
        return None
    if (oh is not None and not isinstance(oh, dict)) or (nh is not None and not isinstance(nh, dict)):
        raise HTTPException(409, "评分历史格式无效")
    if not oh or not nh:
        history_card, legacy = (old_card, new_card) if oh else (new_card, old_card)
        history = oh or nh
        own, own_applied = _card_history_events(history_card, history)
        pending = legacy.get("pendingFsrs")
        migrated_versions = {}
        if pending:
            legacy_events = _history_events(pending)
            if not set(legacy_events) <= set(own):
                raise HTTPException(409, "旧客户端的评分缺少可验证的历史，请保留两端进度")
            for event_id, (_, event) in legacy_events.items():
                other = own[event_id][1]
                legacy_key = event.get("schedulerKey") or pending.get("schedulerKey")
                own_key = other.get("schedulerKey")
                if legacy_key and not isinstance(legacy_key, str):
                    raise HTTPException(409, "评分历史的参数版本无效")
                if (_event_core(event) != _event_core(other) or
                    (legacy_key and own_key and legacy_key != own_key) or
                    (legacy_key and not own_key and event_id in own_applied)):
                    raise HTTPException(409, "旧客户端的评分缺少可验证的历史，请保留两端进度")
                if legacy_key and not own_key:
                    migrated_versions[event_id] = legacy_key
        other_fsrs = legacy.get("fsrs") or {}
        current_fsrs = history_card.get("fsrs") or {}
        base = history.get("base") or {}
        as_base = {"state": other_fsrs.get("state"), "stability": other_fsrs.get("stability"),
                   "difficulty": other_fsrs.get("difficulty"), "due": other_fsrs.get("due"),
                   "step": other_fsrs.get("step"),
                   "last_review": other_fsrs.get("lastReview") or other_fsrs.get("last_review")}
        at_origin = (not other_fsrs and (not legacy.get("stage") or bool(pending)) if base.get("is_new") else bool(other_fsrs) and
                     _history_base_key(base) == _history_base_key(as_base))
        if not at_origin and _fsrs_state_key(other_fsrs) != _fsrs_state_key(current_fsrs):
            raise HTTPException(409, "旧客户端的卡片已分叉且无法重算，请保留两端进度")
        known = set(history_card.get("appliedFsrs") or []) | set(own)
        if not set(legacy.get("appliedFsrs") or []) <= known:
            raise HTTPException(409, "旧客户端含无法验证的评分，请保留两端进度")
        result = dict(history_card)
        if migrated_versions:
            for name in ("fsrsHistory", "pendingFsrs"):
                group = result.get(name)
                if group:
                    result[name] = {**group, "events": [
                        {**event, "schedulerKey": migrated_versions[event["id"]]}
                        if event["id"] in migrated_versions else event for event in group["events"]]}
        # 旧客户端可能忽略逐事件参数；没有对应的完成标记时，不把它的结果当作已验证。
        if own and not result.get("pendingFsrs") and not _history_replay_verified(result, own):
            if all(pair[1].get("schedulerKey") for pair in own.values()):
                ordered = [pair[1] for _, pair in sorted(own.items(), key=lambda p: (p[1][0], p[0]))]
                result["fsrsHistory"] = {"base": history["base"], "events": ordered}
                result["pendingFsrs"] = {"base": history["base"], "events": ordered}
                result.pop("fsrsReplayVersions", None)
                remainder = set(result.get("appliedFsrs") or []) - set(own)
                if remainder: result["appliedFsrs"] = sorted(remainder)
                else: result.pop("appliedFsrs", None)
            elif _fsrs_state_key(other_fsrs) != _fsrs_state_key(current_fsrs):
                raise HTTPException(409, "旧评分缺少参数版本，无法安全重算")
        return result
    if _history_base_key(oh.get("base")) != _history_base_key(nh.get("base")):
        raise HTTPException(409, "评分历史的共同起点不同，请保留两端进度")
    left, left_applied = _card_history_events(old_card, oh)
    right, right_applied = _card_history_events(new_card, nh)
    union = dict(left)
    for event_id, (at, event) in right.items():
        if event_id not in union:
            union[event_id] = (at, event)
            continue
        other = union[event_id][1]
        if _event_core(other) != _event_core(event):
            raise HTTPException(409, "同一评分标识对应不同的事件")
        old_key, new_key = other.get("schedulerKey"), event.get("schedulerKey")
        if old_key and new_key and old_key != new_key:
            raise HTTPException(409, "同一评分对应不同的 FSRS 参数")
        combined = dict(other)
        if new_key and not old_key:
            combined["schedulerKey"] = new_key
        union[event_id] = (at, combined)
    if set(left) != set(right):
        for event_id in left_applied | right_applied:
            if event_id in union and not union[event_id][1].get("schedulerKey"):
                raise HTTPException(409, "旧评分没有算法版本，无法安全合并")
    origin_key = _history_base_key(oh["base"])
    origin_last_review = origin_key[-1] if len(origin_key) > 1 else None
    if origin_last_review and any(pair[0] < origin_last_review for pair in union.values()):
        raise HTTPException(409, "评分时间早于共同起点，无法安全重算")
    events = [pair[1] for _, pair in sorted(union.items(), key=lambda p: (p[1][0], p[0]))]
    ids = set(union)
    # 已完整算出并集的一侧可以直接使用；其他情况按共同起点重算整个并集。
    settled = []
    same_completed = (set(left) == set(right) and not old_card.get("pendingFsrs") and not new_card.get("pendingFsrs")
                      and _fsrs_state_key(old_card.get("fsrs")) == _fsrs_state_key(new_card.get("fsrs")))
    for card, own in ((old_card, left), (new_card, right)):
        verified = _history_replay_verified(card, own)
        if (set(own) == ids and not card.get("pendingFsrs") and ids <= set(card.get("appliedFsrs") or [])
            and (verified or same_completed)):
            settled.append(card)
    if len(settled) == 2 and _fsrs_state_key(settled[0].get("fsrs")) != _fsrs_state_key(settled[1].get("fsrs")):
        raise HTTPException(409, "相同评分历史产生不同结果，请保留两端进度")
    result = dict(settled[0] if settled else selected)
    result["fsrsHistory"] = {"base": oh["base"], "events": events}
    applied = set(old_card.get("appliedFsrs") or []) | set(new_card.get("appliedFsrs") or [])
    if settled:
        result.pop("pendingFsrs", None)
    elif events:
        result["pendingFsrs"] = {"base": oh["base"], "events": events}
        result.pop("fsrsReplayVersions", None)  # 旧客户端不能沿用旧的完成标记。
        applied -= ids
    else:
        result.pop("pendingFsrs", None)
    if applied:
        result["appliedFsrs"] = sorted(applied)
    else:
        result.pop("appliedFsrs", None)
    return result


def _merge_card_replay(old_card, new_card, selected):
    """保留待重放评分；分叉无法安全合并时拒绝写入，不能悄悄丢掉评分。"""
    merged = _merge_histories(old_card, new_card, selected)
    if merged is not None:
        return merged
    old_applied = set(old_card.get("appliedFsrs") or [])
    new_applied = set(new_card.get("appliedFsrs") or [])
    if old_applied and new_applied and not (old_applied <= new_applied or new_applied <= old_applied):
        raise HTTPException(409, "同一单词在不同设备产生了冲突的评分，请先保留两端本地进度")
    applied = old_applied | new_applied
    old_pending, new_pending = old_card.get("pendingFsrs"), new_card.get("pendingFsrs")

    def remaining(pending):
        if not pending:
            return None
        events = pending.get("events") or []
        kept = [e for e in events if e.get("id") not in applied]
        if kept and len(kept) != len(events):
            raise HTTPException(409, "待同步评分已部分应用，无法安全自动合并")
        return {**pending, "events": kept} if kept else None

    op, np = remaining(old_pending), remaining(new_pending)
    result = dict(selected)
    if op and np:
        def base_key(p):
            b = p.get("base") or {}
            return (bool(b.get("is_new")), b.get("state", 1), b.get("stability", 0),
                    b.get("difficulty", 0), b.get("due"), b.get("step"), b.get("last_review"))
        if base_key(op) != base_key(np):
            raise HTTPException(409, "同一单词的离线评分起点不同，无法安全自动合并")
        events = {}
        for event in op["events"] + np["events"]:
            event_id = event.get("id")
            if not event_id or event_id in events and events[event_id] != event:
                raise HTTPException(409, "待同步评分标识无效或冲突")
            events[event_id] = event
        result["pendingFsrs"] = {"base": op["base"], "events": sorted(events.values(), key=lambda e: (e["at"], e["id"]))}
    elif op or np:
        pending = op or np
        other = new_card if op else old_card
        other_fsrs = other.get("fsrs") or {}
        base = pending.get("base") or {}
        # 无待处理队列的一侧只能是同一调度起点，不能覆盖另一侧的离线评分。
        if base.get("is_new"):
            same_base = not other_fsrs
        elif other_fsrs:
            same_base = all(other_fsrs.get(k) == base.get(k) for k in ("state", "stability", "difficulty", "due", "step"))
            same_base = same_base and (other_fsrs.get("lastReview") or other_fsrs.get("last_review")) == base.get("last_review")
        else:
            same_base = False
        if not same_base:
            raise HTTPException(409, "离线评分与另一设备的卡片状态冲突，无法安全自动合并")
        result = dict(old_card if op else new_card)
        result["pendingFsrs"] = pending
    else:
        if old_pending and not op and not new_pending:
            result = dict(new_card)
        elif new_pending and not np and not old_pending:
            result = dict(old_card)
        result.pop("pendingFsrs", None)
    if applied:
        result["appliedFsrs"] = sorted(applied)
    return result


def merge_learning_states(old, new):
    """多设备学习状态字段级合并，避免旧设备整包覆盖新进度。

    规则：
    - log：精确事件计数取最大值（同一事件不重复，真实重复学习不丢失）
    - cards：按该词最近学习日期选较新的卡；同日取活动较多的一侧，平局取新写入
    - posterior/probeCount：新版按共同基线和因果证据重放，旧版保守兼容
    - pointer：同一 frontier 只前进；frontier 变化视为重新定级，接受新游标
    - pendingNew/personalized：按词合并；settings 取新写入的用户意图
    """
    old_schedulers = validate_fsrs_schedulers(old or {})
    new_schedulers = validate_fsrs_schedulers(new or {})
    validate_settings_versions(old or {})
    validate_settings_versions(new or {})
    old_version = validate_placement_version(old or {})
    new_version = validate_placement_version(new or {})
    old_rejected = validate_rejected_personalized(old or {})
    new_rejected = validate_rejected_personalized(new or {})
    validate_personal_versions(old or {})
    validate_personal_versions(new or {})
    validate_knowledge_evidence(old or {})
    validate_knowledge_evidence(new or {})
    validate_band_evidence(old or {})
    validate_band_evidence(new or {})
    old = canonicalize_posterior(old or {})
    new = canonicalize_posterior(new or {})
    validate_streak(old or {})
    validate_streak(new or {})
    if not old:
        return filter_rejected_personalized(new)
    if not new:
        return filter_rejected_personalized(old)
    old_epoch = old.get("restoreEpoch", 0)
    new_epoch = new.get("restoreEpoch", 0)
    if not isinstance(old_epoch, int) or isinstance(old_epoch, bool) or not isinstance(new_epoch, int) or isinstance(new_epoch, bool):
        raise HTTPException(422, "学习状态恢复版本无效")
    if old_epoch != new_epoch:
        raise HTTPException(409, "学习进度已恢复，当前设备版本不同；请先导出本机进度并重新加载")
    import json as _j
    from collections import Counter

    out = dict(new)
    settings, settings_versions = merge_versioned_settings(old, new)
    out["settings"] = settings
    if settings_versions:
        out["settingsVersions"] = settings_versions
    if old_schedulers or new_schedulers:
        out["fsrsSchedulers"] = {**old_schedulers, **new_schedulers}
    old_logs = old.get("log") or []
    new_logs = new.get("log") or []
    merged_logs = merge_log_events(old_logs, new_logs)
    merged_logs.sort(key=lambda x: (x.get("d", ""), x.get("word", ""), x.get("kind", ""), x.get("rating", 0)))
    # 最近 1200 条以外，保留最近三个有学习记录的日期里每词每类型的一条，
    # 防止大量曝光记录挤掉跨设备每日上限所依赖的学习计数。
    from datetime import date as _date
    scored = []
    for index, entry in enumerate(merged_logs):
        if entry.get("kind") not in ("learn", "review", "probe") or not isinstance(entry.get("word"), str):
            continue
        try:
            day = _date.fromisoformat(entry.get("d", ""))
        except (TypeError, ValueError):
            continue
        scored.append((index, day, entry["kind"], entry["word"]))
    days = set(sorted({day for _, day, _, _ in scored})[-3:])
    retained = {}
    for index, day, kind, word in scored:
        if day in days:
            retained[(day, kind, word)] = index
    keep = set(retained.values())
    tail = max(0, len(merged_logs) - 1200)
    out["log"] = [entry for index, entry in enumerate(merged_logs) if index >= tail or index in keep]

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
    # Retain the stored order and append new words. Set iteration can reshuffle
    # unchanged cards when one word is added, rewriting positional segments.
    for w in dict.fromkeys((*old_cards, *new_cards)):
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
            cards[w] = _merge_card_replay(oc, nc, cards[w])
    out["cards"] = cards
    # v2.0 字段：不能像整包替换一样把 bandStats/knowledge 清空或覆盖
    knowledge, knowledge_evidence = merge_knowledge_evidence(old, new)
    out["knowledge"] = knowledge
    if knowledge_evidence: out["knowledgeEvidence"] = knowledge_evidence

    # 后验不能取平均：保留证据更多的一侧。
    # 但重新定级是显式重置：placementResetAt 更新（或新客户端清空 posterior/probeCount）时，
    # 必须接受新后验，绝不能用"旧探测次数更多"把重测撤销。
    old_reset = float(old.get("placementResetAt") or 0)
    new_reset = float(new.get("placementResetAt") or 0)
    if old_version or new_version:
        old_key = (old_version["counter"], old_version["device"], old_version["id"]) if old_version else (0, "", "")
        new_key = (new_version["counter"], new_version["device"], new_version["id"]) if new_version else (0, "", "")
        explicit_reset, stale_reset = new_key > old_key, old_key > new_key
        out["placementVersion"] = new_version if new_key >= old_key else old_version
    else:
        explicit_reset = (new_reset > old_reset or
                          (not old_reset and not new_reset and new.get("posterior") is None and int(new.get("probeCount", 0)) == 0 and old.get("posterior") is not None))
        stale_reset = old_reset > new_reset
    if explicit_reset:
        out["posterior"] = new.get("posterior")
        out["probeCount"] = int(new.get("probeCount", 0))
        out["track"] = new.get("track")
        if not new_version and new_reset <= old_reset:
            out["placementResetAt"] = time.time()
    elif stale_reset or int(old.get("probeCount", 0)) > int(new.get("probeCount", 0)):
        out["posterior"] = old.get("posterior")
        out["probeCount"] = old.get("probeCount", 0)
    else:
        out["posterior"] = new.get("posterior")
        out["probeCount"] = new.get("probeCount", 0)
    # Only histories from the same placement epoch may be combined.
    if explicit_reset or stale_reset:
        selected = new if explicit_reset else old
        if selected.get("posteriorHistory") is None:
            out.pop("posteriorHistory", None)
        else:
            out["posteriorHistory"] = selected["posteriorHistory"]
    else:
        history = merge_posterior(old, new)
        if history is not None:
            out["posteriorHistory"] = history
            out["posterior"], out["probeCount"] = replay_posterior(history)
        else:
            out.pop("posteriorHistory", None)
    if old_version or new_version:
        out["placementResetAt"] = new_reset if explicit_reset else old_reset if stale_reset else max(old_reset, new_reset)
    else:
        out["placementResetAt"] = max(old_reset, float(out.get("placementResetAt") or 0))

    if stale_reset:
        out["frontier"] = old.get("frontier")
        out["pointer"] = old.get("pointer", 1)
        out["track"] = old.get("track")
    elif explicit_reset:
        out["frontier"] = new.get("frontier")
        out["pointer"] = new.get("pointer", 1)
    elif old.get("frontier") == new.get("frontier"):
        out["pointer"] = max(int(old.get("pointer", 1)), int(new.get("pointer", 1)))
    else:
        out["frontier"] = new.get("frontier")
        out["pointer"] = new.get("pointer", 1)
    if stale_reset or explicit_reset:
        source = old if stale_reset else new
        out["bandStats"] = source.get("bandStats")
        out["wrongStreak"] = source.get("wrongStreak", 0)
        if source.get("bandEvidence") is not None: out["bandEvidence"] = source["bandEvidence"]
        else: out.pop("bandEvidence", None)
    else:
        bands, band_evidence = merge_band_evidence(old, new)
        out["bandStats"] = bands
        if band_evidence: out["bandEvidence"] = band_evidence
    validate_band_evidence(out)
    out["calibrated"] = bool((old if stale_reset else new).get("calibrated")) if stale_reset or explicit_reset else bool(old.get("calibrated") or new.get("calibrated"))

    # 已有学习卡的词不再是待学词；合并时也去掉重复项。
    pending, seen = [], set()
    for entry in (old.get("pendingNew") or []) + (new.get("pendingNew") or []):
        word = entry.get("word") if isinstance(entry, dict) else None
        if word and word not in seen and word not in cards:
            pending.append(entry)
            seen.add(word)
    out["pendingNew"] = pending

    personal, personal_versions = merge_versioned_personal(old, new)
    rejected = {word: sorted(set(old_rejected.get(word, [])) | set(new_rejected.get(word, [])))
                for word in old_rejected.keys() | new_rejected.keys()}
    if rejected:
        out["rejectedPersonalized"] = rejected
    out["personalized"] = personal
    if personal_versions: out["personalVersions"] = personal_versions
    out = filter_rejected_personalized(out)
    # 持久化的生成任务按任务 ID 去重，旧设备缺字段不能清空待恢复任务。
    jobs = {j["id"]: j for j in (old.get("personalJobs") or []) if isinstance(j, dict) and j.get("id")}
    for job in new.get("personalJobs") or []:
        if isinstance(job, dict) and job.get("id"):
            previous = jobs.get(job["id"])
            # 已完成或失败的任务不因旧快照回退为待处理。
            if not previous or previous.get("status") not in ("complete", "partial", "failed", "superseded"):
                jobs[job["id"]] = job
    out["personalJobs"] = sorted(jobs.values(), key=lambda j: (j.get("date", ""), j.get("id", "")))[-100:]

    # 同一天验收进度按词合并；较早日期的完成项不能带入新一天。
    progress_day = max(str(old.get("quizProgressDay") or ""), str(new.get("quizProgressDay") or ""))
    if progress_day:
        completed = set()
        for state in (old, new):
            if state.get("quizProgressDay") == progress_day and isinstance(state.get("quizCompleted"), list):
                completed.update(w for w in state["quizCompleted"] if isinstance(w, str))
        out["quizProgressDay"] = progress_day
        out["quizCompleted"] = sorted(completed)

    # 日期型字段取较新；对应计数/说明跟随同一天的一侧
    for field in ("lastDay", "quizDay", "weaveDay", "personalizedDay"):
        if str(old.get(field) or "") > str(new.get(field) or ""):
            out[field] = old.get(field)
            for linked in ("weaveCount", "personalizedWeak"):
                if field == "weaveDay" and linked == "weaveCount" or field == "personalizedDay" and linked == "personalizedWeak":
                    out[linked] = old.get(linked)
    if not explicit_reset and not stale_reset and str((old.get("track") or {}).get("evalDay") or "") > str((new.get("track") or {}).get("evalDay") or ""):
        out["track"] = old.get("track")
    # 连续天数与最后学习日绑定：断签后的新短纪录不能被旧高纪录复活。
    old_day, new_day = str(old.get("lastDay") or ""), str(new.get("lastDay") or "")
    if old_day != new_day:
        latest = old if old_day > new_day else new
        out["streak"] = int(latest.get("streak", 0))
    else:
        out["streak"] = max(int(old.get("streak", 0)), int(new.get("streak", 0)))
    streak_evidence = merge_streak(old, new)
    if streak_evidence is not None:
        out["streakEvidence"] = streak_evidence
        out["lastDay"], out["streak"] = calculate_streak(streak_evidence)
    else:
        out.pop("streakEvidence", None)
    out["v"] = max(int(old.get("v", 1)), int(new.get("v", 1)))
    return out


def checkpoint_learning_state(state):
    """Replace settled histories with validated baselines; callers must advance the epoch."""
    import copy
    validate_knowledge_evidence(state)
    validate_band_evidence(state)
    validate_posterior(state)
    validate_streak(state)
    result = copy.deepcopy(canonicalize_posterior(state))
    cards = result.get("cards") or {}
    if not isinstance(cards, dict):
        raise HTTPException(422, "卡片格式无效")
    for card in cards.values():
        if not isinstance(card, dict):
            raise HTTPException(422, "卡片格式无效")
        if card.get("pendingFsrs"):
            raise HTTPException(409, "存在待重放的评分，请先联网完成同步")
        history = card.get("fsrsHistory")
        if history:
            if not isinstance(history, dict):
                raise HTTPException(409, "评分历史格式无效，请先导出进度")
            events, applied = _card_history_events(card, history)
            if (set(events) != applied or (events and (not isinstance(card.get("fsrs"), dict) or
                not _history_replay_verified(card, events)))):
                raise HTTPException(409, "评分历史尚未完整验证，请先重放或导出进度")
        elif card.get("appliedFsrs") or card.get("fsrsReplayVersions"):
            raise HTTPException(409, "旧评分缺少可验证的完整历史，请先导出进度")
        for field in ("fsrsHistory", "pendingFsrs", "fsrsReplayVersions", "appliedFsrs"):
            card.pop(field, None)
    for field in ("knowledgeEvidence", "bandEvidence", "posteriorHistory", "streakEvidence"):
        result.pop(field, None)
    result, _ = anchor_legacy_evidence(result)
    return result


def mount_auth(app: FastAPI):
    init_users()
    daily_study.mount(app, lambda: USERS_DB, identity_by_token, load_verified_state)

    @app.post("/api/v1/auth/register")
    def register(body: RegisterIn, request: Request):
        check_rate(request, "auth")
        if not USERNAME_RE.match(body.username):
            raise HTTPException(400, "用户名仅允许字母/数字/下划线，3~20 位")
        # Hash before taking the database write lock.
        with password_slot():
            encoded = _PASSWORD_HASHER.hash(body.password)
        conn = sqlite3.connect(USERS_DB, timeout=15)
        try:
            conn.execute("BEGIN IMMEDIATE")
            if conn.execute("SELECT 1 FROM users WHERE username=?", (body.username,)).fetchone():
                raise HTTPException(409, "用户名已被占用")
            uid, account_id = secrets.randbits(52) or 1, secrets.token_hex(16)
            while conn.execute("SELECT 1 FROM users WHERE id=? UNION ALL SELECT 1 FROM user_state WHERE user_id=? UNION ALL SELECT 1 FROM user_state_backups WHERE user_id=? LIMIT 1", (uid, uid, uid)).fetchone():
                uid = secrets.randbits(52) or 1
            conn.execute("INSERT INTO users(id, username, nickname, password_hash, salt, created_at, last_login_at, account_id) VALUES(?,?,?,?,?,?,?,?)",
                         (uid, body.username, body.nickname or body.username, encoded, "", time.time(), time.time(), account_id))
            token = make_token(conn, uid)
            return {"token": token, "user": {"id": uid, "account_id": account_id, "username": body.username, "nickname": body.nickname or body.username}}
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    @app.post("/api/v1/auth/login")
    def login(body: LoginIn, request: Request):
        check_rate(request, "auth")
        # Re-read under the write lock after verification; an account replaced while
        # hashing must never inherit the verified account's new token.
        for _ in range(3):
            read = sqlite3.connect(USERS_DB, timeout=15)
            try:
                row = read.execute("SELECT id, nickname, password_hash, salt, account_id FROM users WHERE username=?", (body.username,)).fetchone()
            finally:
                read.close()
            with password_slot():
                valid, upgrade = verify_password_record(body.password, row)
                encoded = _PASSWORD_HASHER.hash(body.password) if valid and upgrade else None
            if not valid or not row:
                raise HTTPException(401, "用户名或密码错误")
            conn = sqlite3.connect(USERS_DB, timeout=15)
            try:
                conn.execute("BEGIN IMMEDIATE")
                current = conn.execute("SELECT id, nickname, password_hash, salt, account_id FROM users WHERE username=?", (body.username,)).fetchone()
                if current != row:
                    conn.rollback()
                    continue
                if encoded:
                    conn.execute("UPDATE users SET password_hash=?, salt='' WHERE id=? AND account_id=?", (encoded, row[0], row[4]))
                conn.execute("UPDATE users SET last_login_at=? WHERE id=? AND account_id=?", (time.time(), row[0], row[4]))
                token = make_token(conn, row[0])
                return {"token": token, "user": {"id": row[0], "account_id": row[4], "username": body.username, "nickname": row[1]}}
            except Exception:
                conn.rollback()
                raise
            finally:
                conn.close()
        raise HTTPException(409, "账号信息已变化，请重试登录")

    @app.post("/api/v1/auth/logout")
    def logout(authorization: str = Header(default="")):
        if authorization.startswith("Bearer "):
            th = hashlib.sha256(authorization[7:].encode()).hexdigest()
            conn = sqlite3.connect(USERS_DB)
            conn.execute("UPDATE tokens SET revoked=1 WHERE token_hash=?", (th,))
            conn.commit()
            conn.close()
        return {"ok": True}

    def read_stored_account_state(account_id, *, require_legacy_capacity=False):
        """Anchor legacy evidence and read one coherent stored revision.

        This path deliberately does not load the separate scheduler database;
        raw snapshots and their change journal share the stored representation.
        """
        import json as _j
        conn = sqlite3.connect(USERS_DB, timeout=15)
        try:
            conn.execute("BEGIN IMMEDIATE")
            generation = sync_generation(conn)
            row = conn.execute("SELECT state_json, updated_at, state_revision FROM account_state WHERE account_id=?",
                               (account_id,)).fetchone()
            if row:
                validate_state_revision(row[2])
                old_state = load_verified_state(conn, account_id, row[0], row[2])
                if require_legacy_capacity:
                    # Never give an old whole-state client an incomplete or
                    # unrepresentable state. Raw paged snapshots remain usable.
                    serialize_state(old_state)
                state, added = anchor_legacy_evidence(old_state)
                if added:
                    stamp = max(time.time(), row[1] + 0.000001)
                    revision = next_state_revision(row[2])
                    conn.execute("UPDATE account_state SET state_json=?, updated_at=?, state_revision=? WHERE account_id=?",
                                 (serialize_state(state, MAX_LARGE_DELTA_STATE_BYTES if os.environ.get("VOCAB_EXPERIMENTAL_LARGE_DELTAS") == "1" and not require_legacy_capacity else MAX_STATE_BYTES), stamp, revision, account_id))
                    state_segments.write(conn, account_id, revision, state)
                    record_change(conn, account_id, row[2], revision, state.get("restoreEpoch", 0), old_state, state, stamp)
                    row = (None, stamp, revision)
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()
        if not row:
            return {"state": None, "state_revision": "0", "sync_generation":generation}
        return {"state": state, "updated_at": row[1], "state_revision": str(row[2]), "sync_generation":generation}

    def read_enriched_account_state(account_id, *, require_legacy_capacity=False):
        current = read_stored_account_state(account_id, require_legacy_capacity=require_legacy_capacity)
        if current["state"] is not None:
            stored = current["state"]
            current["state"] = enrich_fsrs_schedulers(stored, account_id)
            if require_legacy_capacity and current["state"] is not stored:
                # Scheduler enrichment can itself push a previously valid
                # stored state beyond what whole-state clients can handle.
                serialize_state(current["state"])
        return current

    @app.get("/api/v1/me/state")
    def get_state(authorization: str = Header(default="")):
        identity = identity_by_token(authorization)
        if not identity:
            raise HTTPException(401, "未登录或登录已过期")
        return read_enriched_account_state(identity[1], require_legacy_capacity=True)

    def sync_generation(conn):
        row = conn.execute("SELECT generation FROM sync_metadata WHERE id=1").fetchone()
        if not row or not isinstance(row[0], str) or not re.fullmatch(r"[0-9a-f]{32}", row[0]):
            raise HTTPException(409, "服务器同步代次无效，请联系管理员检查数据库")
        return row[0]

    @app.post("/api/v1/me/fsrs-schedulers/resolve")
    def resolve_scheduler_versions(body: SchedulerResolveIn, request: Request, authorization: str = Header(default="")):
        identity = identity_by_token(authorization)
        if not identity:
            raise HTTPException(401, "未登录或登录已过期")
        check_rate(request, "fsrs_resolve")
        if not re.fullmatch(r"[0-9a-f]{32}", body.generation):
            raise HTTPException(422, "服务器同步代次无效")
        if len(set(body.keys)) != len(body.keys) or any(not re.fullmatch(r"[0-9a-f]{64}", key) for key in body.keys):
            raise HTTPException(422, "FSRS 参数版本标识无效")
        conn = sqlite3.connect(USERS_DB, timeout=15)
        try:
            conn.execute("BEGIN")
            if sync_generation(conn) != body.generation:
                raise HTTPException(409, "服务器同步代次已变化，请重新获取快照")
            row = conn.execute("SELECT state_json,state_revision FROM account_state WHERE account_id=?", (identity[1],)).fetchone()
            state = load_verified_state(conn, identity[1], row[0], validate_state_revision(row[1])) if row else {}
            stored = validate_fsrs_schedulers(state)
        except (sqlite3.Error, json.JSONDecodeError):
            raise HTTPException(503, "无法读取学习状态中的 FSRS 参数")
        finally:
            conn.close()
        versions = {key: stored[key] for key in body.keys if key in stored}
        missing = [key for key in body.keys if key not in versions]
        try:
            rows = load_owned_scheduler_versions(identity[1], missing)
            for key, raw in rows:
                config = normalize_fsrs_config(json.loads(raw))
                if fsrs_config_key(config) != key:
                    raise ValueError("scheduler checksum mismatch")
                versions[key] = config
        except sqlite3.Error:
            raise HTTPException(503, "无法读取 FSRS 参数历史，请保留本地进度")
        except (ValueError, TypeError, OverflowError):
            raise HTTPException(409, "FSRS 参数历史校验失败，请保留本地进度")
        # The parameter database is separate. Recheck after reading it so a
        # database rotation during the lookup cannot validate an old baseline.
        conn = sqlite3.connect(USERS_DB, timeout=15)
        try:
            if sync_generation(conn) != body.generation:
                raise HTTPException(409, "服务器同步代次已变化，请重新获取快照")
        finally:
            conn.close()
        return JSONResponse({"generation":body.generation, "versions":versions,
                             "missing":[key for key in body.keys if key not in versions]},
                            headers={"Cache-Control":"no-store"})

    @app.get("/api/v1/me/state/delta-capabilities")
    def state_delta_capabilities(request: Request, authorization: str = Header(default="")):
        if not identity_by_token(authorization):
            raise HTTPException(401, "未登录或登录已过期")
        check_rate(request, "state_changes")
        enabled = os.environ.get("VOCAB_EXPERIMENTAL_LARGE_DELTAS") == "1"
        return JSONResponse({"append_log_v1": True, "guarded_restore_receipt_v1": True, "guarded_checkpoint_receipt_v1": True, "experimental_large_delta_v1": enabled,
                             "experimental_large_restore_v1": enabled,
                             "experimental_large_checkpoint_v1": enabled}, headers={"Cache-Control": "no-store"})

    @app.get("/api/v1/me/state/changes")
    def read_state_change(request: Request, after: str = Query(), generation: str = Query(), page: int = Query(default=0, ge=0, le=1024), compact: bool = Query(default=False),
                          authorization: str = Header(default="")):
        identity = identity_by_token(authorization)
        if not identity:
            raise HTTPException(401, "未登录或登录已过期")
        check_rate(request, "state_changes")
        if not re.fullmatch(r"[0-9a-f]{32}", generation):
            raise HTTPException(422, "服务器同步代次无效")
        if not re.fullmatch(r"0|[1-9][0-9]{0,18}", after) or int(after) > 2**63 - 1:
            raise HTTPException(422, "学习状态修订号无效")
        base = int(after)
        verification_stamp = state_verification_cache.stamp(USERS_DB)
        conn = sqlite3.connect(USERS_DB, timeout=15)
        try:
            conn.execute("BEGIN")
            actual_generation = sync_generation(conn)
            if actual_generation != generation:
                raise HTTPException(409, "服务器同步代次已变化，请重新获取快照")
            current = conn.execute("SELECT state_revision FROM account_state WHERE account_id=?", (identity[1],)).fetchone()
            head = validate_state_revision(current[0]) if current else 0
            epoch = state_verification_cache.lookup(verification_stamp, identity[1], head) if current else 0
            if epoch is None:
                raw = conn.execute("SELECT state_json FROM account_state WHERE account_id=?", (identity[1],)).fetchone()[0]
                state = load_verified_state(conn, identity[1], raw, head)
                if not isinstance(state, dict):
                    raise HTTPException(409, "学习状态格式无效，请先导出并联系管理员")
                epoch = state.get("restoreEpoch", 0)
                if type(epoch) is not int or not 0 <= epoch <= 2**53 - 1:
                    raise HTTPException(409, "学习状态恢复版本无效，请先导出并联系管理员")
                state_verification_cache.remember(verification_stamp, identity[1], head, epoch)
            if base > head:
                raise HTTPException(409, "服务器版本已回退，请重新获取快照")
            if base == head:
                if page:
                    raise HTTPException(416, "变更页码超出范围")
                return JSONResponse({"generation":actual_generation, "head_revision":str(head), "change":None}, headers={"Cache-Control":"no-store"})
            row = conn.execute("""SELECT revision,base_revision,restore_epoch,reset,length(payload),digest,
                                  substr(payload,?,?),created_at FROM account_state_changes WHERE account_id=? AND revision=?""",
                               (page * CHANGE_PAGE_BYTES + 1, CHANGE_PAGE_BYTES, identity[1], base + 1)).fetchone()
            if row and compact:
                alternative = conn.execute("""SELECT length(payload),digest,substr(payload,?,?)
                    FROM account_state_change_compact WHERE account_id=? AND revision=?""",
                    (page * CHANGE_PAGE_BYTES + 1, CHANGE_PAGE_BYTES, identity[1], base + 1)).fetchone()
                if alternative:
                    row = (*row[:4], *alternative, row[7])
            if not row or row[1] != base:
                raise HTTPException(410, "所需变更已过期，请重新获取快照")
            if row[3] or row[2] != epoch:
                raise HTTPException(409, "进度已重置或变更过大，请重新获取快照")
            if not row[4]:
                raise HTTPException(410, "所需变更已过期，请重新获取快照")
            count = (row[4] + CHANGE_PAGE_BYTES - 1) // CHANGE_PAGE_BYTES
            if page >= count:
                raise HTTPException(416, "变更页码超出范围")
            return JSONResponse({"generation":actual_generation, "head_revision":str(head), "change":{"base_revision":str(row[1]),
                    "revision":str(row[0]), "restore_epoch":row[2], "byte_length":row[4],
                    "page_bytes":CHANGE_PAGE_BYTES, "page_count":count, "page":page,
                    "sha256":row[5], "updated_at":row[7], "data":base64.b64encode(row[6]).decode('ascii')}},
                    headers={"Cache-Control":"no-store"})
        finally:
            conn.close()

    def snapshot_manifest(snapshot_id, revision, epoch, length, digest, expires_at, representation, generation):
        return JSONResponse({"snapshot_id":snapshot_id, "state_revision":str(revision), "restore_epoch":epoch,
                             "byte_length":length, "page_bytes":SNAPSHOT_PAGE_BYTES,
                             "page_count":(length + SNAPSHOT_PAGE_BYTES - 1) // SNAPSHOT_PAGE_BYTES,
                             "sha256":digest, "expires_at":expires_at, "representation":representation,
                             "generation":generation}, headers={"Cache-Control":"no-store"})

    def replay_snapshot(conn, account_id, request_key, representation):
        if request_key is None:
            return None
        row = conn.execute("""SELECT snapshot_id,state_revision,restore_epoch,length(payload),digest,expires_at,retired,representation
                              FROM account_state_snapshots WHERE account_id=? AND request_key=?""",
                           (account_id, request_key)).fetchone()
        if row is None:
            return None
        if row[7] != representation:
            raise HTTPException(409, "请求标识已用于其他快照类型，请使用新的请求标识")
        if row[5] <= time.time():
            raise HTTPException(410, "快照已过期，请使用新的请求标识重新创建")
        current = conn.execute("SELECT json_type(state_json, '$.restoreEpoch'), json_extract(state_json, '$.restoreEpoch') FROM account_state WHERE account_id=?", (account_id,)).fetchone()
        epoch_type, epoch = current if current else (None, None)
        if epoch_type is None:
            epoch = 0
        if epoch_type not in (None, "integer") or epoch != row[2]:
            raise HTTPException(409, "进度已恢复或整理，请使用新的请求标识重新创建快照")
        if row[6]:
            raise HTTPException(410, "快照已释放，请使用新的请求标识重新创建")
        return snapshot_manifest(*row[:6], row[7], sync_generation(conn))

    @app.post("/api/v1/me/state/snapshots")
    def create_state_snapshot(request: Request, authorization: str = Header(default=""),
                              idempotency_key: str | None = Header(default=None),
                              representation: str = Query(default="enriched")):
        identity = identity_by_token(authorization)
        if not identity:
            raise HTTPException(401, "未登录或登录已过期")
        check_rate(request, "snapshot")
        account_id = identity[1]
        if representation not in ("enriched", "stored"):
            raise HTTPException(422, "快照类型无效")
        if idempotency_key is not None and not re.fullmatch(r"[0-9a-f]{32}", idempotency_key):
            raise HTTPException(422, "请求标识必须是 32 位小写十六进制字符")
        if idempotency_key is not None:
            conn = sqlite3.connect(USERS_DB, timeout=15)
            try:
                conn.execute("BEGIN")
                replay = replay_snapshot(conn, account_id, idempotency_key, representation)
            finally:
                conn.close()
            if replay is not None:
                return replay
        # Both representations anchor legacy evidence first. Stored snapshots
        # read that revision directly; only enriched snapshots consult the
        # separate scheduler database. The insertion transaction verifies that
        # the pinned revision and generation have not changed in the meantime.
        if representation == "stored":
            current = read_stored_account_state(account_id)
        else:
            # Preserve the second session check previously performed by GET.
            if identity_by_token(authorization) != identity:
                raise HTTPException(401, "未登录或登录已过期")
            current = read_enriched_account_state(account_id)
        state = current.get("state")
        epoch = state.get("restoreEpoch", 0) if state is not None else 0
        if not isinstance(epoch, int) or isinstance(epoch, bool) or not 0 <= epoch <= 2**53 - 1:
            raise HTTPException(409, "学习状态恢复版本无效，请先导出并检查进度")
        try:
            payload = json.dumps(current, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")
        except (ValueError, TypeError):
            raise HTTPException(422, "学习状态包含无效数据")
        if len(payload) > SNAPSHOT_MAX_BYTES:
            raise HTTPException(413, "学习状态超过快照大小上限，请先导出并联系管理员")
        snapshot_id = secrets.token_hex(16)
        digest = hashlib.sha256(payload).hexdigest()
        conn = sqlite3.connect(USERS_DB, timeout=15)
        try:
            conn.execute("BEGIN IMMEDIATE")
            generation = sync_generation(conn)
            if generation != current["sync_generation"]:
                raise HTTPException(409, "服务器同步代次已变化，请重新创建快照")
            replay = replay_snapshot(conn, account_id, idempotency_key, representation)
            if replay is not None:
                conn.commit()
                return replay
            row = conn.execute("SELECT state_revision FROM account_state WHERE account_id=?", (account_id,)).fetchone()
            revision = validate_state_revision(row[0]) if row else 0
            if str(revision) != current["state_revision"]:
                raise HTTPException(409, "服务器进度已变化，请重新创建快照")
            now = time.time()
            conn.execute("DELETE FROM account_state_snapshots WHERE expires_at<=?", (now,))
            # Retain a small tombstone for keyed snapshots until their original
            # expiry, so a delayed retry cannot silently create a new snapshot.
            conn.execute("UPDATE account_state_snapshots SET retired=1,payload=X'' WHERE account_id=? AND restore_epoch!=? AND request_key IS NOT NULL", (account_id, epoch))
            conn.execute("DELETE FROM account_state_snapshots WHERE account_id=? AND restore_epoch!=? AND request_key IS NULL", (account_id, epoch))
            if idempotency_key is not None:
                keys = conn.execute("SELECT count(*) FROM account_state_snapshots WHERE account_id=? AND request_key IS NOT NULL", (account_id,)).fetchone()[0]
                if keys >= SNAPSHOT_MAX_KEYS_PER_ACCOUNT:
                    conn.commit()
                    raise HTTPException(429, "快照请求标识过多，请稍后重试")
            count = conn.execute("SELECT count(*) FROM account_state_snapshots WHERE account_id=? AND retired=0", (account_id,)).fetchone()[0]
            if count >= SNAPSHOT_MAX_PER_ACCOUNT:
                conn.commit()  # Preserve expiry cleanup even when the quota rejects this request.
                raise HTTPException(429, "当前账号的快照过多，请先释放或稍后重试")
            total = conn.execute("SELECT coalesce(sum(length(payload)),0) FROM account_state_snapshots").fetchone()[0]
            if total + len(payload) > SNAPSHOT_GLOBAL_BYTES:
                conn.commit()
                raise HTTPException(503, "快照服务繁忙，请稍后重试")
            conn.execute("""INSERT INTO account_state_snapshots(snapshot_id,account_id,state_revision,restore_epoch,payload,digest,created_at,expires_at,request_key,representation)
                            VALUES(?,?,?,?,?,?,?,?,?,?)""",
                         (snapshot_id, account_id, revision, epoch, payload, digest, now, now + SNAPSHOT_TTL_SECONDS, idempotency_key, representation))
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()
        return snapshot_manifest(snapshot_id, revision, epoch, len(payload), digest, now + SNAPSHOT_TTL_SECONDS, representation, generation)

    @app.get("/api/v1/me/state/snapshots/{snapshot_id}")
    def read_state_snapshot(snapshot_id: str, request: Request, page: int = Query(ge=0, le=1024), authorization: str = Header(default="")):
        identity = identity_by_token(authorization)
        if not identity:
            raise HTTPException(401, "未登录或登录已过期")
        check_rate(request, "snapshot_read")
        if not re.fullmatch(r"[0-9a-f]{32}", snapshot_id):
            raise HTTPException(404, "快照不存在或已过期")
        account_id = identity[1]
        conn = sqlite3.connect(USERS_DB, timeout=15)
        try:
            conn.execute("BEGIN")
            row = conn.execute("""SELECT state_revision,restore_epoch,length(payload),expires_at,substr(payload,?,?)
                                  FROM account_state_snapshots WHERE snapshot_id=? AND account_id=? AND retired=0""",
                               (page * SNAPSHOT_PAGE_BYTES + 1, SNAPSHOT_PAGE_BYTES, snapshot_id, account_id)).fetchone()
            current = conn.execute("SELECT json_type(state_json, '$.restoreEpoch'), json_extract(state_json, '$.restoreEpoch') FROM account_state WHERE account_id=?", (account_id,)).fetchone()
            conn.commit()
        finally:
            conn.close()
        if not row or row[3] <= time.time():
            raise HTTPException(404, "快照不存在或已过期")
        epoch_type, current_epoch = current if current else (None, None)
        if epoch_type is None:
            current_epoch = 0
        if epoch_type not in (None, "integer") or current_epoch != row[1]:
            raise HTTPException(409, "进度已恢复或整理，请重新创建快照")
        count = (row[2] + SNAPSHOT_PAGE_BYTES - 1) // SNAPSHOT_PAGE_BYTES
        if page >= count:
            raise HTTPException(416, "快照页码超出范围")
        part = row[4]
        return JSONResponse({"snapshot_id":snapshot_id, "page":page,
                             "data":base64.b64encode(part).decode("ascii")},
                            headers={"Cache-Control":"no-store"})

    @app.delete("/api/v1/me/state/snapshots/{snapshot_id}")
    def delete_state_snapshot(snapshot_id: str, authorization: str = Header(default="")):
        identity = identity_by_token(authorization)
        if not identity:
            raise HTTPException(401, "未登录或登录已过期")
        if not re.fullmatch(r"[0-9a-f]{32}", snapshot_id):
            raise HTTPException(404, "快照不存在或已过期")
        conn = sqlite3.connect(USERS_DB, timeout=15)
        try:
            conn.execute("BEGIN IMMEDIATE")
            deleted = conn.execute("UPDATE account_state_snapshots SET retired=1,payload=X'' WHERE snapshot_id=? AND account_id=? AND request_key IS NOT NULL AND retired=0", (snapshot_id, identity[1])).rowcount
            if not deleted:
                deleted = conn.execute("DELETE FROM account_state_snapshots WHERE snapshot_id=? AND account_id=? AND request_key IS NULL AND retired=0", (snapshot_id, identity[1])).rowcount
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()
        if not deleted:
            raise HTTPException(404, "快照不存在或已过期")
        return JSONResponse({"ok":True}, headers={"Cache-Control":"no-store"})

    @app.get("/api/v1/me/fsrs-schedulers")
    def scheduler_backups(authorization: str = Header(default="")):
        identity = identity_by_token(authorization)
        if not identity:
            raise HTTPException(401, "未登录或登录已过期")
        _, account_id = identity
        import json as _j
        from app.main import PERSONAL_DB
        with sqlite3.connect(USERS_DB, timeout=15) as conn:
            conn.execute("BEGIN")
            row = conn.execute("SELECT state_json,state_revision FROM account_state WHERE account_id=?", (account_id,)).fetchone()
            state = load_verified_state(conn, account_id, row[0], validate_state_revision(row[1])) if row else {}
        versions = validate_fsrs_schedulers(state)
        try:
            with sqlite3.connect(PERSONAL_DB, timeout=15) as conn:
                rows = conn.execute("SELECT scheduler_key, config_json FROM fsrs_scheduler_versions WHERE owner=? LIMIT 257", (f"account:{account_id}",)).fetchall()
            for key, raw in rows:
                config = normalize_fsrs_config(_j.loads(raw))
                if fsrs_config_key(config) != key:
                    raise ValueError("snapshot hash mismatch")
                versions[key] = config
            if len(versions) > 256:
                raise HTTPException(413, "FSRS 参数版本过多，无法自动打包备份")
            return {"versions": versions}
        except sqlite3.Error:
            raise HTTPException(503, "读取 FSRS 参数备份失败")
        except (ValueError, TypeError, OverflowError):
            raise HTTPException(409, "FSRS 参数备份校验失败")

    def submit_state_delta_impl(body: dict, request: Request, authorization: str, staged=False, rate_checked=False, stage_nonce=None, stage_digest=None, large=False):
        identity = identity_by_token(authorization)
        if not identity:
            raise HTTPException(401, "未登录或登录已过期")
        if not rate_checked: check_rate(request, "state_delta_write")
        if set(body) != {"generation", "base_revision", "restore_epoch", "batch_id", "ops"}:
            raise HTTPException(422, "增量批次字段无效")
        generation, base, epoch, batch = (body[k] for k in ("generation", "base_revision", "restore_epoch", "batch_id"))
        if not isinstance(generation, str) or not re.fullmatch(r"[0-9a-f]{32}", generation):
            raise HTTPException(422, "服务器同步代次无效")
        if not isinstance(batch, str) or not re.fullmatch(r"[0-9a-f]{32}", batch):
            raise HTTPException(422, "增量批次标识无效")
        if not isinstance(base, str) or not re.fullmatch(r"0|[1-9][0-9]{0,18}", base) or int(base) > 2**63 - 1:
            raise HTTPException(422, "学习状态修订号无效")
        if type(epoch) is not int or not 0 <= epoch <= 2**53 - 1:
            raise HTTPException(422, "学习状态恢复版本无效")
        try:
            validate_upload_ops(body["ops"], max_operations=MAX_STAGED_OPERATIONS if staged else 2048)
            if large and any(not op['path'] for op in body['ops']):
                raise ValueError('large incremental endpoint requires a baseline')
            encoded_request = json.dumps(body, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
        except (ValueError, TypeError, UnicodeError, RecursionError):
            raise HTTPException(422, "增量批次格式无效")
        if len(encoded_request) > (delta_staging.MAX_BYTES + 1024 if staged else DELTA_MAX_BYTES):
            raise HTTPException(413, "增量批次超过大小上限，请拆分后重试")
        request_hash = hashlib.sha256((b'large-delta-v1\0' if large else b'') + encoded_request).hexdigest()
        account_id = identity[1]
        conn = sqlite3.connect(USERS_DB, timeout=15)
        try:
            conn.execute("BEGIN IMMEDIATE")
            if staged:
                stage = conn.execute("""SELECT generation,base_revision,restore_epoch,digest,expires_at,stage_nonce
                    FROM account_delta_stages WHERE account_id=? AND batch_id=?""", (account_id,batch)).fetchone()
                if not stage or stage[5] != stage_nonce: raise HTTPException(404, "增量暂存已删除或替换")
                if stage[4] <= time.time(): raise HTTPException(410, "增量暂存已过期")
                if stage[:4] != (generation,base,epoch,stage_digest): raise HTTPException(409, "增量暂存清单已变化")
            if sync_generation(conn) != generation:
                raise HTTPException(409, "服务器同步代次已变化，请重新获取快照")
            row = conn.execute("SELECT state_json,updated_at,state_revision FROM account_state WHERE account_id=?", (account_id,)).fetchone()
            current_revision = validate_state_revision(row[2]) if row else 0
            old_state = load_verified_state(conn, account_id, row[0], current_revision) if row else None
            current_epoch = old_state.get("restoreEpoch", 0) if old_state is not None else 0
            if type(current_epoch) is not int or not 0 <= current_epoch <= 2**53 - 1 or current_epoch != epoch:
                raise HTTPException(409, "学习进度已恢复或整理，请先导出并重新同步")
            if conn.execute("SELECT 1 FROM account_restore_receipts WHERE account_id=? AND batch_id=? AND created_at>?",
                            (account_id, batch, time.time() - DELTA_RECEIPT_TTL)).fetchone():
                raise HTTPException(409, "批次标识已用于恢复")
            if conn.execute("SELECT 1 FROM account_checkpoint_receipts WHERE account_id=? AND batch_id=? AND created_at>?",
                            (account_id, batch, time.time() - DELTA_RECEIPT_TTL)).fetchone():
                raise HTTPException(409, "批次标识已用于历史整理")
            receipt = conn.execute("SELECT request_hash,generation,revision,restore_epoch,updated_at,created_at FROM account_state_batches WHERE account_id=? AND batch_id=?", (account_id, batch)).fetchone()
            if receipt and receipt[5] <= time.time() - DELTA_RECEIPT_TTL:
                receipt = None  # Expiry is effective even when no cleanup ran.
            if receipt:
                if receipt[0] != request_hash or receipt[1] != generation or receipt[3] != epoch:
                    raise HTTPException(409, "增量批次标识已用于不同内容")
                conn.commit()
                return JSONResponse({"ok":True, "batch_id":batch, "generation":generation,
                    "state_revision":str(receipt[2]), "restore_epoch":epoch, "updated_at":receipt[4]}, headers={"Cache-Control":"no-store"})
            if current_revision != int(base):
                raise HTTPException(409, {"code":"BASE_REVISION_CONFLICT", "message":"服务器进度已变化，请重新同步后重试"})
            if large and old_state is None:
                raise HTTPException(409, "大状态增量提交需要已有基线")
            state_limit = MAX_LARGE_DELTA_STATE_BYTES if large else MAX_STATE_BYTES
            if old_state is not None: serialize_state(old_state, state_limit)
            try:
                candidate = apply_upload_ops(old_state, body["ops"])
            except (ValueError, TypeError, RecursionError):
                raise HTTPException(422, "增量批次无法应用于当前基线")
            if "__proto__" in candidate:
                raise HTTPException(422, "增量批次包含无效字段")
            candidate_epoch = candidate.get("restoreEpoch", 0)
            if type(candidate_epoch) is not int or candidate_epoch != epoch:
                raise HTTPException(409, "增量批次不能更改恢复版本")
            candidate = prepare_uploaded_state(candidate, state_limit)
            merged = merge_learning_states(old_state, candidate) if row else candidate
            validate_fsrs_schedulers(merged)
            anchor_streak(merged)  # Reject an unanchorable merged legacy pair before commit.
            encoded = serialize_state(merged, state_limit)
            updated_at = max(time.time(), row[1] + 0.000001) if row else time.time()
            revision = next_state_revision(row[2]) if row else 1
            conn.execute("""INSERT INTO account_state(account_id,state_json,updated_at,state_revision) VALUES(?,?,?,?)
                            ON CONFLICT(account_id) DO UPDATE SET state_json=excluded.state_json,
                            updated_at=excluded.updated_at,state_revision=excluded.state_revision""",
                         (account_id, encoded, updated_at, revision))
            state_segments.write(conn, account_id, revision, merged)
            record_change(conn, account_id, current_revision, revision, epoch, old_state, merged, updated_at)
            now = time.time()
            conn.execute("DELETE FROM account_state_batches WHERE created_at<=?", (now - DELTA_RECEIPT_TTL,))
            conn.execute("""INSERT INTO account_state_batches(account_id,batch_id,request_hash,generation,base_revision,revision,restore_epoch,updated_at,created_at)
                            VALUES(?,?,?,?,?,?,?,?,?)""", (account_id, batch, request_hash, generation, current_revision, revision, epoch, updated_at, now))
            conn.execute("""DELETE FROM account_state_batches WHERE account_id=? AND batch_id NOT IN
                            (SELECT batch_id FROM account_state_batches WHERE account_id=? ORDER BY created_at DESC,rowid DESC LIMIT ?)""",
                         (account_id, account_id, DELTA_MAX_RECEIPTS))
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()
        return JSONResponse({"ok":True, "batch_id":batch, "generation":generation,
            "state_revision":str(revision), "restore_epoch":epoch, "updated_at":updated_at}, headers={"Cache-Control":"no-store"})

    @app.post("/api/v1/me/state/deltas")
    def submit_state_delta(body: dict, request: Request, authorization: str = Header(default="")):
        return submit_state_delta_impl(body, request, authorization)

    @app.post("/api/v1/me/state/experimental-large-deltas")
    def submit_experimental_large_delta(body: dict, request: Request, authorization: str = Header(default="")):
        if os.environ.get("VOCAB_EXPERIMENTAL_LARGE_DELTAS") != "1":
            raise HTTPException(404, "未启用实验性大状态增量提交")
        return submit_state_delta_impl(body, request, authorization, large=True)

    @app.post("/api/v1/me/state/delta-stages")
    def create_delta_stage(body: dict, request: Request, authorization: str = Header(default="")):
        identity = identity_by_token(authorization)
        if not identity: raise HTTPException(401, "未登录或登录已过期")
        check_rate(request, "state_delta_write")
        def verify(conn, generation, revision, epoch, require_base):
            if sync_generation(conn) != generation: raise HTTPException(409, "服务器同步代次已变化")
            row = conn.execute("SELECT state_json,state_revision FROM account_state WHERE account_id=?", (identity[1],)).fetchone()
            state = load_verified_state(conn, identity[1], row[0], validate_state_revision(row[1])) if row else None
            current_epoch = state.get("restoreEpoch", 0) if state is not None else 0
            current_revision = validate_state_revision(row[1]) if row else 0
            if type(current_epoch) is not int or current_epoch != epoch: raise HTTPException(409, "学习进度已恢复或整理")
            if require_base and current_revision != int(revision): raise HTTPException(409, {"code":"BASE_REVISION_CONFLICT", "message":"服务器进度已变化，请重新同步后重试"})
        result = delta_staging.create(USERS_DB, identity[1], body, verify)
        return JSONResponse({**result, "max_operations":MAX_STAGED_OPERATIONS}, headers={"Cache-Control":"no-store"})

    @app.put("/api/v1/me/state/delta-stages/{batch_id}/parts/{part}")
    def put_delta_stage_part(batch_id: str, part: int, body: dict, request: Request, authorization: str = Header(default="")):
        identity = identity_by_token(authorization)
        if not identity: raise HTTPException(401, "未登录或登录已过期")
        check_rate(request, "state_delta_write")
        return JSONResponse(delta_staging.put(USERS_DB, identity[1], batch_id, part, body), headers={"Cache-Control":"no-store"})

    @app.delete("/api/v1/me/state/delta-stages/{batch_id}")
    def delete_delta_stage(batch_id: str, request: Request, authorization: str = Header(default="")):
        identity = identity_by_token(authorization)
        if not identity: raise HTTPException(401, "未登录或登录已过期")
        check_rate(request, "state_delta_write")
        return JSONResponse(delta_staging.delete(USERS_DB, identity[1], batch_id), headers={"Cache-Control":"no-store"})

    def commit_delta_stage_impl(batch_id: str, request: Request, authorization: str, large=False):
        identity = identity_by_token(authorization)
        if not identity: raise HTTPException(401, "未登录或登录已过期")
        check_rate(request, "state_delta_write")
        manifest, payload, stage_nonce = delta_staging.assemble(USERS_DB, identity[1], batch_id)
        def unique_pairs(pairs):
            value = {}
            for key, item in pairs:
                if key in value: raise ValueError("duplicate key")
                value[key] = item
            return value
        def invalid_constant(_): raise ValueError("invalid number")
        try:
            operations = json.loads(payload.decode("utf-8"), object_pairs_hook=unique_pairs, parse_constant=invalid_constant)
        except (ValueError, UnicodeError, RecursionError):
            raise HTTPException(422, "增量暂存内容无效")
        return submit_state_delta_impl({**manifest, "ops":operations}, request, authorization, staged=True, rate_checked=True, stage_nonce=stage_nonce, stage_digest=hashlib.sha256(payload).hexdigest(), large=large)

    @app.post("/api/v1/me/state/delta-stages/{batch_id}/commit")
    def commit_delta_stage(batch_id: str, request: Request, authorization: str = Header(default="")):
        return commit_delta_stage_impl(batch_id, request, authorization)

    @app.post("/api/v1/me/state/delta-stages/{batch_id}/experimental-large-commit")
    def commit_experimental_large_delta_stage(batch_id: str, request: Request, authorization: str = Header(default="")):
        if os.environ.get("VOCAB_EXPERIMENTAL_LARGE_DELTAS") != "1":
            raise HTTPException(404, "未启用实验性大状态增量提交")
        return commit_delta_stage_impl(batch_id, request, authorization, large=True)

    def merge_uploaded_state(body, account_id, expected_generation=None, expected_epoch=None):
        body = prepare_uploaded_state(body)  # 先拒绝过大的输入，避免持锁执行无效合并。
        conn = sqlite3.connect(USERS_DB, timeout=15)
        try:
            # 锁住整个读、合并、写入过程，避免并发请求读到同一旧快照。
            conn.execute("BEGIN IMMEDIATE")
            if expected_generation is not None and sync_generation(conn) != expected_generation:
                raise HTTPException(409, "服务器同步代次已变化，请先导出本机进度并重新加载")
            row = conn.execute("SELECT state_json, updated_at, state_revision FROM account_state WHERE account_id=?", (account_id,)).fetchone()
            old_state = load_verified_state(conn, account_id, row[0], validate_state_revision(row[2])) if row else None
            if expected_generation is not None:
                epoch = old_state.get("restoreEpoch", 0) if old_state is not None else 0
                new_epoch = body.get("restoreEpoch", 0)
                if type(epoch) is not int or type(new_epoch) is not int or epoch != expected_epoch or new_epoch != expected_epoch:
                    raise HTTPException(409, "学习进度已恢复或整理，请先导出并重新加载")
            if row:
                # A legacy write cannot represent the complete large baseline,
                # even if its proposed merged output happens to be smaller.
                serialize_state(old_state)
                body = merge_learning_states(old_state, body)
            validate_fsrs_schedulers(body)  # 合并后的版本数量也必须符合上限。
            anchor_streak(body)  # 快照读取必须能为旧连续天数建立基线。
            encoded = serialize_state(body)  # 两份合并后的大小也要检查；失败必须回滚。
            updated_at = max(time.time(), row[1] + 0.000001) if row else time.time()
            revision = next_state_revision(row[2]) if row else 1
            conn.execute("""INSERT INTO account_state(account_id, state_json, updated_at, state_revision) VALUES(?,?,?,?)
                            ON CONFLICT(account_id) DO UPDATE SET state_json=excluded.state_json,
                            updated_at=excluded.updated_at, state_revision=excluded.state_revision""",
                         (account_id, encoded, updated_at, revision))
            state_segments.write(conn, account_id, revision, body)
            record_change(conn, account_id, row[2] if row else 0, revision, body.get("restoreEpoch", 0), old_state, body, updated_at)
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()
        return {"ok": True, "updated_at": updated_at, "state_revision": str(revision)}

    @app.put("/api/v1/me/state")
    def put_state(body: dict, authorization: str = Header(default="")):
        identity = identity_by_token(authorization)
        if not identity:
            raise HTTPException(401, "未登录或登录已过期")
        return merge_uploaded_state(body, identity[1])

    @app.post("/api/v1/me/state/guarded-merge")
    def guarded_merge_state(body: dict, request: Request, authorization: str = Header(default="")):
        identity = identity_by_token(authorization)
        if not identity:
            raise HTTPException(401, "未登录或登录已过期")
        check_rate(request, "state_delta_write")
        if set(body) != {"generation", "restore_epoch", "state"} or not isinstance(body["state"], dict):
            raise HTTPException(422, "同步请求格式无效")
        generation, epoch = body["generation"], body["restore_epoch"]
        if not isinstance(generation, str) or not re.fullmatch(r"[0-9a-f]{32}", generation) or type(epoch) is not int or not 0 <= epoch <= 2**53 - 1:
            raise HTTPException(422, "同步代次或恢复版本无效")
        result = merge_uploaded_state(body["state"], identity[1], generation, epoch)
        return JSONResponse({**result, "generation":generation, "restore_epoch":epoch}, headers={"Cache-Control":"no-store"})

    @app.post("/api/v1/me/state/checkpoint")
    def checkpoint_state(body: CheckpointIn, authorization: str = Header(default="")):
        identity = identity_by_token(authorization)
        if not identity:
            raise HTTPException(401, "未登录或登录已过期")
        import json as _j
        account_id = identity[1]
        conn = sqlite3.connect(USERS_DB, timeout=15)
        try:
            conn.execute("BEGIN IMMEDIATE")
            if isinstance(body, GuardedCheckpointIn):
                if not re.fullmatch(r"[0-9a-f]{32}", body.generation) or not re.fullmatch(r"0|[1-9][0-9]{0,18}", body.state_revision) or int(body.state_revision) > 2**63 - 1:
                    raise HTTPException(422, "同步代次或修订号无效")
                if sync_generation(conn) != body.generation:
                    raise HTTPException(409, "服务器同步代次已变化，请重新预览")
            row = conn.execute("SELECT state_json, updated_at, state_revision FROM account_state WHERE account_id=?", (account_id,)).fetchone()
            if isinstance(body, GuardedCheckpointIn) and str(validate_state_revision(row[2]) if row else 0) != body.state_revision:
                raise HTTPException(409, "服务器进度已变化，请重新同步后再整理")
            if not row or row[1] != body.expected_updated_at:
                raise HTTPException(409, "服务器进度已变化，请重新同步后再整理")
            old = load_verified_state(conn, account_id, row[0], validate_state_revision(row[2]))
            serialize_state(old)  # Legacy checkpoint cannot replace an oversized baseline.
            epoch = old.get("restoreEpoch", 0)
            if not isinstance(epoch, int) or isinstance(epoch, bool) or not 0 <= epoch < 2**53 - 1:
                raise HTTPException(409, "服务器恢复版本无效，请先检查原存档")
            compacted = checkpoint_learning_state(old)
            compacted["restoreEpoch"] = epoch + 1
            encoded = serialize_state(compacted)
            now = max(time.time(), row[1] + 0.000001)
            conn.execute("INSERT INTO account_state_backups(account_id, state_json, created_at, reason) VALUES(?,?,?,?)", (account_id, row[0], now, "before_checkpoint"))
            revision = next_state_revision(row[2])
            conn.execute("UPDATE account_state SET state_json=?, updated_at=?, state_revision=? WHERE account_id=?", (encoded, now, revision, account_id))
            state_segments.write(conn, account_id, revision, compacted)
            record_change(conn, account_id, row[2], revision, compacted["restoreEpoch"], old, compacted, now, reset=True)
            conn.commit()
            return {"state": compacted, "updated_at": now, "state_revision": str(revision)}
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    @app.post("/api/v1/me/state/guarded-checkpoint")
    def guarded_checkpoint_state(body: GuardedCheckpointIn, authorization: str = Header(default="")):
        return checkpoint_state(body, authorization)

    def checkpoint_receipt_preview(body: dict, request: Request, authorization: str, max_bytes: int):
        identity = identity_by_token(authorization)
        if not identity: raise HTTPException(401, "未登录或登录已过期")
        check_rate(request, "state_changes")
        if set(body) != {"generation", "base_revision", "restore_epoch"}:
            raise HTTPException(422, "整理预览字段无效")
        generation, base, epoch = (body[key] for key in ("generation", "base_revision", "restore_epoch"))
        if not isinstance(generation, str) or not re.fullmatch(r"[0-9a-f]{32}", generation) or not isinstance(base, str) or not re.fullmatch(r"0|[1-9][0-9]{0,18}", base) or int(base) >= 2**63 - 1 or type(epoch) is not int or not 0 <= epoch < 2**53 - 1:
            raise HTTPException(422, "整理预览版本无效")
        with sqlite3.connect(USERS_DB, timeout=15) as conn:
            conn.execute("BEGIN")
            if sync_generation(conn) != generation: raise HTTPException(409, "服务器同步代次已变化，请重新预览")
            row = conn.execute("SELECT state_json,state_revision FROM account_state WHERE account_id=?", (identity[1],)).fetchone()
            if not row or validate_state_revision(row[1]) != int(base): raise HTTPException(409, "服务器进度已变化，请先同步后再整理")
            old = load_verified_state(conn, identity[1], row[0], row[1]); serialize_state(old, max_bytes)
            if type(old.get("restoreEpoch", 0)) is not int or old.get("restoreEpoch", 0) != epoch:
                raise HTTPException(409, "学习进度已恢复或整理，请重新同步")
            compacted = checkpoint_learning_state(old); compacted["restoreEpoch"] = epoch + 1
            serialize_state(compacted, max_bytes)
            conn.commit()
        return JSONResponse({"ok":True, "generation":generation, "base_revision":base, "restore_epoch":epoch}, headers={"Cache-Control":"no-store"})

    @app.post("/api/v1/me/state/guarded-checkpoint-receipt-preview")
    def guarded_checkpoint_receipt_preview(body: dict, request: Request, authorization: str = Header(default="")):
        return checkpoint_receipt_preview(body, request, authorization, MAX_STATE_BYTES)

    @app.post("/api/v1/me/state/experimental-large-checkpoint-preview")
    def experimental_large_checkpoint_preview(body: dict, request: Request, authorization: str = Header(default="")):
        if os.environ.get("VOCAB_EXPERIMENTAL_LARGE_DELTAS") != "1":
            raise HTTPException(404, "未启用实验性大状态整理")
        return checkpoint_receipt_preview(body, request, authorization, MAX_LARGE_DELTA_STATE_BYTES)

    # The response is a small durable receipt; clients read a separately
    # verified snapshot before installing a checkpointed large state.
    def checkpoint_receipt_commit(body: dict, request: Request, authorization: str, max_bytes: int):
        identity = identity_by_token(authorization)
        if not identity: raise HTTPException(401, "未登录或登录已过期")
        check_rate(request, "state_delta_write")
        if set(body) != {"batch_id", "generation", "base_revision", "restore_epoch"}:
            raise HTTPException(422, "整理请求字段无效")
        batch, generation, base, epoch = (body[key] for key in ("batch_id", "generation", "base_revision", "restore_epoch"))
        if not isinstance(batch, str) or not re.fullmatch(r"[0-9a-f]{32}", batch) or not isinstance(generation, str) or not re.fullmatch(r"[0-9a-f]{32}", generation):
            raise HTTPException(422, "整理批次或同步代次无效")
        if not isinstance(base, str) or not re.fullmatch(r"0|[1-9][0-9]{0,18}", base) or int(base) >= 2**63 - 1:
            raise HTTPException(422, "学习状态修订号无效")
        if type(epoch) is not int or not 0 <= epoch < 2**53 - 1:
            raise HTTPException(422, "学习状态恢复版本无效")
        request_hash = hashlib.sha256(b"large-checkpoint-v1\0" + json.dumps(body, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        account_id = identity[1]
        conn = sqlite3.connect(USERS_DB, timeout=15)
        try:
            conn.execute("BEGIN IMMEDIATE")
            if sync_generation(conn) != generation: raise HTTPException(409, "服务器同步代次已变化，请重新预览")
            now = time.time()
            receipt = conn.execute("""SELECT request_hash,generation,base_revision,revision,old_epoch,new_epoch,updated_at
                FROM account_checkpoint_receipts WHERE account_id=? AND batch_id=? AND created_at>?""",
                (account_id, batch, now - DELTA_RECEIPT_TTL)).fetchone()
            if receipt:
                if receipt[0] != request_hash or receipt[1] != generation or receipt[2] != int(base) or receipt[4] != epoch:
                    raise HTTPException(409, "批次标识已用于不同整理请求")
                conn.commit()
                return JSONResponse({"ok":True, "batch_id":batch, "generation":generation, "base_revision":base,
                    "state_revision":str(receipt[3]), "restore_epoch":receipt[5], "updated_at":receipt[6]}, headers={"Cache-Control":"no-store"})
            for table in ("account_state_batches", "account_restore_receipts"):
                if conn.execute(f"SELECT 1 FROM {table} WHERE account_id=? AND batch_id=? AND created_at>?",
                                (account_id, batch, now - DELTA_RECEIPT_TTL)).fetchone():
                    raise HTTPException(409, "批次标识已用于其他同步操作")
            if conn.execute("SELECT 1 FROM account_delta_stages WHERE account_id=? AND batch_id=? AND expires_at>?",
                            (account_id, batch, now)).fetchone():
                raise HTTPException(409, "批次标识已用于暂存操作")
            row = conn.execute("SELECT state_json,updated_at,state_revision FROM account_state WHERE account_id=?", (account_id,)).fetchone()
            if not row or validate_state_revision(row[2]) != int(base):
                raise HTTPException(409, "服务器进度已变化，请先同步后再整理")
            old = load_verified_state(conn, account_id, row[0], row[2])
            serialize_state(old, max_bytes)
            if type(old.get("restoreEpoch", 0)) is not int or old.get("restoreEpoch", 0) != epoch:
                raise HTTPException(409, "学习进度已恢复或整理，请重新同步")
            compacted = checkpoint_learning_state(old)
            compacted["restoreEpoch"] = epoch + 1
            encoded = serialize_state(compacted, max_bytes)
            updated = max(now, row[1] + 0.000001)
            conn.execute("INSERT INTO account_state_backups(account_id,state_json,created_at,reason) VALUES(?,?,?,?)",
                         (account_id, row[0], updated, "before_checkpoint"))
            revision = next_state_revision(row[2])
            conn.execute("UPDATE account_state SET state_json=?,updated_at=?,state_revision=? WHERE account_id=?",
                         (encoded, updated, revision, account_id))
            state_segments.write(conn, account_id, revision, compacted)
            record_change(conn, account_id, row[2], revision, epoch + 1, old, compacted, updated, reset=True)
            conn.execute("DELETE FROM account_checkpoint_receipts WHERE created_at<=?", (time.time() - DELTA_RECEIPT_TTL,))
            conn.execute("""INSERT INTO account_checkpoint_receipts(account_id,batch_id,request_hash,generation,base_revision,
                revision,old_epoch,new_epoch,updated_at,created_at) VALUES(?,?,?,?,?,?,?,?,?,?)""",
                (account_id, batch, request_hash, generation, int(base), revision, epoch, epoch + 1, updated, time.time()))
            conn.execute("""DELETE FROM account_checkpoint_receipts WHERE account_id=? AND batch_id NOT IN
                (SELECT batch_id FROM account_checkpoint_receipts WHERE account_id=? ORDER BY created_at DESC,rowid DESC LIMIT ?)""",
                (account_id, account_id, DELTA_MAX_RECEIPTS))
            conn.commit()
            return JSONResponse({"ok":True, "batch_id":batch, "generation":generation, "base_revision":base,
                "state_revision":str(revision), "restore_epoch":epoch + 1, "updated_at":updated}, headers={"Cache-Control":"no-store"})
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    @app.post("/api/v1/me/state/guarded-checkpoint-idempotent")
    def guarded_checkpoint_idempotent(body: dict, request: Request, authorization: str = Header(default="")):
        return checkpoint_receipt_commit(body, request, authorization, MAX_STATE_BYTES)

    @app.post("/api/v1/me/state/experimental-large-checkpoint")
    def experimental_large_checkpoint(body: dict, request: Request, authorization: str = Header(default="")):
        if os.environ.get("VOCAB_EXPERIMENTAL_LARGE_DELTAS") != "1":
            raise HTTPException(404, "未启用实验性大状态整理")
        return checkpoint_receipt_commit(body, request, authorization, MAX_LARGE_DELTA_STATE_BYTES)

    # Cancellation serializes with commit. Advancing an unchanged revision
    # fences arbitrarily delayed requests in the current generation.
    def cancel_experimental_large_operation(body: dict, request: Request, authorization: str, restore: bool):
        if os.environ.get("VOCAB_EXPERIMENTAL_LARGE_DELTAS") != "1":
            raise HTTPException(404, "未启用实验性大状态操作")
        identity = identity_by_token(authorization)
        if not identity: raise HTTPException(401, "未登录或登录已过期")
        check_rate(request, "state_delta_write")
        fields = {"batch_id", "generation", "base_revision", "restore_epoch"}
        if restore: fields.add("payload_sha256")
        if set(body) != fields: raise HTTPException(422, "取消请求字段无效")
        batch, generation, base, epoch = (body[key] for key in ("batch_id", "generation", "base_revision", "restore_epoch"))
        digest = body.get("payload_sha256")
        if not isinstance(batch, str) or not re.fullmatch(r"[0-9a-f]{32}", batch) or not isinstance(generation, str) or not re.fullmatch(r"[0-9a-f]{32}", generation):
            raise HTTPException(422, "批次或同步代次无效")
        if not isinstance(base, str) or not re.fullmatch(r"0|[1-9][0-9]{0,18}", base) or int(base) >= 2**63 - 1:
            raise HTTPException(422, "学习状态修订号无效")
        if type(epoch) is not int or not 0 <= epoch < 2**53 - 1:
            raise HTTPException(422, "学习状态恢复版本无效")
        if restore and (not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest)):
            raise HTTPException(422, "恢复备份摘要无效")
        account_id = identity[1]
        conn = sqlite3.connect(USERS_DB, timeout=15)
        try:
            conn.execute("BEGIN IMMEDIATE")
            if sync_generation(conn) != generation: raise HTTPException(409, "服务器同步代次已变化，请先导出并核对")
            now = time.time()
            own_table = "account_restore_receipts" if restore else "account_checkpoint_receipts"
            if conn.execute(f"SELECT 1 FROM {own_table} WHERE account_id=? AND batch_id=? AND created_at>?",
                            (account_id, batch, now - DELTA_RECEIPT_TTL)).fetchone():
                raise HTTPException(409, "该操作已提交，请继续恢复结果")
            other_table = "account_checkpoint_receipts" if restore else "account_restore_receipts"
            for table in ("account_state_batches", other_table):
                if conn.execute(f"SELECT 1 FROM {table} WHERE account_id=? AND batch_id=? AND created_at>?",
                                (account_id, batch, now - DELTA_RECEIPT_TTL)).fetchone():
                    raise HTTPException(409, "批次标识已用于其他同步操作")
            stage = conn.execute("""SELECT generation,base_revision,restore_epoch,digest,expires_at
                                    FROM account_delta_stages WHERE account_id=? AND batch_id=?""", (account_id, batch)).fetchone()
            if stage:
                if not restore:
                    if stage[4] > now: raise HTTPException(409, "批次标识已用于暂存操作")
                elif stage[:4] != (generation, base, epoch, digest):
                    raise HTTPException(409, "恢复暂存与本机备份不一致，请先导出")
            row = conn.execute("SELECT state_json,updated_at,state_revision FROM account_state WHERE account_id=?", (account_id,)).fetchone()
            if not row: raise HTTPException(409, "服务器进度不存在，请先导出并核对")
            revision = validate_state_revision(row[2])
            if revision < int(base): raise HTTPException(409, "服务器修订号已回退，请先导出并核对")
            state = load_verified_state(conn, account_id, row[0], revision)
            serialize_state(state, MAX_LARGE_DELTA_STATE_BYTES)
            if type(state.get("restoreEpoch", 0)) is not int or state.get("restoreEpoch", 0) != epoch:
                raise HTTPException(409, "服务器恢复版本已变化，请先导出并核对")
            if restore and stage:
                conn.execute("DELETE FROM account_delta_stage_parts WHERE account_id=? AND batch_id=?", (account_id, batch))
                conn.execute("DELETE FROM account_delta_stages WHERE account_id=? AND batch_id=?", (account_id, batch))
            if revision == int(base):
                next_revision = next_state_revision(revision)
                updated = max(now, row[1] + 0.000001)
                conn.execute("UPDATE account_state SET updated_at=?,state_revision=? WHERE account_id=?", (updated, next_revision, account_id))
                state_segments.write(conn, account_id, next_revision, state)
                record_change(conn, account_id, revision, next_revision, epoch, state, state, updated)
                revision = next_revision
            conn.commit()
            result = {"ok":True, "cancelled":True, "batch_id":batch, "generation":generation,
                      "base_revision":base, "restore_epoch":epoch, "head_revision":str(revision)}
            if restore: result["payload_sha256"] = digest
            return JSONResponse(result, headers={"Cache-Control":"no-store"})
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    @app.post("/api/v1/me/state/experimental-large-checkpoint-cancel")
    def cancel_experimental_large_checkpoint(body: dict, request: Request, authorization: str = Header(default="")):
        return cancel_experimental_large_operation(body, request, authorization, False)

    @app.post("/api/v1/me/state/experimental-large-restore-cancel")
    def cancel_experimental_large_restore(body: dict, request: Request, authorization: str = Header(default="")):
        return cancel_experimental_large_operation(body, request, authorization, True)

    @app.get("/api/v1/me/state/experimental-large-checkpoint-receipts/{batch_id}")
    def experimental_large_checkpoint_receipt(batch_id: str, request: Request, authorization: str = Header(default="")):
        if os.environ.get("VOCAB_EXPERIMENTAL_LARGE_DELTAS") != "1":
            raise HTTPException(404, "未启用实验性大状态整理")
        identity = identity_by_token(authorization)
        if not identity: raise HTTPException(401, "未登录或登录已过期")
        check_rate(request, "state_changes")
        if not re.fullmatch(r"[a-f0-9]{32}", batch_id): raise HTTPException(422, "整理批次标识无效")
        with sqlite3.connect(USERS_DB, timeout=15) as conn:
            conn.execute("BEGIN")
            row = conn.execute("""SELECT generation,base_revision,revision,new_epoch,updated_at FROM account_checkpoint_receipts
                WHERE account_id=? AND batch_id=? AND created_at>?""", (identity[1], batch_id, time.time() - DELTA_RECEIPT_TTL)).fetchone()
            if not row: raise HTTPException(404, "整理回执不存在或已过期")
            if sync_generation(conn) != row[0]: raise HTTPException(409, "服务器同步代次已变化，请重新核对")
            conn.commit()
        return JSONResponse({"ok":True, "batch_id":batch_id, "generation":row[0], "base_revision":str(row[1]),
            "state_revision":str(row[2]), "restore_epoch":row[3], "updated_at":row[4]}, headers={"Cache-Control":"no-store"})

    @app.post("/api/v1/me/state/restore")
    def restore_state(body: RestoreIn, authorization: str = Header(default="")):
        identity = identity_by_token(authorization)
        if not identity:
            raise HTTPException(401, "未登录或登录已过期")
        _, account_id = identity
        import json as _j
        validate_restore_state(body.state)
        request_hash = None
        if isinstance(body, IdempotentGuardedRestoreIn):
            if not re.fullmatch(r"[a-f0-9]{32}", body.batch_id):
                raise HTTPException(422, "恢复批次标识无效")
            request_hash = hashlib.sha256(json.dumps({"generation":body.generation,
                "state_revision":body.state_revision, "expected_updated_at":body.expected_updated_at,
                "state":body.state}, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")).hexdigest()
        conn = sqlite3.connect(USERS_DB, timeout=15)
        try:
            conn.execute("BEGIN IMMEDIATE")
            if isinstance(body, GuardedRestoreIn):
                if not re.fullmatch(r"[0-9a-f]{32}", body.generation) or not re.fullmatch(r"0|[1-9][0-9]{0,18}", body.state_revision) or int(body.state_revision) > 2**63 - 1:
                    raise HTTPException(422, "同步代次或修订号无效")
                if sync_generation(conn) != body.generation:
                    raise HTTPException(409, "服务器同步代次已变化，请重新预览")
            if request_hash is not None:
                receipt = conn.execute("""SELECT request_hash,generation,revision,updated_at,state_json,state_sha256
                    FROM account_guarded_restore_receipts WHERE account_id=? AND batch_id=? AND created_at>?""",
                    (account_id, body.batch_id, time.time() - DELTA_RECEIPT_TTL)).fetchone()
                if receipt:
                    if receipt[0] != request_hash or receipt[1] != body.generation:
                        raise HTTPException(409, "批次标识已用于不同恢复内容")
                    if hashlib.sha256(receipt[4].encode("utf-8")).hexdigest() != receipt[5]:
                        raise HTTPException(409, "恢复回执损坏，请先导出本机进度并核对服务器")
                    try: receipt_state = _j.loads(receipt[4])
                    except (ValueError, TypeError): raise HTTPException(409, "恢复回执损坏，请先导出本机进度并核对服务器")
                    conn.commit()
                    return {"state":receipt_state, "updated_at":receipt[3],
                            "state_revision":str(receipt[2]), "generation":receipt[1], "batch_id":body.batch_id,
                            "state_json":receipt[4], "state_sha256":receipt[5]}
            row = conn.execute("SELECT state_json, updated_at, state_revision FROM account_state WHERE account_id=?", (account_id,)).fetchone()
            if isinstance(body, GuardedRestoreIn) and str(validate_state_revision(row[2]) if row else 0) != body.state_revision:
                raise HTTPException(409, "服务器进度已变化，请重新预览后再恢复")
            actual = row[1] if row else None
            if actual != body.expected_updated_at:
                raise HTTPException(409, "服务器进度已变化，请重新预览后再恢复")
            old = load_verified_state(conn, account_id, row[0], validate_state_revision(row[2])) if row else {}
            if row: serialize_state(old)  # Legacy restore cannot replace an oversized baseline.
            epoch = old.get("restoreEpoch", 0)
            if not isinstance(epoch, int) or isinstance(epoch, bool) or epoch < 0:
                raise HTTPException(409, "服务器恢复版本无效，请先检查原存档")
            restored = canonicalize_posterior(filter_rejected_personalized(body.state))
            restored["restoreEpoch"] = epoch + 1
            restored, _ = anchor_legacy_evidence(restored)
            encoded = serialize_state(restored)
            now = max(time.time(), actual + 0.000001) if actual is not None else time.time()
            if row:
                conn.execute("INSERT INTO account_state_backups(account_id, state_json, created_at, reason) VALUES(?,?,?,?)",
                             (account_id, row[0], now, "before_restore"))
            revision = next_state_revision(row[2]) if row else 1
            conn.execute("""INSERT INTO account_state(account_id, state_json, updated_at, state_revision) VALUES(?,?,?,?)
                ON CONFLICT(account_id) DO UPDATE SET state_json=excluded.state_json, updated_at=excluded.updated_at,
                state_revision=excluded.state_revision""",
                (account_id, encoded, now, revision))
            state_segments.write(conn, account_id, revision, restored)
            record_change(conn, account_id, row[2] if row else 0, revision, restored["restoreEpoch"], old if row else None, restored, now, reset=True)
            if request_hash is not None:
                conn.execute("DELETE FROM account_guarded_restore_receipts WHERE created_at<=?", (time.time() - DELTA_RECEIPT_TTL,))
                conn.execute("""INSERT INTO account_guarded_restore_receipts
                    (account_id,batch_id,request_hash,generation,revision,updated_at,state_json,state_sha256,created_at)
                    VALUES(?,?,?,?,?,?,?,?,?)""", (account_id,body.batch_id,request_hash,body.generation,revision,now,encoded,
                        hashlib.sha256(encoded.encode("utf-8")).hexdigest(),time.time()))
                conn.execute("""DELETE FROM account_guarded_restore_receipts WHERE account_id=? AND batch_id NOT IN
                    (SELECT batch_id FROM account_guarded_restore_receipts WHERE account_id=? ORDER BY created_at DESC,rowid DESC LIMIT 8)""",
                    (account_id,account_id))
            conn.commit()
            result = {"state": restored, "updated_at": now, "state_revision": str(revision)}
            if request_hash is not None:
                result.update({"generation":body.generation, "batch_id":body.batch_id, "state_json":encoded,
                               "state_sha256":hashlib.sha256(encoded.encode("utf-8")).hexdigest()})
            return result
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    @app.post("/api/v1/me/state/guarded-restore")
    def guarded_restore_state(body: GuardedRestoreIn, authorization: str = Header(default="")):
        return restore_state(body, authorization)

    @app.post("/api/v1/me/state/guarded-restore-idempotent")
    def idempotent_guarded_restore_state(body: IdempotentGuardedRestoreIn, authorization: str = Header(default="")):
        return restore_state(body, authorization)

    # A staged restore is a separate, opt-in protocol. It never exposes a
    # partially uploaded state and never returns an oversized response body.
    @app.post("/api/v1/me/state/delta-stages/{batch_id}/experimental-large-restore")
    def experimental_large_restore(batch_id: str, request: Request, authorization: str = Header(default="")):
        if os.environ.get("VOCAB_EXPERIMENTAL_LARGE_DELTAS") != "1":
            raise HTTPException(404, "未启用实验性大状态恢复")
        identity = identity_by_token(authorization)
        if not identity: raise HTTPException(401, "未登录或登录已过期")
        check_rate(request, "state_delta_write")
        account_id = identity[1]
        manifest, payload, nonce = delta_staging.assemble(USERS_DB, account_id, batch_id)
        generation, base, epoch = manifest["generation"], manifest["base_revision"], manifest["restore_epoch"]
        def unique_pairs(pairs):
            result = {}
            for key, value in pairs:
                if key in result: raise ValueError("duplicate key")
                result[key] = value
            return result
        def invalid_constant(_): raise ValueError("invalid number")
        try:
            state = json.loads(payload.decode("utf-8"), object_pairs_hook=unique_pairs, parse_constant=invalid_constant)
            if not isinstance(state, dict): raise ValueError("state must be an object")
            validate_restore_state(state, MAX_LARGE_DELTA_STATE_BYTES)
        except (ValueError, TypeError, UnicodeError, RecursionError):
            raise HTTPException(422, "暂存备份格式无效")
        request_hash = hashlib.sha256(b"large-restore-v1\0" + json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode() + b"\0" + payload).hexdigest()
        digest = hashlib.sha256(payload).hexdigest()
        conn = sqlite3.connect(USERS_DB, timeout=15)
        try:
            conn.execute("BEGIN IMMEDIATE")
            stage = conn.execute("""SELECT generation,base_revision,restore_epoch,digest,expires_at,stage_nonce
                FROM account_delta_stages WHERE account_id=? AND batch_id=?""", (account_id, batch_id)).fetchone()
            if not stage or stage[5] != nonce: raise HTTPException(404, "恢复暂存已删除或替换")
            if stage[4] <= time.time(): raise HTTPException(410, "恢复暂存已过期")
            if stage[:4] != (generation, base, epoch, digest): raise HTTPException(409, "恢复暂存清单已变化")
            if sync_generation(conn) != generation: raise HTTPException(409, "服务器同步代次已变化，请重新预览")
            now = time.time()
            receipt = conn.execute("""SELECT request_hash,generation,base_revision,revision,old_epoch,new_epoch,updated_at,payload_sha256
                FROM account_restore_receipts WHERE account_id=? AND batch_id=? AND created_at>?""",
                (account_id, batch_id, now - DELTA_RECEIPT_TTL)).fetchone()
            if receipt:
                if receipt[0] != request_hash or receipt[1] != generation or receipt[2] != int(base) or receipt[4] != epoch or receipt[7] != digest:
                    raise HTTPException(409, "批次标识已用于不同恢复内容")
                conn.commit()
                return JSONResponse({"ok":True, "batch_id":batch_id, "generation":generation, "base_revision":base,
                    "state_revision":str(receipt[3]), "restore_epoch":receipt[5], "updated_at":receipt[6], "payload_sha256":receipt[7]}, headers={"Cache-Control":"no-store"})
            if conn.execute("SELECT 1 FROM account_state_batches WHERE account_id=? AND batch_id=? AND created_at>?",
                            (account_id, batch_id, now - DELTA_RECEIPT_TTL)).fetchone():
                raise HTTPException(409, "批次标识已用于增量同步")
            if conn.execute("SELECT 1 FROM account_checkpoint_receipts WHERE account_id=? AND batch_id=? AND created_at>?",
                            (account_id, batch_id, now - DELTA_RECEIPT_TTL)).fetchone():
                raise HTTPException(409, "批次标识已用于历史整理")
            row = conn.execute("SELECT state_json,updated_at,state_revision FROM account_state WHERE account_id=?", (account_id,)).fetchone()
            if not row or validate_state_revision(row[2]) != int(base):
                raise HTTPException(409, "服务器进度已变化，请重新预览后再恢复")
            old = load_verified_state(conn, account_id, row[0], row[2])
            serialize_state(old, MAX_LARGE_DELTA_STATE_BYTES)
            current_epoch = old.get("restoreEpoch", 0)
            if type(current_epoch) is not int or current_epoch != epoch or not 0 <= epoch < 2**53 - 1:
                raise HTTPException(409, "学习进度已恢复或整理，请重新预览")
            restored = canonicalize_posterior(filter_rejected_personalized(state))
            restored["restoreEpoch"] = epoch + 1
            restored, _ = anchor_legacy_evidence(restored)
            encoded = serialize_state(restored, MAX_LARGE_DELTA_STATE_BYTES)
            now = max(now, row[1] + 0.000001)
            conn.execute("INSERT INTO account_state_backups(account_id,state_json,created_at,reason) VALUES(?,?,?,?)",
                         (account_id, row[0], now, "before_restore"))
            revision = next_state_revision(row[2])
            conn.execute("UPDATE account_state SET state_json=?,updated_at=?,state_revision=? WHERE account_id=?",
                         (encoded, now, revision, account_id))
            state_segments.write(conn, account_id, revision, restored)
            record_change(conn, account_id, row[2], revision, epoch + 1, old, restored, now, reset=True)
            conn.execute("DELETE FROM account_restore_receipts WHERE created_at<=?", (time.time() - DELTA_RECEIPT_TTL,))
            conn.execute("""INSERT INTO account_restore_receipts(account_id,batch_id,request_hash,generation,base_revision,
                revision,old_epoch,new_epoch,updated_at,created_at,payload_sha256) VALUES(?,?,?,?,?,?,?,?,?,?,?)""",
                (account_id,batch_id,request_hash,generation,int(base),revision,epoch,epoch+1,now,time.time(),digest))
            conn.execute("""DELETE FROM account_restore_receipts WHERE account_id=? AND batch_id NOT IN
                (SELECT batch_id FROM account_restore_receipts WHERE account_id=? ORDER BY created_at DESC,rowid DESC LIMIT ?)""",
                (account_id,account_id,DELTA_MAX_RECEIPTS))
            conn.commit()
            return JSONResponse({"ok":True, "batch_id":batch_id, "generation":generation, "base_revision":base,
                "state_revision":str(revision), "restore_epoch":epoch+1, "updated_at":now, "payload_sha256":digest}, headers={"Cache-Control":"no-store"})
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    @app.get("/api/v1/me/state/experimental-large-restore-receipts/{batch_id}")
    def experimental_large_restore_receipt(batch_id: str, request: Request, authorization: str = Header(default="")):
        if os.environ.get("VOCAB_EXPERIMENTAL_LARGE_DELTAS") != "1":
            raise HTTPException(404, "未启用实验性大状态恢复")
        identity = identity_by_token(authorization)
        if not identity: raise HTTPException(401, "未登录或登录已过期")
        check_rate(request, "state_changes")
        if not re.fullmatch(r"[a-f0-9]{32}", batch_id): raise HTTPException(422, "恢复批次标识无效")
        with sqlite3.connect(USERS_DB, timeout=15) as conn:
            conn.execute("BEGIN")
            row = conn.execute("""SELECT generation,base_revision,revision,new_epoch,updated_at,payload_sha256 FROM account_restore_receipts
                WHERE account_id=? AND batch_id=? AND created_at>?""", (identity[1], batch_id, time.time()-DELTA_RECEIPT_TTL)).fetchone()
            if not row: raise HTTPException(404, "恢复回执不存在或已过期")
            if sync_generation(conn) != row[0]: raise HTTPException(409, "服务器同步代次已变化，请重新核对")
            conn.commit()
        return JSONResponse({"ok":True, "batch_id":batch_id, "generation":row[0], "base_revision":str(row[1]),
            "state_revision":str(row[2]), "restore_epoch":row[3], "updated_at":row[4], "payload_sha256":row[5]}, headers={"Cache-Control":"no-store"})

    @app.get("/api/v1/me/state/backups")
    def list_state_backups(authorization: str = Header(default="")):
        identity = identity_by_token(authorization)
        if not identity:
            raise HTTPException(401, "未登录或登录已过期")
        _, account_id = identity
        with sqlite3.connect(USERS_DB) as conn:
            rows = conn.execute("SELECT id, created_at, reason FROM account_state_backups WHERE account_id=? ORDER BY id DESC LIMIT 100", (account_id,)).fetchall()
        return {"backups": [{"id": i, "created_at": t, "reason": reason} for i, t, reason in rows]}

    @app.get("/api/v1/me/state/backups/{backup_id}")
    def get_state_backup(backup_id: int, authorization: str = Header(default="")):
        identity = identity_by_token(authorization)
        if not identity:
            raise HTTPException(401, "未登录或登录已过期")
        _, account_id = identity
        import json as _j
        with sqlite3.connect(USERS_DB) as conn:
            row = conn.execute("SELECT state_json FROM account_state_backups WHERE account_id=? AND id=?", (account_id, backup_id)).fetchone()
        if not row:
            raise HTTPException(404, "备份不存在")
        return {"state": enrich_fsrs_schedulers(_j.loads(row[0]), account_id)}
