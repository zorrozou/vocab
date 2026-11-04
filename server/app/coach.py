"""Optional listening/reading coach. It never writes the vocabulary state."""
from datetime import datetime, timedelta, timezone
from hashlib import sha256
import json
import math
import logging
import re
import sqlite3
import time
from typing import Literal
from uuid import UUID, uuid4
from threading import BoundedSemaphore

from fastapi import Header, HTTPException, Request
from pydantic import BaseModel, Field

from app.coach_material import PACK
from app import coach_studio as studio
from app.limits import check_rate

TARGET, LIMIT, LEASE = 1800, 2400, 25


class ClockIn(BaseModel):
    client: UUID
    offset: int = Field(ge=-720, le=840)
    action: Literal["status", "pulse", "stop", "extend", "offline"]
    activity: Literal["class","vocab"]="vocab"


class LessonIn(BaseModel):
    client: UUID
    offset: int = Field(ge=-720, le=840)
    track: Literal["work", "life", "read"] = "life"
    edition: Literal[1,2] = 1
    level: int = Field(default=0,ge=0,le=20000)
    due: int = Field(default=0,ge=0,le=100)
    words: list[str] = Field(default_factory=list,max_length=3)


class HomeIn(LessonIn):
    goal: Literal["work","life","read"] | None = None
    study: bool | None = None


class UndoIn(LessonIn):
    task: str = Field(max_length=128)


class ReplyIn(LessonIn):
    attempt: Literal[1,2] = 1
    task: str = Field(max_length=128)
    text: str = Field(min_length=1,max_length=180)



class AidIn(LessonIn):
    task: str = Field(max_length=128)
    kind: Literal["transcript","play"]
    event: UUID


class AnswerIn(LessonIn):
    task: str = Field(max_length=128)
    choice: int = Field(ge=0, le=2)
    mode: Literal["read", "listen", "assisted"]
    replay: bool = False


def init(conn):
    studio.init(conn)
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
    elapsed=max(0,min(now,end)-start) if holder else 0
    if elapsed:
        conn.execute("UPDATE coach_phase_time_v2 SET seconds=seconds+? WHERE owner=? AND day=? AND client=? AND activity='class'",(elapsed,owner,day,holder))
    if holder:
        used += elapsed
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
        conn.execute("INSERT INTO coach_phase_time_v2 VALUES(?,?,?,?,0) ON CONFLICT(owner,day) DO UPDATE SET client=excluded.client,activity=excluded.activity",
                     (owner,day,client,body.activity))
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


def load_lesson(conn,owner,day,edition=1):
    table=studio.TABLE if edition==2 else "coach_lesson_v1"
    row=conn.execute(f"SELECT body FROM {table} WHERE owner=? AND day=?",(owner,day)).fetchone()
    return json.loads(row[0]) if row else None


def save(conn,owner,day,lesson):
    table=studio.TABLE if lesson.get("edition")==2 else "coach_lesson_v1"
    conn.execute(f"INSERT OR REPLACE INTO {table} VALUES(?,?,?)",(owner,day,json.dumps(lesson,ensure_ascii=False)))


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
    if lesson.get("edition")==2:
        return studio.task(lesson,step)
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
    extras={}
    if lesson.get("edition")==2:
        count=len(studio.stage_order(lesson))
        extras={"edition":2,"source":lesson["source"],"title":lesson["cards"][0]["title"],
                "words":lesson["words"],"interval":lesson["interval"],"response":lesson.get("response")}
        extras["debrief"]=studio.debrief(lesson)
    return {**extras,"day":lesson["day"],"track":lesson["track"],"focus":studio.SKILLS[lesson["skill"]] if lesson.get("edition")==2 else PACK[lesson["skill"]]["label"],
            "reason":lesson["reason"],"step":len(answers),"count":count,"last":answers[-1] if answers else None,
            "task":task(lesson,len(answers))[0] if len(answers)<count else None,
            "independent":sum(a["ok"] and a["mode"]!="assisted" and not a.get("replay") for a in answers)}


def mount_coach(app, database, identify, enabled, explain, author=None, assess=None, valid_word=None):
    workers=BoundedSemaphore(2)
    def inputs(body):
        return list(dict.fromkeys(w.lower() for w in body.words if re.fullmatch(r"[a-zA-Z]{2,30}",w) and (not valid_word or valid_word(w.lower()))))

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

    @app.post("/api/v1/coach/dashboard")
    def dashboard(body:HomeIn,authorization:str=Header(default=""),x_guest_token:str=Header(default="")):
        who=owner(authorization,x_guest_token)
        with connect() as conn:
            now=time.time()
            info=budget(conn,who,ClockIn(client=body.client,offset=body.offset,action="status"),now)
            day=info["day"]
            goal=studio.profile(conn,who,body.goal)
            studio.participation(conn,who,body.study)
            report=studio.dashboard(conn,who,day,goal,info["limit"]-info["used"],body.due)
            prep=conn.execute("SELECT body FROM coach_prep_v2 WHERE owner=? AND day=? AND goal=?",(who,day,goal)).fetchone()
            cached=json.loads(prep[0]) if prep and prep[0] and not report["study"]["on"] else None
            ready=bool(cached and studio.SKILLS[cached["skill"]]==report["focus"])
            if ready and not report["started"]:
                report.update(title=cached["cards"][0]["title"],source="AI 定制")
            previous=load_lesson(conn,who,day)
            report.update(used=info["used"],limit=info["limit"],prepared=ready,
                          legacy=bool(previous and present(previous)["task"]),weak=inputs(body))
            return report

    @app.post("/api/v1/coach/prepare")
    def prepare(body:LessonIn,authorization:str=Header(default=""),x_guest_token:str=Header(default=""),request:Request=None):
        who=owner(authorization,x_guest_token)
        now=time.time()
        with connect() as conn:
            info=budget(conn,who,ClockIn(client=body.client,offset=body.offset,action="status"),now)
            day=info["day"];goal=studio.profile(conn,who)
            if info["limit"]-info["used"]<360:raise HTTPException(409,"今日剩余时间不足以开始新课")
            if studio.participation(conn,who):
                return {"ready":False,"message":"学习验证使用共同教研材料，避免教材难度干扰比较。"}
            if load_lesson(conn,who,day,2):raise HTTPException(409,"今天的课堂已经开始，教材已固定")
            last=conn.execute("SELECT started,body FROM coach_prep_v2 WHERE owner=? AND day=? AND goal=?",(who,day,goal)).fetchone()
            if last and last[1]:return {"ready":True,"message":"今日定制材料已就绪"}
            if last and now-last[0]<180:return {"ready":False,"message":"本轮备课中或暂未通过审校。也可以直接开始教研课程。"}
            check_rate(request,"personalize")
            if not workers.acquire(blocking=False):raise HTTPException(429,"教练暂忙，可以直接开始教研课程")
            try:
                stamp=str(uuid4())
                past=studio.history(conn,who,day)
                skill,reason,_,_=studio.choose(past,day)
                previous=[c["passage"] for lesson in past for c in lesson.get("cards",[])]
                conn.execute("INSERT OR REPLACE INTO coach_prep_v2 VALUES(?,?,?,?,?,NULL)",(who,day,goal,now,stamp))
            except BaseException:
                workers.release()
                raise
        try:
            doc=studio.prepare_material(author or explain,assess or explain,skill,goal,body.level,inputs(body),reason,previous)
        except Exception as exc:
            logging.getLogger(__name__).warning("教练备课未采用：%s",type(exc).__name__)
            return {"ready":False,"message":"本次定制未通过或服务暂不可用，已为你保留教研课程。"}
        finally:
            workers.release()
        with connect() as conn:
            if load_lesson(conn,who,day,2) or studio.profile(conn,who)!=goal:
                return {"ready":False,"message":"目标或课程已经更新，保留已打开的教材。"}
            changed=conn.execute("UPDATE coach_prep_v2 SET body=? WHERE owner=? AND day=? AND goal=? AND token=?",
                                 (json.dumps(doc,ensure_ascii=False),who,day,goal,stamp)).rowcount
            return {"ready":bool(changed),"message":"三则情境与题目已备好并通过审校。" if changed else "备课已更新，请刷新。"}

    @app.post("/api/v1/coach/lesson")
    def lesson(body: LessonIn, authorization:str=Header(default=""), x_guest_token:str=Header(default="")):
        who=owner(authorization,x_guest_token)
        with connect() as conn:
            day=active(conn,who,body,time.time())
            current=load_lesson(conn,who,day,body.edition)
            if not current:
                used,extra,start=conn.execute("SELECT used,extra,start FROM coach_clock_v1 WHERE owner=? AND day=?",(who,day)).fetchone()
                remaining=(LIMIT if extra else TARGET)-used-max(0,time.time()-start)
                minimum=360 if body.edition==2 else 180
                if remaining<minimum:
                    raise HTTPException(409,f"剩余时间不足 {minimum//60} 分钟，建议今天收课。已完成的进度已保留。")
                if body.edition==2:
                    current=studio.make(conn,who,day,studio.profile(conn,who),body.level,inputs(body))
                else:
                    current=make_lesson(conn,who,day,"life" if body.track=="read" else body.track)
                save(conn,who,day,current)
            return present(current)

    @app.post("/api/v1/coach/aid")
    def aid(body: AidIn, authorization:str=Header(default=""), x_guest_token:str=Header(default="")):
        who=owner(authorization,x_guest_token)
        with connect() as conn:
            day=active(conn,who,body,time.time())
            current=load_lesson(conn,who,day,body.edition)
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
            current=load_lesson(conn,who,day,body.edition)
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
            if body.choice>=len(pending["options"]):
                raise HTTPException(422,"选项已更新")
            gap=(body.choice-right)%len(pending["options"])-1
            if pending["kind"]=="listen" and not (pending["plays"] or pending["shown"] or body.mode=="assisted"):
                raise HTTPException(409,"请先听消息或查看原文")
            mode="assisted" if pending["shown"] or pending["hint"] or body.mode=="assisted" else pending["kind"]
            current["answers"].append({"id":body.task,"ok":body.choice==right,"choice":body.choice,
                "mode":mode,"replay":pending["plays"]>1 or body.replay,"explanation":values[4],"reply":values[5],
                "chosen":pending["options"][body.choice],"expected":values[2],"gap":max(0,gap),"stage":pending.get("stage",""),"at":time.time()})
            if current.get("edition")==2:
                current["activeSeconds"]=max(0,int(studio.active_seconds(conn,who,day,time.time())-current.get("beganAtSeconds",0)))
            save(conn,who,day,current)
            return present(current)

    @app.post("/api/v1/coach/explanation")
    def explanation(body:LessonIn, authorization:str=Header(default=""), x_guest_token:str=Header(default="")):
        who=owner(authorization,x_guest_token)
        with connect() as conn:
            day=active(conn,who,body,time.time())
            current=load_lesson(conn,who,day,body.edition)
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
            latest=load_lesson(conn,who,day,body.edition)
            if latest and len(latest["answers"])>index and latest["answers"][index]["id"]==answer["id"]:
                latest["answers"][index]["ai"]=out.strip()
                save(conn,who,day,latest)
        return {"text":out.strip(),"ai":True}


    @app.post("/api/v1/coach/undo")
    def undo(body:UndoIn,authorization:str=Header(default=""),x_guest_token:str=Header(default="")):
        who=owner(authorization,x_guest_token)
        with connect() as conn:
            day=active(conn,who,body,time.time())
            l=load_lesson(conn,who,day,2)
            if not l or not l["answers"] or l["answers"][-1]["id"]!=body.task:
                raise HTTPException(409,"作答已更新，请取回最新进度")
            l["answers"].pop()
            l.setdefault("revisions",{})[str(len(l["answers"]))]=int(l.get("revisions",{}).get(str(len(l["answers"])),0))+1
            # Keep earlier exposure visible; a corrected answer after feedback is assisted.
            l.setdefault("corrected",{})[str(len(l["answers"]))]=True
            save(conn,who,day,l)
            return present(l)

    @app.post("/api/v1/coach/reply")
    def reply(body:ReplyIn, authorization:str=Header(default=""),x_guest_token:str=Header(default=""),request:Request=None):
        who=owner(authorization,x_guest_token)
        if not re.search(r"[A-Za-z]",body.text):raise HTTPException(422,"请尝试写一句英语")
        with connect() as conn:
            day=active(conn,who,body,time.time())
            l=load_lesson(conn,who,day,2)
            if not l or not l["answers"] or l["answers"][-1]["id"]!=body.task:raise HTTPException(409,"本题已更新")
            last=l["answers"][-1]
            saved=last.get("responses",[])
            if len(saved)>=body.attempt:return saved[body.attempt-1]
            if body.attempt!=len(saved)+1:raise HTTPException(409,"先提交第一句回应")
            if last.get("replyVersion")==body.attempt and time.time()-last.get("replyAttempt",0)<60:
                raise HTTPException(429,"本轮反馈正在准备或刚刚尝试过")
            check_rate(request,"sentence")
            last.update(replyAttempt=time.time(),replyVersion=body.attempt)
            save(conn,who,day,l)
            prompt,_,_=task(l,len(l["answers"])-1)
        try:
            result=studio.reply_feedback(assess or explain,prompt["passage"],last["expected"],body.text,last["reply"])
            result["attempt"]=body.attempt
        except Exception:
            return {"verdict":"暂无法判断","tip":"这次没有取得可靠反馈。可以对照参考说法自行检查，稍后重试。","example":last["reply"]}
        with connect() as conn:
            latest=load_lesson(conn,who,day,2)
            for a in latest["answers"]:
                if a["id"]==body.task:
                    saved=a.setdefault("responses",[])
                    if len(saved)==body.attempt-1:saved.append(result)
                    if len(saved)<body.attempt:raise HTTPException(409,"回应版本已变化")
                    a["response"]=saved[-1]
                    save(conn,who,day,latest)
                    return saved[body.attempt-1]
        raise HTTPException(409,"课程已变化")
