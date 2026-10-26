#!/usr/bin/env python3
"""CAT 定级稳定性模拟：比较旧规则与稳定化规则的误差和波动。

旧规则：≥12 且 std<400 提前结束；连错 8 题直接 frontier=1；最终取当前均值。
新规则：≥20 且 std<250 提前结束；不归零；最终取最近 5 题均值的中位数。
用户模型：真实水平 true_level，P(会)=logistic((level-r)/400)，4选1含25%猜测。
"""
import math
import random
import statistics

GRID = [float(x) for x in range(0, 12001, 250)]


def logistic(x):
    return 1 / (1 + math.exp(-x))


def update(post, rank, resp):
    out, s = [], 0.0
    for i, p in enumerate(post):
        pk = 0.25 + 0.75 * logistic((GRID[i] - rank) / 400)
        v = p * (resp * pk + (1 - resp) * (1 - pk))
        out.append(v)
        s += v
    return [v / s for v in out]


def mean_std(post):
    m = sum(g * p for g, p in zip(GRID, post))
    sd = math.sqrt(sum((g - m) ** 2 * p for g, p in zip(GRID, post)))
    return m, sd


def one(true_level, rule, seed):
    rng = random.Random(seed)
    post = [1 / len(GRID)] * len(GRID)
    wrong_streak = 0
    means = []
    for q in range(1, 31):
        m, sd = mean_std(post)
        if rule == "old" and q >= 12 and sd < 400:
            return m, q
        if rule == "new" and q >= 20 and sd < 250:
            return statistics.median(means[-5:]), q
        if rule == "mid" and q >= 18 and sd < 275:
            return statistics.median(means[-5:]), q
        if rule == "old" and wrong_streak >= 8:
            return 1.0, q
        base = min(max(round(m), 1), 10987)
        rank = min(max(base + rng.randint(-150, 150), 1), 10987)
        p = 0.25 + 0.75 * logistic((true_level - rank) / 400)
        resp = 1.0 if rng.random() < p else 0.0
        post = update(post, rank, resp)
        means.append(mean_std(post)[0])
        wrong_streak = 0 if resp else wrong_streak + 1
    m, _ = mean_std(post)
    return (statistics.median(means[-5:]) if rule in ("mid", "new") else m), 30


def main():
    for level in (1000, 3000, 6000):
        print(f"\n真实水平 {level}")
        for rule in ("old", "mid", "new"):
            results = [one(level, rule, 10000 + i) for i in range(200)]
            estimates = [x[0] for x in results]
            qs = [x[1] for x in results]
            mae = statistics.mean(abs(x - level) for x in estimates)
            sd = statistics.pstdev(estimates)
            med = statistics.median(estimates)
            print(f"  {rule}: 中位数 {med:.0f} · MAE {mae:.0f} · 波动SD {sd:.0f} · 平均题数 {statistics.mean(qs):.1f}")


if __name__ == "__main__":
    main()
