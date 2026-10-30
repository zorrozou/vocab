#!/usr/bin/env python3
"""Read-only exhaustive corpus audit; JSON report contains every actionable row."""
import argparse,json,sqlite3,sys
from pathlib import Path
_project=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(_project/'server' if (_project/'server'/'app').is_dir() else _project))
from app.content_quality import valid_word,sentence_issue,translation_issue

def audit(db):
    c=sqlite3.connect(f'file:{Path(db).resolve()}?mode=ro',uri=True)
    variants=dict(c.execute('SELECT variant,lemma FROM variant_map'))
    rows=c.execute("SELECT s.id,e.word,s.tier,s.text,s.translation,s.genMethod FROM sentence s JOIN lexicon_entry e ON e.id=s.targetWordId WHERE COALESCE(s.flag,'')!='reported' AND (s.genMethod='tatoeba' OR s.genMethod LIKE 'llm-%') ORDER BY s.id").fetchall()
    issues=[];available=set();selected={}
    for sid,word,tier,text,zh,method in rows:
        reason=sentence_issue(text,word,lambda t:variants.get(t,t))
        if reason: issues.append({'id':sid,'word':word,'tier':tier,'reason':reason,'text':text})
        elif translation_issue(zh): issues.append({'id':sid,'word':word,'tier':tier,'reason':translation_issue(zh),'text':text})
        else:
            available.add((word,tier))
            score=(0 if method=='tatoeba' else 1,-sid)
            if (word,tier) not in selected or score<selected[word,tier][0]: selected[word,tier]=(score,sid,text)
    words=[r[0] for r in c.execute('SELECT word FROM lexicon_entry ORDER BY id')]
    return {'words':len(words),'sentences_checked':len(rows),'blocked_words':[w for w in words if not valid_word(w)],
            'issues':issues,'missing_tiers':[{'word':w,'tiers':[t for t in (1,2,3) if (w,t) not in available]} for w in words if valid_word(w) and any((w,t) not in available for t in (1,2,3))],
            'selected_count':len(selected)}
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('database');p.add_argument('--output',required=True);a=p.parse_args()
    report=audit(a.database);Path(a.output).write_text(json.dumps(report,ensure_ascii=False,indent=2))
    print(json.dumps({k:v if k in ('words','sentences_checked','selected_count') else len(v) for k,v in report.items()}))
