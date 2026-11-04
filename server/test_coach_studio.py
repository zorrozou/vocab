"""Studio contracts: two goals, real evidence, authored course validation and versioned undo."""
import json, sqlite3, tempfile
from pathlib import Path
from unittest.mock import patch
from uuid import uuid4
from fastapi import FastAPI, HTTPException
from app import coach
from app import coach_studio as studio
from app.coach_curriculum import CASES, TRANSFER

now=1793750400
client=str(uuid4())
calls=[]
cards=[dict(c,english=studio.english_copy(c)) for c in CASES["condition"].values()]
cards[0]["passage"]="Please telephone the store about your raincoat if you cannot collect it before closing."
cards[1]["passage"]="Unless our finance team revises the amount, the written estimate goes to our customer after lunch."
cards[2]["passage"]="Another person has reserved the book you are using, so take it back before the Tuesday deadline."
def author(prompt):
    calls.append(prompt)
    return json.dumps(cards,ensure_ascii=False)
def assess(prompt):
    if "student_quote" in prompt:
        return json.dumps({"relation":"MATCH","student_quote":json.loads(prompt[prompt.index('{\"student\"'):])["student"]})
    if "verdict" in prompt:
        data=json.loads(prompt[prompt.index("{"):])
        return json.dumps({"verdict":"表达清楚","tip":"沟通行动清楚。","tipEn":"Your intended action is clear.","scene_quote":data["情境原文"][:15],"learner_quote":data["学生实际说的英语"][:10]})
    return '["PASS","PASS","PASS"]'
with tempfile.TemporaryDirectory() as tmp:
    path=Path(tmp)/"personal.db"
    app=FastAPI()
    coach.mount_coach(app,lambda:path,lambda _,token,g:token,lambda:True,lambda prompt:'解释',
                      author=author,assess=assess,valid_word=lambda w:w=='raincoat')
    routes={r.path.split('/')[-1]:r.endpoint for r in app.routes if r.path.startswith('/api/v1/coach')}
    def call(op,owner='alice',**kw):
        model={'dashboard':coach.HomeIn,'clock':coach.ClockIn,'aid':coach.AidIn,'answer':coach.AnswerIn,
               'reply':coach.ReplyIn,'undo':coach.UndoIn}.get(op,coach.LessonIn)
        return routes[op](model(**{'client':client,'offset':480,'edition':2,**kw}),owner,'')
    with patch.object(coach.time,'time',return_value=now):
        assert call('dashboard',goal='work')['goal']=='work'
        d=call('dashboard');assert d['minutes']==[8,20,2] and d['signals']['listen']==0
        assert call('dashboard',owner='bob')['goal']=='life'
        assert call('prepare',words=['raincoat','invalidword'],level=2000)['ready']
        assert call('prepare')['ready'] and len(calls)==1 and 'raincoat' in calls[0] and 'invalidword' not in calls[0]
        assert call('dashboard')['title']==cards[0]['title'] and call('dashboard')['source']=='AI 定制'
        call('clock',action='pulse');l=call('lesson')
        assert l['source']=='AI 定制' and l['words']==['raincoat'] and l['track']=='work'
        t=l['task']; call('aid',task=t['id'],kind='transcript',event=str(uuid4()))
        choice=t['options'].index(cards[0]['options'][2])
        l=call('answer',task=t['id'],choice=choice,mode='listen')
        assert l['task']['question']==cards[0]['checks'][1][0] and l['count']==4
        a=call('reply',task=t['id'],text='Could I collect my blue coat tomorrow morning instead?');assert a['verdict']=='表达清楚'
        improved=call('reply',task=t['id'],text='I can call the shop now.',attempt=2)
        assert improved['attempt']==2 and call('reply',task=t['id'],text='repeat',attempt=2)==improved
        l=call('undo',task=t['id']);assert l['step']==0 and l['task']['id']!=t['id']
        try:call('answer',task=t['id'],choice=choice,mode='assisted')
        except HTTPException as e:assert e.status_code==409
        else:raise AssertionError('stale answer replayed')
        t=l['task'];call('aid',task=t['id'],kind='transcript',event=str(uuid4()))
        l=call('answer',task=t['id'],choice=t['options'].index(cards[0]['options'][0]),mode='assisted')
        assert l['independent']==0 and l['count']==4
        while l['task']:
            t=l['task']
            if t['kind']=='listen':call('aid',task=t['id'],kind='play',event=str(uuid4()))
            l=call('answer',task=t['id'],choice=0,mode=t['kind'])
        assert l['debrief'] and call('dashboard')['complete']
        assert sum(call('dashboard')['signals'].values())==4
        assert call('dashboard',goal='read')['goal']=='read'
        assert call('lesson')['track']=='work'
        assert call('lesson',edition=1)['step']==0
        with sqlite3.connect(path) as c:
            raw=c.execute('select body from coach_course_v2').fetchone()[0]
            assert 'Could I collect my blue coat tomorrow morning instead?' not in json.dumps(json.loads(raw)['answers'])
    for delay in (7,30):
        with patch.object(coach.time,'time',return_value=now+delay*86400):
            call('clock',action='pulse');l=call('lesson');assert l['interval']==delay and l['track']=='read'
    try:studio.prepare_material(author,lambda _: '["FAIL","PASS","PASS"]','condition','life',1000,[],'基线')
    except ValueError:pass
    else:raise AssertionError('rejected material accepted')
# Exclusive timer attribution and voluntary paired training do not grant extra time.
with sqlite3.connect(":memory:") as db:
    coach.init(db)
    def pulse(at,activity,action="pulse"):
        body=coach.ClockIn(client=client,offset=480,action=action,activity=activity)
        return coach.budget(db,"trial",body,at)
    day=pulse(now,"vocab")["day"]
    pulse(now+10,"class");pulse(now+18,"class","stop")
    assert studio.active_seconds(db,"trial",day,now+20)==8
    assert not studio.participation(db,"trial")
    seed=studio.participation(db,"trial",True)
    original=studio.make(db,"trial",day,"life",1000,[])
    assert original["studySeed"]==seed and original["arm"] in ("fixed","adaptive")
    original["answers"]=[{"ok":False,"mode":"read","expected":"行动","at":now}]
    original["activeSeconds"]=120
    coach.save(db,"trial",day,original)
    from datetime import date,timedelta
    day2=(date.fromisoformat(day)+timedelta(days=1)).isoformat()
    pair=studio.make(db,"trial",day2,"life",1000,[])
    assert pair["skill"]==original["skill"] and pair["arm"]!=original["arm"]
    for delta in (7,30):
        later=(date.fromisoformat(day)+timedelta(days=delta)).isoformat()
        test=studio.make(db,"trial",later,"life",1000,[])
        assert test["reviewOf"]==day and test["novel"] and test["arm"]==original["arm"]
        assert test["cards"][-1]["passage"] in [x[1] for x in TRANSFER[test["skill"]]]
        test["answers"]=[{"ok":True,"expected":"行动","mode":"listen"}]*3
        coach.save(db,"trial",later,test)
    # Repeated listening is evidence of a support need even when the chosen action was right.
    repeated=dict(original,answers=[dict(ok=True,mode="listen",replay=True,expected="改去西门",
                                         chosen="改去西门",responses=[{"learner":"PRIVATE"}])])
    skill,reason,_,_=studio.choose([repeated],day2)
    facts=studio.prior_evidence([repeated],skill)
    assert skill==original["skill"] and "重听" in reason and "改去西门" in reason
    assert len(facts)==1 and "PRIVATE" not in json.dumps(facts)
    assert not studio.participation(db,"trial",False)
print('PASS voluntary paired assignment, separate class time and unseen delayed test materials')
print('PASS personalized studio, verified generation, persisted goals, distinct diagnosis, undo, no raw reply, 7-/30-day follow-up')
