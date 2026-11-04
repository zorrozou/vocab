"""Exercise coach clocks, evidence, authorization and recovery using disposable DBs."""
import sqlite3
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from fastapi import FastAPI, HTTPException
from types import SimpleNamespace
from app import coach

A="aaaaaaaa-1111-4111-8111-111111111111"
B="bbbbbbbb-1111-4111-8111-111111111111"
NOW=1793750400

def test_clock():
    with sqlite3.connect(":memory:") as c:
        coach.init(c)
        def call(now, ident=A, action="pulse", offset=480):
            return coach.budget(c,"test",coach.ClockIn(client=ident,offset=offset,action=action),now)
        assert call(NOW)["credit"]==25
        assert call(NOW+5,B)["busy"]
        assert call(NOW+6,action="stop")["used"]==6
        assert call(NOW+90,B,action="offline")["credit"]==600
        assert call(NOW+90,B)["credit"]==600
        assert call(NOW+91,A)["busy"]
        assert call(NOW+110,B,action="stop")["used"]==26
        s=call(NOW+120)
        c.execute("UPDATE coach_clock_v1 SET used=1796,client=NULL,start=NULL,end=NULL")
        assert call(NOW+121)["credit"]==4
        assert call(NOW+125,B)["credit"]==0
        assert call(NOW+126,B,action="extend")["limit"]==2400
        c.execute("UPDATE coach_clock_v1 SET used=2398,client=NULL,start=NULL,end=NULL")
        assert call(NOW+127,B)["credit"]==2
        for offset in (-720,0,840):
            s=call(NOW+500,A,offset=offset)
            assert s["used"]==2400 and not s["credit"]
        assert call(NOW+86400)["used"]==0
        # Lease ends on the registered learning-day boundary.
        _,midnight=coach.local_day(NOW+86400,480)
        assert call(midnight-4)["credit"]==4
        assert call(midnight+1,B)["used"]==0


def test_lessons():
    with TemporaryDirectory() as d:
        path=Path(d)/"personal.db"
        app=FastAPI()
        def identify(_,auth,g):
            if auth not in ("Bearer alice","Bearer bob"):raise HTTPException(401)
            return auth
        flag={"on":True}
        coach.mount_coach(app,lambda:path,identify,lambda:flag["on"],lambda p:"unless 表示改变计划的条件。")
        routes={r.path.split("/")[-1]:r.endpoint for r in app.routes if r.path.startswith("/api/v1/coach/")}
        def post(path,client=A,who="alice",**kw):
            model={"clock":coach.ClockIn,"answer":coach.AnswerIn,"aid":coach.AidIn}.get(path,coach.LessonIn)
            try:
                data=routes[path](model(client=client,offset=480,**kw),"Bearer "+who,"")
                return SimpleNamespace(status_code=200,is_success=True,json=lambda:data)
            except HTTPException as e:
                return SimpleNamespace(status_code=e.status_code)
        with patch.object(coach.time,'time',return_value=NOW):
            assert post("lesson").status_code==409
            assert post("clock",action="pulse").is_success
            l=post("lesson").json();t=l["task"]
            assert t['kind']=='listen' and len(t['options'])==2
            assert post("answer",task=t["id"],choice=0,mode="listen").status_code==409
            assert post("aid",task=t["id"],kind="play",event=A).json()["task"]["plays"]==1
            assert post("aid",task=t["id"],kind="play",event=A).json()["task"]["plays"]==1
            correct=t['options'].index('室外')
            result=post("answer",task=t['id'],choice=1-correct,mode="listen").json()
            assert result["count"]==3 and result["step"]==1 and result["task"]["hint"]
            assert post("answer",task=t["id"],choice=1-correct,mode="listen").json()==result
            assert post("explanation").json()["ai"]
            assert post("clock",client=B,action="pulse").json()["busy"]
            post("clock",action="stop")
            post("clock",client=B,action="pulse")
            assert post("lesson",client=B).json()['task']==result['task']
            flag["on"]=False
            assert post("lesson",client=B).status_code==503
            assert post("clock",client=B,action="pulse").json()["credit"]>0
            flag["on"]=True
            assert post("lesson",client=B).json()["task"]==result["task"]
            assert post("lesson",client=B,who="bob").status_code==409
            assert post("clock",who="stranger",action="pulse").status_code==401
            for _ in range(2):
                result=post("answer",client=B,task=result['task']['id'],choice=0,mode="assisted").json()
            assert result['step']==3 and result['task'] is None
        with patch.object(coach.time,'time',return_value=NOW+86400):
            post("clock",action="pulse")
            l2=post("lesson").json()
            assert l2["focus"]==l["focus"] and l2["task"]["passage"]!=t["passage"]
            assert '上次' in l2["reason"]
        with patch.object(coach.time,'time',return_value=NOW+7*86400):
            post("clock",action="pulse")
            due=post("lesson").json()
            assert "跨周验证" in due["reason"] and due["focus"]==l["focus"]
        with sqlite3.connect(path) as db:
            assert all(row[0].startswith('coach_') for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'"))
if __name__=="__main__":
    test_clock();test_lessons();print("PASS shared 30/40-minute limits, midnight, pause, adaptive lesson, retries and cross-device evidence")
