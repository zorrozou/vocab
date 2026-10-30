#!/usr/bin/env python3
"""Bounded content repair: read-only proposal, separate reviewed transactional apply.
Uses the configured existing LLM provider for public lexicon text only.
"""
import argparse,json,os,re,sqlite3,sys,time,urllib.request
from concurrent.futures import ThreadPoolExecutor,as_completed
from pathlib import Path
from audit_learning_content import audit
from app.content_quality import sentence_issue,valid_word
from app.core_senses import OVERRIDES,apply_overrides

def call(prompt):
    base=os.environ.get('LLM_BASE_URL','https://open.bigmodel.cn/api/paas/v4').rstrip('/')
    key=os.environ.get('LLM_API_KEY','')
    if not key: raise ValueError('LLM key unavailable')
    body={'model':os.environ.get('LLM_MODEL','glm-4.6'),'messages':[{'role':'user','content':prompt}],
          'thinking':{'type':'disabled'},'temperature':.2,'max_tokens':4500}
    req=urllib.request.Request(base+'/chat/completions',data=json.dumps(body).encode(),headers={'Content-Type':'application/json','Authorization':'Bearer '+key})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req,timeout=100) as r: text=json.load(r)['choices'][0]['message']['content']
            return json.loads(text[text.index('['):text.rindex(']')+1])
        except Exception:
            if attempt==2: raise
            time.sleep(2)

def propose(db,output):
    report=audit(db);c=sqlite3.connect(f'file:{Path(db).resolve()}?mode=ro',uri=True)
    words={w:(i,s or '') for i,w,s in c.execute("SELECT e.id,e.word,s.text FROM lexicon_entry e LEFT JOIN sense s ON s.wordId=e.id AND s.role='core'")}
    tasks=[]
    for m in report['missing_tiers']:
        for tier in m['tiers']: tasks.append({'word':m['word'],'tier':tier,'text':'','zh':'','sid':None,'action':'generate'})
    for i in report['issues']:
        if i['reason']=='missing-translation': tasks.append({'word':i['word'],'tier':i['tier'],'text':i['text'],'zh':'','sid':i['id'],'action':'translate'})
    # Re-evaluate historical low-level function-word backlog and a known lexical misuse.
    for sid,w,tier,text,zh in c.execute("""SELECT s.id,e.word,s.tier,s.text,s.translation FROM sentence s JOIN lexicon_entry e ON e.id=s.targetWordId JOIN sense g ON g.wordId=e.id AND g.role='core'
        WHERE (e.level=1 AND (g.pos LIKE 'prep%' OR g.pos LIKE 'pron%' OR g.pos LIKE 'conj%' OR g.pos LIKE 'art%' OR g.pos LIKE 'num%') OR e.word='mike')
        AND COALESCE(s.flag,'')!='reported' AND (s.genMethod LIKE 'llm-%' OR s.genMethod='tatoeba') ORDER BY s.id"""):
        if valid_word(w): tasks.append({'word':w,'tier':tier,'text':text,'zh':zh or '', 'sid':sid,'action':'review'})
    for sid,w,tier,text,zh in c.execute("SELECT s.id,e.word,s.tier,s.text,s.translation FROM sentence s JOIN lexicon_entry e ON e.id=s.targetWordId WHERE COALESCE(s.flag,'')!='reported' AND (s.genMethod LIKE 'llm-%' OR s.genMethod='tatoeba') ORDER BY s.id"):
        if w in OVERRIDES: tasks.append({'word':w,'tier':tier,'text':text,'zh':zh or '', 'sid':sid,'action':'review'})
    # Never repair a row twice.
    unique={('sid',t['sid']) if t['sid'] else ('new',t['word'],t['tier']):t for t in tasks};tasks=list(unique.values())
    for i,t in enumerate(tasks): t.update(id=i,sense=words[t['word']][1])
    accepted=[];failed=[]
    if Path(output).exists():
        old=json.loads(Path(output).read_text())
        by_key={(r['sid'],r['word'],r['tier']):r for r in old.get('accepted',[]) if r['word'] not in OVERRIDES}
        todo=[]
        for t in tasks:
            prior=by_key.get((t['sid'],t['word'],t['tier']))
            if prior and prior.get('sense')==t['sense']:accepted.append({**prior,'id':t['id']})
            else:todo.append(t)
        tasks=todo
    def batch(rows):
        result=call('你是英语教材编辑。逐项处理下列任务。review：只在原句语法、自然度、目标词词义有错误时改写，否则保留原句。translate：保留英文、补完整中文。generate：补一条自然的真实场景例句。必须使用给定目标词的核心词义，除目标词外用简单常用词；tier1用3~12词简单句，tier2用5~18词短语扩展句，tier3用8~22词含自然从句的句子。勿强求复杂结构而拼凑。返回JSON数组，每项含id,text,zh。不得省略任务。\n'+json.dumps(rows,ensure_ascii=False))
        by_id={x.get('id'):x for x in result if isinstance(x,dict)}
        proposed=[];reject=[]
        for row in rows:
            cand=by_id.get(row['id'],{})
            if not isinstance(cand.get('text'),str) or not isinstance(cand.get('zh'),str) or not re.search('[\u4e00-\u9fff]',cand['zh']) or sentence_issue(cand['text'],row['word']): reject.append(row);continue
            if row['action']=='translate' and cand['text']!=row['text']:reject.append(row);continue
            if len(re.findall(r"[A-Za-z']+",cand['text']))>22:reject.append(row);continue
            proposed.append({**row,'replacement':cand['text'].strip(),'translation':cand['zh'].strip()})
        if not proposed:return [],reject
        scores=call('独立复核英语教材例句。逐项按1~5评分：5=语法、搭配、目标词核心义和中文均准确自然；4=可用；3及以下=有问题或生硬。严审词义，不能只看句子通顺。返回JSON数组，每项含id,score,reason。\n'+json.dumps([{'id':r['id'],'word':r['word'],'sense':r['sense'],'text':r['replacement'],'zh':r['translation']} for r in proposed],ensure_ascii=False))
        score={x.get('id'):x for x in scores if isinstance(x,dict)}
        good=[]
        for r in proposed:
            v=score.get(r['id'],{})
            if type(v.get('score')) is int and 4<=v['score']<=5: good.append({**r,'review_score':v['score'],'review_reason':v.get('reason','')})
            else:reject.append({**r,"rejection":v.get("reason","missing review score")})
        return good,reject
    print(f'Tasks {len(tasks)}; bounded batches of 8, 4 workers',flush=True)
    for round in range(2):
        if not tasks:break
        failed=[]
        with ThreadPoolExecutor(max_workers=4) as pool:
            futures={pool.submit(batch,tasks[i:i+8]):tasks[i:i+8] for i in range(0,len(tasks),8)}
            for f in as_completed(futures):
                try:g,b=f.result();accepted.extend(g);failed.extend(b)
                except Exception as e:failed.extend(futures[f]);print('Batch failed',type(e).__name__,flush=True)
                Path(output).write_text(json.dumps({'accepted':accepted,'failed':failed,'total':len(unique),'pending':len(tasks)},ensure_ascii=False,indent=2))
                print(f'round {round+1}: accepted {len(accepted)}; retry {len(failed)}',flush=True)
        tasks=failed
    Path(output).write_text(json.dumps({'accepted':accepted,'failed':failed,'total':len(unique),'pending':0},ensure_ascii=False,indent=2))
    print('DONE',len(accepted),'accepted',len(failed),'failed',flush=True)

def apply(db,patch):
    result=json.loads(Path(patch).read_text());c=sqlite3.connect(db,timeout=30)
    c.execute('BEGIN IMMEDIATE');apply_overrides(c);counts={'updated':0,'inserted':0,'unchanged':0}
    c.execute("CREATE TABLE IF NOT EXISTS content_repair_history(id INTEGER PRIMARY KEY,sentence_id INTEGER,original_json TEXT,replacement_json TEXT,applied_at TEXT DEFAULT CURRENT_TIMESTAMP)")
    word_ids=dict(c.execute('SELECT word,id FROM lexicon_entry'))
    variants=dict(c.execute('SELECT variant,lemma FROM variant_map'))
    def sentence_ids(text,wid):
        found={word_ids.get(variants.get(t,t)) for t in re.findall(r"[a-z']+",text.lower())}
        return json.dumps(sorted((found-{None})|{wid}))
    try:
        for row in result['accepted']:
            if row['review_score']<4 or sentence_issue(row['replacement'],row['word']):raise ValueError('Invalid patch')
            wid=c.execute('SELECT id FROM lexicon_entry WHERE word=?',(row['word'],)).fetchone()[0]
            if row['sid']:
                old=c.execute('SELECT text,translation FROM sentence WHERE id=? AND targetWordId=?',(row['sid'],wid)).fetchone()
                if old is None:raise ValueError('Missing sentence')
                if old==(row['replacement'],row['translation']):counts['unchanged']+=1;continue
                if (old[0],old[1] or '')!=(row['text'],row.get('zh') or ''):raise ValueError('Concurrent content edit: '+str(row['sid']))
                original=c.execute('SELECT * FROM sentence WHERE id=?',(row['sid'],)).fetchone()
                c.execute("INSERT INTO content_repair_history(sentence_id,original_json,replacement_json) VALUES(?,?,?)",(row['sid'],json.dumps(original,ensure_ascii=False),json.dumps(row,ensure_ascii=False)))
                c.execute("UPDATE sentence SET genMethod=CASE WHEN text!=? THEN 'llm-quality-v2' ELSE genMethod END,text=?,translation=?,wordIds=?,flag='quality-v2' WHERE id=?",(row['replacement'],row['replacement'],row['translation'],sentence_ids(row['replacement'],wid),row['sid']));counts['updated']+=1
            elif not c.execute('SELECT 1 FROM sentence WHERE targetWordId=? AND tier=? AND text=?',(wid,row['tier'],row['replacement'])).fetchone():
                c.execute("INSERT INTO sentence(text,translation,wordIds,targetWordId,recallIds,genMethod,flag,tier) VALUES(?,?,?,?,?,'llm-quality-v2','quality-v2',?)",(row['replacement'],row['translation'],sentence_ids(row['replacement'],wid),wid,'[]',row['tier']));counts['inserted']+=1
            else: counts['unchanged']+=1
        c.commit();print(json.dumps(counts))
    except: c.rollback();raise
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('database');p.add_argument('patch');p.add_argument('--apply',action='store_true');a=p.parse_args()
    (apply if a.apply else propose)(a.database,a.patch)
