"""Shared, durable admission of distinct study words before clients show them.

Reservations are never released within a day: an offline device can still use
an earlier response. Settings reductions therefore cannot revoke issued slots.
Actual historical grades are imported even if an old client exceeded the cap;
this freezes further admission instead of deleting real learning history.
"""
import json
import sqlite3
from contextlib import closing
from datetime import datetime, timedelta, timezone
from typing import Literal

from fastapi import Header, HTTPException
from pydantic import BaseModel, ConfigDict, Field, StrictBool, StrictInt

MAX_WORDS = 10000


class Word(BaseModel):
    model_config = ConfigDict(extra="forbid")
    word: str = Field(min_length=1, max_length=100)
    kind: Literal["learn", "review", "probe"]
    from_pending: StrictBool = False


class PlanRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    day: str = Field(pattern=r"^\d{4}-\d{2}-\d{2}$")
    offset_minutes: StrictInt = Field(ge=-720, le=840)
    candidates: list[Word] = Field(default_factory=list, max_length=MAX_WORDS)
    completed: list[Word] = Field(default_factory=list, max_length=MAX_WORDS)
    new_exhausted: StrictBool = False


def initialize(conn):
    conn.execute("""CREATE TABLE IF NOT EXISTS daily_study_plan(
        account_id TEXT NOT NULL, day TEXT NOT NULL,
        cap INTEGER NOT NULL, new_target INTEGER NOT NULL,
        items_json TEXT NOT NULL, PRIMARY KEY(account_id, day))""")


def extend_plan(previous, state, body):
    """Pure allocation policy, evaluated inside the SQLite write transaction."""
    settings = state.get("settings") or {}
    def bounded(key, default):
        value = settings.get(key, default)
        return max(0, min(MAX_WORDS, value)) if type(value) is int else default
    cap = max(previous["cap"] if previous else 0, bounded("dailyCap", 100))
    target = min(cap, max(previous["new_target"] if previous else 0, bounded("newPerDay", 10)))
    items = {item["word"]: dict(item) for item in (previous["items"] if previous else [])}
    # Both server history and the requesting device's unsent history consume slots.
    server_known = [x for x in state.get("log", []) if x.get("d") == body.day and x.get("kind") in ("learn", "review", "probe")]
    known = server_known + [x.model_dump() for x in body.completed]
    for event in known:
        word, kind = event["word"], event["kind"]
        item = items.setdefault(word, {"word": word, "kind": kind, "new_word": False, "probe_word": False, "completed": True, "from_pending": False})
        item["completed"] = True
        if kind == "probe":
            item["probe_word"] = True
        if kind == "learn":
            item["new_word"] = True
            item["kind"] = "learn"
    reserved_new = sum(item["new_word"] for item in items.values())
    reserved_probes = sum(item.get("probe_word", False) for item in items.values())
    client_completed = {(x.word, x.kind) for x in body.completed}
    requires_sync = any((x["word"], x["kind"]) not in client_completed for x in server_known)
    # The vocabulary can genuinely run out. Only that explicit case permits
    # review to use the unfilled new-word slots; all issued words remain reserved.
    reserve_target = target
    if body.new_exhausted:
        proposed_new = {x.word for x in body.candidates if x.kind == "learn" and x.word not in items}
        reserve_target = min(target, reserved_new + len(proposed_new))
    # Reserve new words first regardless of the presentation order in the UI.
    candidates = sorted(body.candidates, key=lambda x: x.kind != "learn")
    approved = []
    for candidate in candidates:
        word, kind = candidate.word, candidate.kind
        item = items.get(word)
        if kind in ("learn", "probe") and word in state.get("cards", {}):
            requires_sync = True
            continue
        needs_new = kind == "learn" and not (item and item["new_word"])
        needs_probe = kind == "probe" and not (item and item.get("probe_word", False))
        if needs_new and reserved_new >= target:
            continue
        if needs_probe and reserved_probes >= 3:
            continue
        if item is None:
            limit = cap if kind == "learn" else cap - max(0, reserve_target - reserved_new)
            if len(items) >= limit:
                continue
            item = {"word": word, "kind": kind, "new_word": False, "probe_word": False, "completed": False, "from_pending": candidate.from_pending}
            items[word] = item
        if needs_new:
            item["new_word"] = True
            item["kind"] = "learn"
            item["from_pending"] = candidate.from_pending
            reserved_new += 1
        if needs_probe:
            item["probe_word"] = True
            reserved_probes += 1
        approved.append(word)
    if len(items) > MAX_WORDS:
        raise HTTPException(413, "今日记录超过共享计划容量，已有学习进度保留，请先同步进度")
    return {"day": body.day, "cap": cap, "new_target": target,
            "configured_cap": bounded("dailyCap", 100), "configured_new_per_day": bounded("newPerDay", 10),
            "items": list(items.values()), "approved": sorted(set(approved)),
            "over_limit": len(items) > cap, "requires_sync": requires_sync}


def mount(app, db_path, identity_by_token, load_state):
    @app.post("/api/v1/me/study-plan")
    def reserve_study(body: PlanRequest, authorization: str = Header(default="")):
        identity = identity_by_token(authorization)
        if not identity:
            raise HTTPException(401, "未登录或登录已过期")
        account = identity[1]
        now = datetime.now(timezone.utc) + timedelta(minutes=body.offset_minutes)
        if body.day != now.date().isoformat():
            raise HTTPException(409, "日期已变化，请重新加载今天的任务")
        with closing(sqlite3.connect(db_path(), timeout=15)) as conn, conn:
            conn.execute("BEGIN IMMEDIATE")
            if not conn.execute("SELECT 1 FROM users WHERE id=? AND account_id=?", identity).fetchone():
                raise HTTPException(401, "账号已变化，请重新登录")
            row = conn.execute("SELECT state_json,state_revision FROM account_state WHERE account_id=?", (account,)).fetchone()
            state = load_state(conn, account, row[0], row[1]) if row else {}
            old = conn.execute("SELECT cap,new_target,items_json FROM daily_study_plan WHERE account_id=? AND day=?", (account, body.day)).fetchone()
            previous = {"cap": old[0], "new_target": old[1], "items": json.loads(old[2])} if old else None
            plan = extend_plan(previous, state, body)
            conn.execute("""INSERT INTO daily_study_plan(account_id,day,cap,new_target,items_json) VALUES(?,?,?,?,?)
                ON CONFLICT(account_id,day) DO UPDATE SET cap=excluded.cap,new_target=excluded.new_target,items_json=excluded.items_json""",
                (account, body.day, plan["cap"], plan["new_target"], json.dumps(plan["items"], ensure_ascii=False, separators=(",", ":"))))
            conn.execute("DELETE FROM daily_study_plan WHERE account_id=? AND day<?", (account, (now.date()-timedelta(days=30)).isoformat()))
        # The identity binds an offline cache to this account, not a reusable uid.
        return {"account_id": account, **plan}
