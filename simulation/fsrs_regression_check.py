#!/usr/bin/env python3
"""FSRS 回归测试：新卡毕业 → 间隔增长 → 遗忘重学 → 重新毕业

用法：
  python simulation/fsrs_regression_check.py                    # 默认 http://127.0.0.1:8000
  python simulation/fsrs_regression_check.py http://175.27.210.206

2026-10-26 发现的真实事故：
- 客户端不传 last_review → 经过天数恒为 0，稳定度不增长
- 客户端不传 step → 服务端每张卡都重置到 Learning 第 0 步，永远毕不了业
本脚本覆盖这两个字段缺失会造成破坏的完整链路。
"""
import datetime
import json
import sys
import urllib.request

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8000").rstrip("/")


def post(path, body):
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def main():
    base = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)

    def iso(d):
        return d.isoformat().replace("+00:00", "Z")

    def review(card, rating, now, last_review):
        return post("/api/v1/fsrs/review", {
            "state": card["state"],
            "stability": card["stability"],
            "difficulty": card["difficulty"],
            "due": card["due"],
            "step": card.get("step"),
            "rating": rating,
            "now": iso(now),
            "last_review": iso(last_review),
        })

    first = post("/api/v1/fsrs/review", {"is_new": True, "rating": 3, "now": iso(base)})
    assert first["state"] == 1 and first["step"] == 1, first
    print("PASS 新卡 Good → Learning 第 1 步", first)

    graduated = review(first, 3, base + datetime.timedelta(minutes=15), base)
    assert graduated["state"] == 2 and graduated["step"] is None, graduated
    print("PASS 第二步 Good → 毕业进入 Review", graduated)

    later = review(
        graduated, 3,
        base + datetime.timedelta(days=3),
        base + datetime.timedelta(minutes=15),
    )
    assert later["state"] == 2, later
    assert later["stability"] > graduated["stability"], (graduated, later)
    print("PASS 3 天后 Good → 稳定度真实增长", later)

    forgotten = review(
        later, 1,
        base + datetime.timedelta(days=5),
        base + datetime.timedelta(days=3),
    )
    assert forgotten["state"] == 3 and forgotten["step"] == 0, forgotten
    print("PASS 忘记 → Relearning 第 0 步", forgotten)

    relearned = review(
        forgotten, 3,
        base + datetime.timedelta(days=5, minutes=20),
        base + datetime.timedelta(days=5),
    )
    assert relearned["state"] == 2 and relearned["step"] is None, relearned
    print("PASS 重学 Good → 重新毕业", relearned)
    print("\nFSRS 回归全部通过")


if __name__ == "__main__":
    main()
