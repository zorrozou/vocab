#!/usr/bin/env python3
"""Capacity stress model using the project's real py-fsrs scheduler.

This is a scenario model, not a prediction of a person's memory. Each active
study day reserves ten new words, then admits the oldest due unmastered cards
up to 100 distinct words. Same-day learning steps reuse those slots. The model includes immediate acceptance and the production mastery evaluator,
omits optional probes and assumes a two-hour session;
use client queue regressions separately to verify implementation parity.
"""
import argparse, heapq, json, random, sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"server"))
from app.study_policy import is_mastered
from datetime import datetime, timedelta, timezone
from importlib.metadata import version
from fsrs import Card, Rating, Scheduler, State


def mastered(card, evidence):
    return is_mastered({'fsrs':{'state':card.state.value,'stability':card.stability or 0,'difficulty':card.difficulty or 0},'studyEvidence':evidence})


def simulate(days=365, seed=7, recall_factor=1.0, break_start=0, break_days=0):
    rng=random.Random(seed)
    scheduler=Scheduler(enable_fuzzing=False)
    cards={}; evidence={}
    start=datetime(2026,1,1,0,tzinfo=timezone.utc)
    rows=[]
    for day in range(days):
        now=start+timedelta(days=day)
        due=sorted((card for card in cards.values() if not mastered(card,evidence[card.card_id]) and card.due<=now),key=lambda c:(c.due,c.card_id))
        active=not (break_start<=day<break_start+break_days)
        selected=due[:90] if active else []
        assert not any(mastered(c,evidence[c.card_id]) for c in selected)
        events=[]
        distinct=set()
        attempts={}
        if active:
            for card in selected:
                heapq.heappush(events,(now,card.card_id,"review"))
            for _ in range(10):
                ident=len(cards)+1
                cards[ident]=Card(card_id=ident,due=now)
                evidence[ident]={"version":1,"originAt":now.isoformat(),"legacy":False,"originIds":[],"events":{}}
                heapq.heappush(events,(now,ident,"learn"))
        while events:
            at,ident,kind=heapq.heappop(events)
            card=cards[ident]
            if kind == "review" and card.due > at: continue
            distinct.add(ident)
            attempts[ident]=attempts.get(ident,0)+1
            if kind == "learn":
                rating=Rating.Good
            else:
                recall=scheduler.get_card_retrievability(card,at)
                rating=Rating.Again if rng.random()>min(1,recall*recall_factor) else rng.choices([Rating.Hard,Rating.Good,Rating.Easy],[.1,.8,.1])[0]
            prior = card.last_review
            evidence[ident]['events'][f'{day}-{attempts[ident]}']={'at':at.isoformat(),'day':at.date().isoformat(),'rating':rating.value,'kind':kind,'verified':kind=='review' and rating.value>=3,**({'priorAt':prior.isoformat()} if prior else {})}
            card,_=scheduler.review_card(card,rating,review_datetime=at)
            if kind == "learn": heapq.heappush(events,(at+timedelta(minutes=1),ident,"acceptance"))
            cards[ident]=card
            if card.state in (State.Learning,State.Relearning) and card.due<=now+timedelta(hours=2) and attempts[ident]<30:
                heapq.heappush(events,(max(card.due,at+timedelta(seconds=1)),ident,"review"))
        assert len(distinct)<=100
        end=now+timedelta(hours=2)
        backlog=sum(not mastered(c,evidence[c.card_id]) and c.due<=end for c in cards.values())
        rows.append({'day':day+1,'distinct':len(distinct),'attempts':sum(attempts.values()),'backlog':backlog,
                     'mastered':sum(mastered(c,evidence[c.card_id]) for c in cards.values()),'learned':len(cards)})
    return {'seed':seed,'recall_factor':recall_factor,'break_start':break_start,'break_days':break_days,
            'maximum_distinct':max(r['distinct'] for r in rows),'maximum_attempts':max(r['attempts'] for r in rows),
            'maximum_backlog':max(r['backlog'] for r in rows),'final':rows[-1],
            'last_30_mean_distinct':round(sum(r['distinct'] for r in rows[-30:])/min(days,30),1)}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--days',type=int,default=365)
    parser.add_argument('--seeds',type=int,nargs='+',default=[7,17,27])
    args=parser.parse_args()
    if args.days<1: parser.error('days must be positive')
    scenarios=[(1.0,0,0),(.85,0,0),(.65,0,0),(1.0,150,7)]
    print(json.dumps({'fsrs_version':version('fsrs'),'days':args.days,'new_per_active_day':10,'distinct_cap':100,
                      'results':[simulate(args.days,seed,factor,pause,length) for factor,pause,length in scenarios for seed in args.seeds]},ensure_ascii=False,indent=2))

if __name__=='__main__': main()
