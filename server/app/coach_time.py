"""Advisory study time: durable, idempotent intervals; never an admission lease."""
from datetime import datetime, timedelta, timezone
from uuid import UUID

from fastapi import HTTPException
from pydantic import BaseModel, Field, model_validator


class Segment(BaseModel):
    id: UUID
    start: float = Field(ge=0, allow_inf_nan=False)
    end: float = Field(ge=0, allow_inf_nan=False)
    activity: str = Field(pattern="^(class|vocab)$")

    @model_validator(mode="after")
    def duration(self):
        if not 0 < self.end - self.start <= 65:
            raise ValueError("interval must contain at most 65 active seconds")
        return self


def init(conn):
    conn.execute("""CREATE TABLE IF NOT EXISTS coach_time_v3(
        owner TEXT,id TEXT,start REAL,end REAL,activity TEXT,PRIMARY KEY(owner,id))""")
    conn.execute("CREATE INDEX IF NOT EXISTS coach_time_window_v3 ON coach_time_v3(owner,start,end)")


def span(day, offset):
    start = datetime.fromisoformat(day).replace(tzinfo=timezone(timedelta(minutes=offset))).timestamp()
    return start, start + 86400


def union(rows):
    total = 0
    end = 0
    for a, b in sorted(rows):
        total += max(0, b - max(a, end))
        end = max(b, end)
    return total


def seconds(conn, owner, day, activity=None):
    zone = conn.execute("SELECT minutes FROM coach_zone_v1 WHERE owner=?", (owner,)).fetchone()
    if not zone:
        return 0
    lo, hi = span(day, zone[0])
    rows = conn.execute("SELECT start,end,activity FROM coach_time_v3 WHERE owner=? AND start<? AND end>?",
                        (owner, hi, lo))
    return union((max(a, lo), min(b, hi)) for a, b, kind in rows if activity is None or kind == activity)


def record(conn, owner, segments, now):
    for s in segments:
        if s.end > now + 300:
            raise HTTPException(422, "练习时间晚于服务器时间，请检查设备时钟")
        row = conn.execute("SELECT start,end,activity FROM coach_time_v3 WHERE owner=? AND id=?",
                           (owner, str(s.id))).fetchone()
        value = (s.start, s.end, s.activity)
        if row and row != value:
            raise HTTPException(409, "练习时间记录标识冲突")
        if not row:
            conn.execute("INSERT INTO coach_time_v3 VALUES(?,?,?,?,?)", (owner, str(s.id), *value))
    return [str(s.id) for s in segments]
