#!/usr/bin/env python3
"""升降梯定级模拟：3 连对升级 vs 加权降级（3 题初判，必要时补 2 题）。

起点 4001~6000。比较准确率、波动和题数，避免一错就降造成震荡。
"""
import math
import random
import statistics

BANDS = [(1, 2000), (2001, 4000), (4001, 6000), (6001, 8000), (8001, 10000), (10001, 10987)]
GRID = [float(x) for x in range(0, 12001, 250)]


def update(post, rank, resp):
    out, s = [], 0.0
    for i, p in enumerate(post):
        pk = 0.25 + 0.75 * logistic((GRID[i] - rank) / 400)
        v = p * (resp * pk + (1 - resp) * (1 - pk))
        out.append(v)
        s += v
    return [v / s for v in out]


def post_mean(post):
    return sum(g * p for g, p in zip(GRID, post))


def logistic(x):
    return 1 / (1 + math.exp(-x))


def knows(level, rank, rng):
    p = 0.25 + 0.75 * logistic((level - rank) / 400)
    return rng.random() < p


def one(level, rule, seed):
    rng = random.Random(seed)
    post = [1 / len(GRID)] * len(GRID)

    def answer(rank):
        ok = knows(level, rank, rng)
        nonlocal post
        if rule in ("weightedBayes", "weighted5"):
            post = update(post, rank, int(ok))
        return ok

    idx = 2
    questions = 0
    final_score = 0
    while questions < 30:
        lo, hi = BANDS[idx]
        if rule == "immediate":
            streak = 0
            while questions < 30:
                rank = rng.randint(lo, hi)
                questions += 1
                ok = knows(level, rank, rng)
                if not ok:
                    final_score = 0
                    if idx == 0:
                        return 1, questions
                    idx -= 1
                    break
                streak += 1
                final_score = streak
                if streak >= 3:
                    if idx == len(BANDS) - 1:
                        return hi, questions
                    idx += 1
                    break
            continue
        # 加权：3 题初判；3 对升级，≤1 对降级，2 对补 2 题；5 题后 ≥4 升、≤2 降、其余为边界
        if rule == "weighted5":
            score = 0
            for _ in range(5):
                rank = rng.randint(lo, hi)
                questions += 1
                score += int(answer(rank))
            if score >= 4:
                if idx == len(BANDS) - 1:
                    return post_mean(post), questions
                idx += 1
                continue
            if score <= 2:
                if idx == 0:
                    return post_mean(post), questions
                idx -= 1
                continue
            return post_mean(post), questions
        # 加权：3 题初判；3 对升级，≤1 对降级，2 对补 2 题；5 题后 ≥4 升、≤2 降、其余为边界
        def finish(value):
            return (post_mean(post) if rule == "weightedBayes" else value), questions
        score = 0
        for _ in range(3):
            rank = rng.randint(lo, hi)
            questions += 1
            score += int(answer(rank))
        if score == 3:
            if idx == len(BANDS) - 1:
                return finish(hi)
            idx += 1
            continue
        if score <= 1:
            if idx == 0:
                return finish(1)
            idx -= 1
            continue
        for _ in range(2):
            rank = rng.randint(lo, hi)
            questions += 1
            score += int(answer(rank))
        final_score = score
        if score >= 4:
            if idx == len(BANDS) - 1:
                return finish(hi)
            idx += 1
            continue
        if score <= 2:
            if idx == 0:
                return finish(1)
            idx -= 1
            continue
        # 3/5 边界：在当前区间按得分估值
        return finish(lo + (hi - lo) * score // 5)
    return (post_mean(post) if rule == "weightedBayes" else BANDS[idx][0]), questions


def main():
    for level in (1000, 3000, 6000):
        print(f"\n真实水平 {level}")
        for rule in ("immediate", "weighted", "weightedBayes", "weighted5"):
            results = [one(level, rule, 20000 + i) for i in range(500)]
            est = [x[0] for x in results]
            qs = [x[1] for x in results]
            print(f"  {rule}: 中位数 {statistics.median(est):.0f} · MAE {statistics.mean(abs(x-level) for x in est):.0f} · 波动SD {statistics.pstdev(est):.0f} · 平均题数 {statistics.mean(qs):.1f}")


if __name__ == "__main__":
    main()
