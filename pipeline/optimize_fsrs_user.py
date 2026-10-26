# -*- coding: utf-8 -*-
"""用真实复习历史优化 FSRS 参数（fsrs.Optimizer）。

用法：python3 optimize_fsrs_user.py <user_id> [user_id...]
读取 users.db 的学习日志，≥400 条才训练（Anki 官方建议的数量级）。
输出 data/fsrs_optimal_uid<N>.json，主服务按用户加载。
"""
import json
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

from fsrs import ReviewLog
from fsrs.optimizer import Optimizer

ROOT = Path(__file__).resolve().parent.parent
DB = ROOT / "data" / "users.db"
OUT = ROOT / "data"


def optimize(uid: int):
    conn = sqlite3.connect(DB)
    row = conn.execute("SELECT state_json FROM user_state WHERE user_id=?", (uid,)).fetchone()
    if not row:
        print(f"uid{uid}: 无学习状态")
        return
    s = json.loads(row[0])
    lex = sqlite3.connect(OUT / "lexicon_v0.1.sqlite")
    word2id = dict(lex.execute("SELECT word,id FROM lexicon_entry"))
    logs = [x for x in s.get("log", []) if x.get("kind") in ("learn", "review") and 1 <= int(x.get("rating", 0)) <= 4]
    print(f"uid{uid}: 复习记录 {len(logs)} 条")
    if len(logs) < 400:
        print(f"uid{uid}: 少于400条，暂不优化，使用默认参数")
        return
    revlogs = []
    for x in logs:
        wid = int(word2id.get(x.get("word"), 0))
        if wid <= 0:
            # 老日志没有 pos 的不纳入（无法稳定映射 card_id）
            continue
        revlogs.append(ReviewLog(card_id=wid, rating=int(x["rating"]),
                                 review_datetime=datetime.fromisoformat(x["d"] + "T08:00:00+00:00"),
                                 review_duration=None))
    print(f"uid{uid}: 可用于优化 {len(revlogs)} 条，开始训练…", flush=True)
    opt = Optimizer(revlogs)
    params = opt.compute_optimal_parameters(verbose=False)
    result = {"user_id": uid, "review_count": len(revlogs),
              "parameters": params, "desired_retention": 0.9,
              "optimized_at": datetime.now(timezone.utc).isoformat()}
    path = OUT / f"fsrs_optimal_uid{uid}.json"
    path.write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(f"uid{uid}: 已保存 {path}\n参数: {[round(x, 4) for x in params]}")


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        optimize(int(arg))
