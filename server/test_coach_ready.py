"""Advisory time and persistent pre-class work with no production model calls."""
import json
import sqlite3
import tempfile
import time
from pathlib import Path
from unittest.mock import patch
from uuid import uuid4
from fastapi import FastAPI, HTTPException
from app import coach, coach_time as timing, coach_studio as studio
from app.coach_curriculum import CASES

NOW=1793836800
CLIENT=str(uuid4())
with tempfile.TemporaryDirectory() as directory:
    db=Path(directory)/'personal.db'
    calls=[];warmed=[];contexts=[]
    def author(prompt):
        calls.append(prompt)
        cards=[dict(c,english=studio.english_copy(c)) for c in CASES['condition'].values()]
        for c,text in zip(cards,["Please telephone the store about your raincoat if you cannot collect it before closing.","Unless our finance team revises the amount, the written estimate goes to our customer after lunch.","Another person has reserved the book you are using, so take it back before the Tuesday deadline."]):c['passage']=text
        return json.dumps(cards)
    app=FastAPI()
    coach.mount_coach(app,lambda:db,lambda _,auth,g:auth,lambda:True,
                     lambda _:json.dumps({'en':'Check the condition.','zh':'请核对条件。'}),author=author,
                     assess=lambda _:'["PASS","PASS","PASS"]',warm=lambda t,v:warmed.append((t,v)) or True,
                     vocabulary=lambda c:contexts.append(c))
    routes={r.path.rsplit('/',1)[-1]:r.endpoint for r in app.routes if '/coach/' in r.path}
    def call(op,owner='alice',**kw):
        model={'dashboard':coach.HomeIn,'clock':coach.ClockIn,'answer':coach.AnswerIn,'aid':coach.AidIn,'undo':coach.UndoIn}.get(op,coach.LessonIn)
        return routes[op](model(client=CLIENT,offset=480,edition=2,**kw),owner,'')
    worker=app.state.coach_worker
    with patch.object(coach.time,'time',return_value=NOW):
        start=time.monotonic();call('dashboard');call('prepare');assert time.monotonic()-start<0.5 and not calls
        # No clock request/lease is required, including exhausted legacy accounts.
        with sqlite3.connect(db) as c:c.execute("UPDATE coach_clock_v1 SET used=3600 WHERE owner='alice' AND day=?",(coach.local_day(NOW,480)[0],))
        lesson=call('lesson');assert lesson['task']
        assert call('dashboard')['minutes']==[8,20,2]
        while lesson['task']:
            t=lesson['task']
            if t['kind']=='listen':call('aid',task=t['id'],kind='transcript',event=str(uuid4()))
            lesson=call('answer',task=t['id'],choice=0,mode='assisted')
        # Finish enqueues tomorrow based on today's answers, with no model call in response.
        call('finish',position=5000,words=['apple'],voice='en-GB-SoniaNeural')
        assert not calls
        # A new app/worker reads the already committed queue after the request has ended.
        restarted=FastAPI()
        coach.mount_coach(restarted,lambda:db,lambda _,auth,g:auth,lambda:True,
                         lambda _:json.dumps({'en':'Check the condition.','zh':'请核对条件。'}),author=author,
                         assess=lambda _:'["PASS","PASS","PASS"]',warm=lambda t,v:warmed.append((t,v)) or True,
                         vocabulary=lambda c:contexts.append(c))
        routes={r.path.rsplit('/',1)[-1]:r.endpoint for r in restarted.routes if '/coach/' in r.path}
        worker=restarted.state.coach_worker
        while worker.once():pass
        assert len(calls)==1 and warmed and contexts and '近期课堂证据' in calls[0]
        with sqlite3.connect(db) as c:
            row=c.execute("SELECT day,body FROM coach_prep_v2 WHERE owner='alice'").fetchone()
            assert row[0]==coach.local_day(NOW+86400,480)[0]
            prepared=json.loads(row[1]);assert prepared['context']
        assert call('explanation')['ai']
        # Undo invalidates the future material, including work completing after the evidence changed.
        last=lesson['last']['id'];call('undo',task=last)
        with sqlite3.connect(db) as c:assert not studio.valid_preparation(c,'alice',row[0],'life',prepared)
        while worker.once():pass
        assert len(calls)==2
        # Duplicate finish / two devices cannot generate another matching course.
        call('finish',position=5000,words=['apple'],voice='en-GB-SoniaNeural')
        while worker.once():pass
        assert len(calls)==2
    # Simulate worker process restart: existing jobs and material remain usable the next day.
    with patch.object(coach.time,'time',return_value=NOW+86400):
        d=call('dashboard');assert d['prepared']
        l=call('lesson');assert l['source']=='AI 定制' and not l['last']
        assert len(calls)==2
        frozen=l['task'];call('dashboard',goal='work');assert call('lesson')['task']==frozen

with sqlite3.connect(':memory:') as c:
    coach.init(c)
    def record(segments,owner='test',now=NOW+100):
        return coach.budget(c,owner,coach.ClockIn(client=CLIENT,offset=480,action='record',segments=segments),now)
    def segment(a,b,kind='vocab'):
        return dict(id=str(uuid4()),start=NOW+a,end=NOW+b,activity=kind)
    first=segment(0,20,'class');second=segment(10,30)
    assert record([first])['used']==20
    assert record([first,second])['used']==30 # union, not 40 seconds across devices
    assert record([first,second])['used']==30 # repeated upload after a lost response
    day=coach.local_day(NOW,480)[0]
    assert studio.active_seconds(c,'test',day,NOW+100)==20
    assert record([first],owner='other')['used']==20
    assert record([])['advisory']
    try:record([dict(first,end=NOW+21)])
    except HTTPException as e:assert e.status_code==409
    else:raise AssertionError('identifier overwrite')
    _,midnight=coach.local_day(NOW,480)
    cross=dict(id=str(uuid4()),start=midnight-10,end=midnight+10,activity='class')
    record([cross],now=midnight+20)
    assert timing.seconds(c,'test',day)==40
    assert timing.seconds(c,'test',coach.local_day(midnight+1,480)[0])==10
    # More than forty minutes remains available; legacy timer also no longer has a cap.
    c.execute("UPDATE coach_clock_v1 SET used=2500 WHERE owner='test'")
    out=coach.budget(c,'test',coach.ClockIn(client=CLIENT,offset=480,action='pulse'),NOW+100)
    assert out['credit']>0 and out['used']>2400
print('PASS background preparation, complete/undo/restart/day rollover, cache and frozen content; advisory time, offline retries, cross-device union, midnight and account isolation')
