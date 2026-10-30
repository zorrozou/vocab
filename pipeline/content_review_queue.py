#!/usr/bin/env python3
"""Export actionable content feedback without account identifiers. Never auto-rewrite."""
import argparse,json,sqlite3
from pathlib import Path
from urllib.parse import quote

def export_queue(data_dir):
    file=Path(data_dir)/'personal.db'
    with sqlite3.connect('file:'+quote(str(file.resolve()),safe='/')+'?mode=ro',uri=True) as db:
        if not db.execute("SELECT 1 FROM sqlite_master WHERE name='content_reports'").fetchone(): return []
        rows=db.execute("SELECT word,kind,text,reason,comment,COUNT(DISTINCT owner),MIN(created),MAX(created) FROM content_reports WHERE status='open' GROUP BY word,kind,text,reason,comment ORDER BY COUNT(DISTINCT owner) DESC,MIN(created)").fetchall()
    keys=('word','kind','text','reason','comment','reporters','first_reported','last_reported')
    return [dict(zip(keys,row)) for row in rows]

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--data-dir',type=Path,required=True);p.add_argument('--output',type=Path,required=True);args=p.parse_args()
    rows=export_queue(args.data_dir);args.output.write_text(json.dumps({'pending':len(rows),'items':rows},ensure_ascii=False,indent=2));print(f'待复核 {len(rows)} 项；未改变词库或学习状态')
