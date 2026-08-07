# -*- coding: utf-8 -*-
"""夜间批处理：处理白天排队的 personalize 请求（cron 每天 03:00 运行）"""
import json, sqlite3, sys, time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from app.main import generate, init_db, PERSONAL_DB  # noqa: E402


def main():
    init_db()
    conn = sqlite3.connect(PERSONAL_DB)
    rows = conn.execute("SELECT rowid, device, date, payload FROM requests WHERE processed=0").fetchall()
    total = 0
    for rowid, device, date, payload in rows:
        p = json.loads(payload)
        # 幂等：重跑先清掉该设备当日旧句
        conn.execute("DELETE FROM sentences WHERE device=? AND date=?", (device, date))
        conn.commit()
        n = generate(device, date, p.get("new_words", []), p.get("weak_words", []),
                     p.get("learned_max_pos", 300))
        conn.execute("UPDATE requests SET processed=1 WHERE rowid=?", (rowid,))
        conn.commit()
        total += n
        print(f"[{time.strftime('%F %T')}] {device} {date}: 生成 {n} 条")
    conn.close()
    print(f"[{time.strftime('%F %T')}] 完成，处理 {len(rows)} 个请求，共 {total} 条")


if __name__ == "__main__":
    main()
