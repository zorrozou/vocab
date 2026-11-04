"""Verify paired copy after rotation and branching, including persisted courses and backfill."""
import copy
from datetime import date,timedelta
import json
import sqlite3
from app import coach,coach_studio as studio
from app.coach_curriculum import CASES,TRANSFER
from app.coach_english import LEGACY
from app.coach_material import PACK
from backfill_coach_english import apply,key,pending

assert set(studio.SKILLS)==set(CASES)==set(TRANSFER)
cases=[(skill,c) for skill,group in CASES.items() for c in group.values()]
held=[(skill,dict(zip(("title","passage","question","options","proof","reply"),row),checks=[])) for skill,rows in TRANSFER.items() for row in rows]
for skill,card in cases+held:
    en=studio.english_copy(card)
    studio.validate_english(en,card)
    rotations=set()
    for n in range(32):
        day=(date(2026,1,1)+timedelta(days=n)).isoformat()
        lesson=dict(edition=2,day=day,skill=skill,track="life",cards=[card]*3,answers=[],source="教研课程",words=[],interval=0,reason="测试")
        task,right,_=coach.task(lesson,0)
        rotations.add(right)
        mapping=dict(zip(card["options"],en["options"]))
        assert task["questionEn"]==en["question"]
        assert task["optionsEn"]==[mapping[o] for o in task["options"]]
        assert task["optionsEn"][right]==en["options"][0] and not ({"english","proof","explanationEn","right"} & task.keys())
        for gap,(zh,english) in enumerate(zip(card["checks"],en["checks"])):
            lesson["answers"]=[dict(ok=False,gap=gap,mode="listen",expected=card["options"][0],chosen=card["options"][gap+1])]
            diag,r,_=coach.task(lesson,1);assert diag["question"]==zh[0] and diag["questionEn"]==english[0]
            assert diag["optionsEn"][r]==english[1] and diag["optionsEn"][1-r]==english[2]
            feedback=coach.present(lesson)["last"]
            assert feedback["expectedEn"]==en["options"][0] and feedback["explanationEn"]==en["proof"]
    assert rotations=={0,1,2}
for skill,group in PACK.items():
    for track in ("life","work"):
        for i,values in enumerate(group[track]):
            l=dict(day="2026-01-01",skill=skill,track=track,variant=i,answers=[])
            t,r,_=coach.task(l,0);q,correct,wrong,_=LEGACY[values[1]]
            assert t["questionEn"]==q and t["optionsEn"][r]==correct and t["optionsEn"][1-r]==wrong

with sqlite3.connect(":memory:") as db:
    coach.init(db)
    card=copy.deepcopy(cases[0][1]);card["passage"]="A synthetic archived message about a pickup."
    lesson=dict(cards=[card],answers=[{"id":"preserved","choice":2}],revisions={"0":1})
    db.execute("insert into coach_course_v2 values('owner','2026-01-01',?)",(json.dumps(lesson),));db.commit()
    en=studio.english_copy(cases[0][1]);bad=dict(en,options=["same"]*3)
    assert len(pending(db))==1
    try:apply(db,{key(card):bad})
    except studio.MaterialRejected:pass
    else:raise AssertionError("invalid English options were accepted")
    assert apply(db,{key(card):en})==1 and not pending(db) and apply(db,{key(card):en})==0
    saved=json.loads(db.execute("select body from coach_course_v2").fetchone()[0])
    assert saved["cards"][0].pop("english")==en and saved==lesson
print("PASS 12 studio lessons, 8 delayed assessments, 18 legacy scenes, choice rotation, both diagnostics, backfill and idempotence")
