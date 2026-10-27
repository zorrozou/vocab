#!/usr/bin/env python3
"""多设备学习状态合并回归测试（server/app/auth.py::merge_learning_states）"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "server"))
from app.auth import merge_learning_states


def log(day, word, rating=3, kind="review"):
    return {"d": day, "word": word, "rating": rating, "kind": kind}


def card(stability):
    return {"due": "2026-11-01T08:00:00Z", "fsrs": {"state": 2, "stability": stability, "difficulty": 5}}


def base():
    return {
        "v": 1, "calibrated": True, "frontier": 3000, "pointer": 4000,
        "probeCount": 20, "posterior": [0.2, 0.8],
        "cards": {}, "log": [], "pendingNew": [], "personalized": {},
        "settings": {"newPerDay": 10}, "streak": 3,
    }


def main():
    old = base()
    old["log"] = [log("2026-10-20", "apple"), log("2026-10-21", "banana")]
    old["cards"] = {"apple": card(5), "banana": card(7)}
    old["pendingNew"] = [{"word": "cherry", "pos": 5000}]

    # 旧设备只有 apple，后写入也不能丢掉 banana 及 pendingNew
    stale = base()
    stale["pointer"] = 3500
    stale["probeCount"] = 10
    stale["posterior"] = [0.9, 0.1]
    stale["log"] = [log("2026-10-20", "apple")]
    stale["cards"] = {"apple": card(5)}
    stale["settings"] = {"newPerDay": 12}
    merged = merge_learning_states(old, stale)
    assert len(merged["log"]) == 2
    assert set(merged["cards"]) == {"apple", "banana"}
    assert merged["pointer"] == 4000
    assert merged["probeCount"] == 20 and merged["posterior"] == [0.2, 0.8]
    assert merged["pendingNew"][0]["word"] == "cherry"
    assert merged["settings"]["newPerDay"] == 12

    # 两台设备各学一个词：并集保留，重复事件不翻倍
    other = base()
    other["log"] = [log("2026-10-20", "apple"), log("2026-10-22", "delta")]
    other["cards"] = {"apple": card(5), "delta": card(2)}
    merged = merge_learning_states(old, other)
    assert len(merged["log"]) == 3, merged["log"]
    assert set(merged["cards"]) == {"apple", "banana", "delta"}

    # 完全相同的重复学习事件是真实事件：计数取 max，不去重成 1，也不累加翻倍
    twice_old = base()
    twice_old["log"] = [log("2026-10-20", "apple", 1), log("2026-10-20", "apple", 1)]
    once_new = base()
    once_new["log"] = [log("2026-10-20", "apple", 1)]
    assert len(merge_learning_states(twice_old, once_new)["log"]) == 2
    thrice_new = base()
    thrice_new["log"] = [log("2026-10-20", "apple", 1)] * 3
    assert len(merge_learning_states(twice_old, thrice_new)["log"]) == 3

    # 同一词在不同设备学习：最近学习日较新的卡获胜
    older = base()
    older["log"] = [log("2026-10-20", "apple")]
    older["cards"] = {"apple": card(5)}
    newer = base()
    newer["log"] = [log("2026-10-21", "apple", 1)]
    newer["cards"] = {"apple": card(1.2)}
    merged = merge_learning_states(older, newer)
    assert merged["cards"]["apple"]["fsrs"]["stability"] == 1.2
    assert merge_learning_states(newer, older)["cards"]["apple"]["fsrs"]["stability"] == 1.2

    # frontier 变化表示重新定级：接受新 frontier/pointer，不被 max 游标规则卡住
    repl = base()
    repl["frontier"] = 5000
    repl["pointer"] = 5001
    merged = merge_learning_states(old, repl)
    assert merged["frontier"] == 5000 and merged["pointer"] == 5001

    # 个性化句按词合并，同词取新写入
    a = base()
    a["personalized"] = {"apple": {"text": "old"}}
    b = base()
    b["personalized"] = {"apple": {"text": "new"}, "banana": {"text": "b"}}
    merged = merge_learning_states(a, b)
    assert merged["personalized"]["apple"]["text"] == "new"
    assert merged["personalized"]["banana"]["text"] == "b"

    # 显式重新定级：旧 probeCount 再大，也不能撤销新后验
    reset_old = base()
    reset_old["probeCount"] = 1000
    reset_old["posterior"] = [1.0, 0.0]
    reset_old["placementResetAt"] = 100.0
    reset_new = base()
    reset_new["probeCount"] = 12
    reset_new["posterior"] = [0.0, 1.0]
    reset_new["placementResetAt"] = 200.0
    merged = merge_learning_states(reset_old, reset_new)
    assert merged["probeCount"] == 12 and merged["posterior"] == [0.0, 1.0]
    assert merged["placementResetAt"] == 200.0
    # 老客户端没有 marker，但明确清空了后验，也识别为重置
    reset_new2 = base()
    reset_new2["probeCount"] = 0
    reset_new2["posterior"] = None
    merged = merge_learning_states(reset_old, reset_new2)
    assert merged["probeCount"] == 0 and merged["posterior"] is None
    assert merged["placementResetAt"] > 100.0

    # v2.0 新字段：缺字段不清空，证据更多的一侧优先；日志合并后仍受上限
    rich = base()
    rich["bandStats"] = {"2": {"a": 3, "b": 1}, "3": {"a": 1, "b": 2}}
    rich["knowledge"] = {"apple": {"a": 4, "b": 1, "pos": 3000}}
    poor = base()
    poor["log"] = [log("2026-10-20", f"w{i}") for i in range(1300)]
    merged = merge_learning_states(rich, poor)
    assert merged["bandStats"]["2"]["a"] == 3
    assert merged["knowledge"]["apple"]["a"] == 4
    assert len(merged["log"]) == 1200
    newer = base()
    newer["bandStats"] = {"2": {"a": 5, "b": 0}}
    newer["knowledge"] = {"apple": {"a": 6, "b": 0, "pos": 3000}}
    merged = merge_learning_states(rich, newer)
    assert merged["bandStats"]["2"]["a"] == 5
    assert merged["knowledge"]["apple"]["a"] == 6

    print("PASS 多设备状态合并：日志并集/计数保真/卡片新旧/游标/后验/重新定级/个性化 全部通过")


if __name__ == "__main__":
    main()
