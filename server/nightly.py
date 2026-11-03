# -*- coding: utf-8 -*-
"""夜间批处理：处理白天排队的 personalize 请求（cron 每天 03:00 运行）"""
import json, sqlite3, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from app.main import generate, init_db, PERSONAL_DB, ReviewUnavailable  # noqa: E402


def main():
    init_db()
    conn = sqlite3.connect(PERSONAL_DB)
    rows = conn.execute("SELECT rowid, device, date, payload FROM requests WHERE processed=0").fetchall()
    total = 0
    for rowid, device, date, payload in rows:
        p = json.loads(payload)
        # 旧版本把即时任务也放进夜间队列；不要清除它已经生成的结果。
        if p.get("sync"):
            conn.execute("UPDATE requests SET processed=1 WHERE rowid=?", (rowid,))
            conn.commit()
            continue
        words = list(dict.fromkeys(p.get("weak_words", [])))
        accepted = []
        def collect(target, recall, text, zh):
            accepted.append((device, date, target, recall, text, time.time(), zh))
        try:
            generate(device, date, words, p.get("learned_max_pos", 300), on_sentence=collect)
        except ReviewUnavailable:
            print(f"[{time.strftime('%F %T')}] 评审服务暂不可用，保留原句和待处理任务")
            break
        with conn:
            if not conn.execute("UPDATE requests SET processed=1 WHERE rowid=? AND processed=0", (rowid,)).rowcount:
                continue
            if len(accepted) == len(words):
                conn.execute("DELETE FROM sentences WHERE device=? AND date=?", (device, date))
            else:
                conn.executemany("DELETE FROM sentences WHERE device=? AND date=? AND target=?",
                                 [row[:3] for row in accepted])
            conn.executemany("INSERT INTO sentences(device,date,target,recall,text,created,zh) VALUES(?,?,?,?,?,?,?)", accepted)
        total += len(accepted)
        print(f"[{time.strftime('%F %T')}] {date}: 生成 {len(accepted)} 条")
    conn.close()
    print(f"[{time.strftime('%F %T')}] 本轮共生成 {total} 条")


if __name__ == "__main__":
    main()
