"""Optional listening/reading coach. It never writes the vocabulary state."""
from datetime import datetime, timedelta, timezone
from hashlib import sha256
import json
import math
import sqlite3
import time
from typing import Literal
from uuid import UUID

from fastapi import Header, HTTPException
from pydantic import BaseModel, Field

from app.coach_material import PACK

TARGET, LIMIT, LEASE = 1800, 2400, 25


class ClockIn(BaseModel):
    client: UUID
    offset: int = Field(ge=-720, le=840)
    action: Literal["status", "pulse", "stop", "extend", "offline"]


class LessonIn(BaseModel):
    client: UUID
    offset: int = Field(ge=-720, le=840)
    track: Literal["work", "life"] = "life"


class AidIn(LessonIn):
    task: str = Field(max_length=128)
    kind: Literal["transcript","play"]
    event: UUID


class AnswerIn(LessonIn):
    task: str = Field(max_length=128)
    choice: int = Field(ge=0, le=1)
    mode: Literal["read", "listen", "assisted"]
    replay: bool = False


def init(conn):
    conn.execute("CREATE TABLE IF NOT EXISTS coach_zone_v1(owner TEXT PRIMARY KEY, minutes INTEGER NOT NULL)")
    conn.execute("""CREATE TABLE IF NOT EXISTS coach_clock_v1(
        owner TEXT,day TEXT,used REAL NOT NULL DEFAULT 0,extra INTEGER NOT NULL DEFAULT 0,
        client TEXT,start REAL,end REAL,PRIMARY KEY(owner,day))""")
    conn.execute("""CREATE TABLE IF NOT EXISTS coach_lesson_v1(
        owner TEXT,day TEXT,body TEXT NOT NULL,PRIMARY KEY(owner,day))""")


def local_day(now, offset):
    local = datetime.fromtimestamp(now, timezone(timedelta(minutes=offset)))
    midnight = (local+timedelta(days=1)).replace(hour=0, minute=0, second=0, microsecond=0)
    return local.date().isoformat(), midnight.timestamp()


def account_day(conn, owner, offset, now):
    conn.execute("INSERT OR IGNORE INTO coach_zone_v1 VALUES(?,?)",(owner,offset))
    minutes=conn.execute("SELECT minutes FROM coach_zone_v1 WHERE owner=?",(owner,)).fetchone()[0]
    return local_day(now,minutes)


def budget(conn, owner, body, now):
    day, midnight = account_day(conn,owner,body.offset,now)
    client = str(body.client)
    conn.execute("INSERT OR IGNORE INTO coach_clock_v1(owner,day) VALUES(?,?)", (owner, day))
    used,extra,holder,start,end = conn.execute(
        "SELECT used,extra,client,start,end FROM coach_clock_v1 WHERE owner=? AND day=?", (owner,day)).fetchone()
    if holder:
        used += max(0, min(now,end)-start)
        start = max(start,now)
        if now >= end:
            holder = start = end = None
    if body.action == "extend" and used >= TARGET:
        extra = 1
    limit = LIMIT if extra else TARGET
    credit = 0
    if body.action == "stop" and holder == client:
        holder = start = end = None
    if body.action in ("pulse","offline") and used < limit and holder in (None,client):
        requested_end = now + (600 if body.action=="offline" else LEASE)
        if holder == client:
            requested_end = max(requested_end,end)
        holder,start,end = client, now, min(requested_end,now+limit-used,midnight)
        credit = max(0,end-now)
    conn.execute("UPDATE coach_clock_v1 SET used=?,extra=?,client=?,start=?,end=? WHERE owner=? AND day=?",
                 (used,extra,holder,start,end,owner,day))
    return {"day":day,"used":math.floor(used),"limit":limit,"credit":credit,
            "busy":bool(holder and holder != client),"extended":bool(extra)}


def active(conn, owner, body, now):
    day,_ = account_day(conn,owner,body.offset,now)
    row=conn.execute("SELECT client,end FROM coach_clock_v1 WHERE owner=? AND day=?",(owner,day)).fetchone()
    if not row or row[0]!=str(body.client) or row[1]<=now:
        raise HTTPException(409,"请先恢复本机学习计时")
    return day


def load_lesson(conn,owner,day):
    row=conn.execute("SELECT body FROM coach_lesson_v1 WHERE owner=? AND day=?",(owner,day)).fetchone()
    return json.loads(row[0]) if row else None


def save(conn,owner,day,lesson):
    conn.execute("INSERT OR REPLACE INTO coach_lesson_v1 VALUES(?,?,?)",(owner,day,json.dumps(lesson,ensure_ascii=False)))


def make_lesson(conn,owner,day,track):
    history=[json.loads(r[0]) for r in conn.execute(
        "SELECT body FROM coach_lesson_v1 WHERE owner=? AND day<? ORDER BY day DESC LIMIT 28",(owner,day))]
    skills=list(PACK)
    focus=skills[len(history)%len(skills)]
    reason="先做一个小任务，看看你怎样理解现实中的安排。"
    for last in history:
        if last["answers"]:
            final=last["answers"][-1]
            if not final["ok"] or final["mode"]=="assisted":
                focus=last["skill"]
                reason="上次这个重点还需要帮助，今天换个情境再试。"
            else:
                focus=skills[(skills.index(last["skill"])+1)%len(skills)]
                reason="上次能独立完成，今天换一个理解重点。"
            break
    tested={old.get("reviewOf") for old in history if old["answers"]}
    transfer=next((old for old in reversed(history) if old["answers"] and not old.get("reviewOf")
                   and old["day"] not in tested and old["day"] <= (datetime.fromisoformat(day)-timedelta(days=7)).date().isoformat()),None)
    if transfer:
        focus=transfer["skill"]
        reason="跨周验证：换一则消息，看看能否独立理解上次的重点。"
    seen=sum(1 for l in history if l["skill"]==focus and l["track"]==track)
    variant=seen%3
    if transfer and track==transfer["track"] and variant==transfer["variant"]:
        variant=(variant+1)%3
    return {"day":day,"skill":focus,"track":track,"variant":variant,"reason":reason,"reviewOf":transfer["day"] if transfer else None,"answers":[]}


def task(lesson,step):
    skill,track=lesson["skill"],lesson["track"]
    first=lesson["answers"][:1]
    needs_help=first and (not first[0]["ok"] or first[0]["mode"]=="assisted")
    # A guided contrast stays in the familiar setting. Independent transfer changes it.
    actual_track=track if step==0 or (step==1 and needs_help) else ("work" if track=="life" else "life")
    i=(lesson["variant"]+step)%3
    values=PACK[skill][actual_track][i]
    ident=f'{lesson["day"]}/{skill}/{actual_track}/{i}/{step}'
    correct=sha256(ident.encode()).digest()[0]%2
    options=[values[2],values[3]] if correct==0 else [values[3],values[2]]
    aids=lesson.get("aids",{}).get(ident,{})
    return {"id":ident,"shown":"transcript" in aids.values(),"plays":sum(v=="play" for v in aids.values()),"passage":values[0],"question":values[1],"options":options,
            "kind":"listen" if step%2==0 else "read",
            "purpose":("先独立理解" if step==0 else "带着线索再试" if step==1 and needs_help else "换个情境验证"),
            "hint":("先区分已知事实和对方要求的行动。" if step==1 and needs_help else "")},correct,values


def present(lesson):
    answers=lesson["answers"]
    count=3 if answers and (not answers[0]["ok"] or answers[0]["mode"]=="assisted") else 2
    return {"day":lesson["day"],"track":lesson["track"],"focus":PACK[lesson["skill"]]["label"],
            "reason":lesson["reason"],"step":len(answers),"count":count,"last":answers[-1] if answers else None,
            "task":task(lesson,len(answers))[0] if len(answers)<count else None,
            "independent":sum(a["ok"] and a["mode"]!="assisted" for a in answers)}


def mount_coach(app, database, identify, enabled, explain):
    def owner(auth,guest):
        if not enabled():
            raise HTTPException(503,"教练暂未开放，可以返回经典词航")
        return identify("coach",auth,guest)
    def connect():
        conn=sqlite3.connect(database(), timeout=10)
        conn.execute("BEGIN IMMEDIATE")
        init(conn)
        return conn

    @app.get("/api/v1/coach/availability")
    def availability():
        return {"enabled":enabled()}

    @app.post("/api/v1/coach/clock")
    def clock(body: ClockIn, authorization:str=Header(default=""), x_guest_token:str=Header(default="")):
        who=identify("coach",authorization,x_guest_token)
        with connect() as conn:
            return budget(conn,who,body,time.time())

    @app.post("/api/v1/coach/lesson")
    def lesson(body: LessonIn, authorization:str=Header(default=""), x_guest_token:str=Header(default="")):
        who=owner(authorization,x_guest_token)
        with connect() as conn:
            day=active(conn,who,body,time.time())
            current=load_lesson(conn,who,day)
            if not current:
                used,extra,start=conn.execute("SELECT used,extra,start FROM coach_clock_v1 WHERE owner=? AND day=?",(who,day)).fetchone()
                remaining=(LIMIT if extra else TARGET)-used-max(0,time.time()-start)
                if remaining<180:
                    raise HTTPException(409,"剩余时间不足 3 分钟，建议今天收课。已完成的背词进度已保留。")
                current=make_lesson(conn,who,day,body.track)
                save(conn,who,day,current)
            return present(current)

    @app.post("/api/v1/coach/aid")
    def aid(body: AidIn, authorization:str=Header(default=""), x_guest_token:str=Header(default="")):
        who=owner(authorization,x_guest_token)
        with connect() as conn:
            day=active(conn,who,body,time.time())
            current=load_lesson(conn,who,day)
            pending=present(current)["task"] if current else None
            if not pending or pending["id"]!=body.task or pending["kind"]!="listen":
                raise HTTPException(409,"题目已更新")
            events=current.setdefault("aids",{}).setdefault(body.task,{})
            if len(events)<32 or body.kind=="transcript" and "transcript" not in events.values():
                events.setdefault(str(body.event),body.kind)
            save(conn,who,day,current)
            return present(current)

    @app.post("/api/v1/coach/answer")
    def answer(body: AnswerIn, authorization:str=Header(default=""), x_guest_token:str=Header(default="")):
        who=owner(authorization,x_guest_token)
        with connect() as conn:
            day=active(conn,who,body,time.time())
            current=load_lesson(conn,who,day)
            if not current:
                raise HTTPException(409,"请重新打开今日课程")
            for a in current["answers"]:
                if a["id"]==body.task:
                    if a["choice"]!=body.choice:
                        raise HTTPException(409,"此题已在另一端作答，请取回最新进度")
                    return present(current)
            pending=present(current)["task"]
            if not pending or pending["id"]!=body.task:
                raise HTTPException(409,"课程进度已更新")
            _,right,values=task(current,len(current["answers"]))
            if pending["kind"]=="listen" and not (pending["plays"] or pending["shown"] or body.mode=="assisted"):
                raise HTTPException(409,"请先听消息或查看原文")
            mode="assisted" if pending["shown"] or pending["hint"] or body.mode=="assisted" else pending["kind"]
            current["answers"].append({"id":body.task,"ok":body.choice==right,"choice":body.choice,
                "mode":mode,"replay":pending["plays"]>1 or body.replay,"explanation":values[4],"reply":values[5],
                "expected":values[2],"at":time.time()})
            save(conn,who,day,current)
            return present(current)

    @app.post("/api/v1/coach/explanation")
    def explanation(body:LessonIn, authorization:str=Header(default=""), x_guest_token:str=Header(default="")):
        who=owner(authorization,x_guest_token)
        with connect() as conn:
            day=active(conn,who,body,time.time())
            current=load_lesson(conn,who,day)
            if not current or not current["answers"]:
                raise HTTPException(409,"请先完成一道题")
            index=len(current["answers"])-1
            answer=current["answers"][index]
            fallback={"text":answer["explanation"],"ai":False}
            if answer.get("ai"):
                return {"text":answer["ai"],"ai":True}
            if answer.get("requested",0)>time.time()-120:
                return fallback
            answer["requested"]=time.time()
            save(conn,who,day,current)
            prompt,_,_=task(current,index)
        # Scores, dates, and memory never come from a model. No identity or raw learner text is sent.
        try:
            out=explain("你是英语教师。根据固定题解用两句中文解释一个关键英文短语，帮助学生理解其所选答案。不要新增事实，不评价发音。"
                        +json.dumps([prompt["passage"],prompt["question"],prompt["options"][answer["choice"]],answer["explanation"]],ensure_ascii=False))
            if not isinstance(out,str) or not 4<=len(out.strip())<=400 or any(c in out for c in "<>{}"):
                return fallback
        except Exception:
            return fallback
        with connect() as conn:
            latest=load_lesson(conn,who,day)
            if latest and len(latest["answers"])>index and latest["answers"][index]["id"]==answer["id"]:
                latest["answers"][index]["ai"]=out.strip()
                save(conn,who,day,latest)
        return {"text":out.strip(),"ai":True}
