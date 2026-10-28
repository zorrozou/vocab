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
    assert list(merged["cards"]) == ["apple", "banana", "delta"]

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
    legacy_old = dict(reset_old)
    legacy_old.pop("placementResetAt")
    merged = merge_learning_states(legacy_old, reset_new2)
    assert merged["probeCount"] == 0 and merged["posterior"] is None
    assert merged["placementResetAt"] > 100.0

    # 重测完成后旧设备晚到：整个定级状态必须保持在较新 epoch。
    reset_new["frontier"] = 5000
    reset_new["pointer"] = 5001
    reset_new["track"] = {"evalDay": "2026-10-27"}
    reset_new["bandStats"] = {"2": {"a": 1, "b": 0}}
    reset_old["frontier"] = 3000
    reset_old["pointer"] = 3001
    reset_old["bandStats"] = {"2": {"a": 100, "b": 0}}
    merged = merge_learning_states(reset_new, reset_old)
    assert (merged["frontier"], merged["pointer"], merged["probeCount"]) == (5000, 5001, 12)
    assert merged["posterior"] == [0.0, 1.0] and merged["placementResetAt"] == 200
    assert merged["track"] == reset_new["track"] and merged["bandStats"] == reset_new["bandStats"]

    # 离线评分不能被同起点的旧卡覆盖，重放完成后旧设备也不能让它复活。
    from fastapi import HTTPException
    baseline = {"state": 2, "stability": 5, "difficulty": 4, "due": "2026-10-20T00:00:00Z",
                "step": None, "lastReview": "2026-10-15T00:00:00Z"}
    replay_base = {"is_new": False, "state": 2, "stability": 5, "difficulty": 4,
                   "due": baseline["due"], "step": None, "last_review": baseline["lastReview"]}
    offline = base(); offline["cards"] = {"apple": {"fsrs": baseline, "due": "2026-10-28",
        "pendingFsrs": {"base": replay_base, "events": [{"id": "offline-a", "rating": 1, "at": "2026-10-27T00:00:00Z"}]}}}
    stale = base(); stale["cards"] = {"apple": {"fsrs": baseline, "due": baseline["due"]}}
    assert merge_learning_states(offline, stale)["cards"]["apple"]["pendingFsrs"]["events"][0]["id"] == "offline-a"
    done = base(); done["cards"] = {"apple": {"fsrs": {**baseline, "lastReview": "2026-10-27T00:00:00Z"},
                                              "appliedFsrs": ["offline-a"]}}
    for left, right in ((offline, done), (done, offline)):
        card_out = merge_learning_states(left, right)["cards"]["apple"]
        assert "pendingFsrs" not in card_out and card_out["appliedFsrs"] == ["offline-a"]
        assert card_out["fsrs"]["lastReview"] == "2026-10-27T00:00:00Z"
    diverged = base(); diverged["cards"] = {"apple": {"fsrs": {**baseline, "lastReview": "2026-10-26T00:00:00Z"}}}
    try:
        merge_learning_states(offline, diverged)
        raise AssertionError("conflicting offline event was silently overwritten")
    except HTTPException as exc:
        assert exc.status_code == 409

    # 旧设备不能让已入卡的待学词复活，重复待学项应去重。
    pending_old = base(); pending_old["pendingNew"] = [{"word": "apple", "pos": 1}]
    learned_new = base(); learned_new["cards"] = {"apple": card(5)}
    learned_new["pendingNew"] = [{"word": "banana", "pos": 2}, {"word": "banana", "pos": 2}]
    assert merge_learning_states(pending_old, learned_new)["pendingNew"] == [{"word": "banana", "pos": 2}]
    assert merge_learning_states(learned_new, pending_old)["pendingNew"] == [{"word": "banana", "pos": 2}]

    # 断签后以较新的学习日为准，旧设备的高连续天数不能复活。
    stale_streak = base(); stale_streak.update(lastDay="2026-10-20", streak=20)
    recent_streak = base(); recent_streak.update(lastDay="2026-10-27", streak=1)
    assert merge_learning_states(stale_streak, recent_streak)["streak"] == 1
    assert merge_learning_states(recent_streak, stale_streak)["streak"] == 1

    # 同日跨设备验收取并集；日期变化时只保留新一天的结果，兼容缺字段的旧客户端。
    qa = base(); qa.update(quizProgressDay="2026-10-27", quizCompleted=["apple"])
    qb = base(); qb.update(quizProgressDay="2026-10-27", quizCompleted=["banana"])
    assert merge_learning_states(qa, qb)["quizCompleted"] == ["apple", "banana"]
    assert merge_learning_states(qa, base())["quizCompleted"] == ["apple"]
    qc = base(); qc.update(quizProgressDay="2026-10-28", quizCompleted=["cherry"])
    later = merge_learning_states(qa, qc)
    assert later["quizProgressDay"] == "2026-10-28" and later["quizCompleted"] == ["cherry"]

    # 待处理的个性化任务不能因旧客户端缺字段丢失；终态不被旧快照回退。
    queued_job = {"id": "job-12345678", "date": "2026-10-27", "status": "queued"}
    waiting = base(); waiting["personalJobs"] = [queued_job]
    assert merge_learning_states(waiting, base())["personalJobs"] == [queued_job]
    completed = base(); completed["personalJobs"] = [{**queued_job, "status": "complete"}]
    assert merge_learning_states(completed, waiting)["personalJobs"][0]["status"] == "complete"

    # v2.0 新字段：缺字段不清空，证据更多的一侧优先；近期学习计数不能被截断。
    rich = base()
    rich["bandStats"] = {"2": {"a": 3, "b": 1}, "3": {"a": 1, "b": 2}}
    rich["knowledge"] = {"apple": {"a": 4, "b": 1, "pos": 3000}}
    poor = base()
    poor["log"] = [log("2026-10-20", f"w{i}") for i in range(1300)]
    merged = merge_learning_states(rich, poor)
    assert merged["bandStats"]["2"]["a"] == 3
    assert merged["knowledge"]["apple"]["a"] == 4
    assert len(merged["log"]) == 1300
    busy = base()
    busy["log"] = [log("2026-10-27", "apple")] + [
        {"d":"2026-10-27", "word":f"zz{i:04}", "kind":"exposure", "rating":3}
        for i in range(1400)
    ]
    preserved = merge_learning_states(base(), busy)["log"]
    assert any(entry["word"] == "apple" for entry in preserved)
    assert len(preserved) == 1201
    newer = base()
    newer["bandStats"] = {"2": {"a": 5, "b": 0}}
    newer["knowledge"] = {"apple": {"a": 6, "b": 0, "pos": 3000}}
    merged = merge_learning_states(rich, newer)
    assert merged["bandStats"]["2"]["a"] == 5
    assert merged["knowledge"]["apple"]["a"] == 6

    print("PASS 多设备状态合并：日志并集/计数保真/卡片新旧/游标/后验/重新定级/个性化 全部通过")


if __name__ == "__main__":
    main()
