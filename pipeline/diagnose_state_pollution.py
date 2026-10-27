# -*- coding: utf-8 -*-
"""跨账号状态污染只读诊断：比较两个账号的 frontier/track/pointer/posterior。
不修改任何数据，只输出疑似共享状态的字段，供用户重新定级/修复前备份审查。
用法：python3 diagnose_state_pollution.py [uidA uidB]
"""
import hashlib
import json
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB = ROOT / "data" / "users.db"


def canon(x):
    return json.dumps(x, ensure_ascii=False, sort_keys=True)


def main():
    uids = [int(x) for x in sys.argv[1:]] or [3, 6]
    conn = sqlite3.connect(DB)
    states = {}
    for uid in uids:
        row = conn.execute("SELECT state_json FROM user_state WHERE user_id=?", (uid,)).fetchone()
        if row:
            states[uid] = json.loads(row[0])
    for i, a in enumerate(uids):
        if a not in states:
            continue
        for b in uids[i + 1:]:
            if b not in states:
                continue
            sa, sb = states[a], states[b]
            print(f"\n=== uid{a} vs uid{b} ===")
            for field in ("frontier", "pointer", "probeCount", "track"):
                va, vb = sa.get(field), sb.get(field)
                if va == vb and va is not None:
                    print(f"相同 {field}: {canon(va)}")
            pa, pb = sa.get("posterior"), sb.get("posterior")
            if pa and pb and canon(pa) == canon(pb):
                print("posterior 完全相同（高度疑似共享/污染）")
            ca, cb = set((sa.get("cards") or {}).keys()), set((sb.get("cards") or {}).keys())
            print(f"卡片数: {len(ca)} vs {len(cb)}；交集 {len(ca & cb)}")
            print(f"日志数: {len(sa.get('log', []))} vs {len(sb.get('log', []))}")
            print("建议：先备份 users.db，再由对应用户重新定级/继续学习纠偏，不要直接手工改库。")


if __name__ == "__main__":
    main()
