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


def update(post, rank, resp, guess=0.25):
    out, s = [], 0.0
    for i, p in enumerate(post):
        pk = guess + (1 - guess) * logistic((GRID[i] - rank) / 400)
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
    if rule in ("strat", "stratBayes", "twoStage", "hybrid"):
        bands = [(1, 2000), (2001, 4000), (4001, 6000), (6001, 8000), (8001, 10000), (10001, 10987)]
        estimate = bands[0][0]
        post = [1 / len(GRID)] * len(GRID)
        if rule == "hybrid":
            means = []
            for lo, hi in bands:
                for _ in range(2):
                    rank = rng.randint(lo, hi)
                    p = 0.25 + 0.75 * logistic((true_level - rank) / 400)
                    resp = 1.0 if rng.random() < p else 0.0
                    post = update(post, rank, resp, 0.25)
                    means.append(mean_std(post)[0])
            for _ in range(18):
                m, _ = mean_std(post)
                base = min(max(round(m), 1), 10987)
                rank = min(max(base + rng.randint(-150, 150), 1), 10987)
                p = 0.25 + 0.75 * logistic((true_level - rank) / 400)
                resp = 1.0 if rng.random() < p else 0.0
                post = update(post, rank, resp, 0.25)
                means.append(mean_std(post)[0])
            return statistics.median(means[-5:]), 30
        if rule == "twoStage":
            scores = []
            for lo, hi in bands:
                score = 0
                for _ in range(3):
                    rank = rng.randint(lo, hi)
                    p = 0.25 + 0.75 * logistic((true_level - rank) / 400)
                    score += int(rng.random() < p)
                scores.append(score)
            candidate = next((i for i, sc in enumerate(scores) if sc < 2), len(bands) - 1)
            lo, hi = bands[candidate]
            final_score = scores[candidate]
            for _ in range(12):
                rank = rng.randint(lo, hi)
                p = 0.25 + 0.75 * logistic((true_level - rank) / 400)
                final_score += int(rng.random() < p)
            if final_score < 9:
                return lo, 30
            return min(hi, lo + (hi - lo) * final_score // 15), 30
        post = [1 / len(GRID)] * len(GRID)
        for lo, hi in bands:
            score = 0
            for _ in range(5):
                rank = rng.randint(lo, hi)
                p = 0.25 + 0.75 * logistic((true_level - rank) / 400)
                resp = 1.0 if rng.random() < p else 0.0
                score += int(resp)
                if rule == "stratBayes":
                    post = update(post, rank, resp, 0.25)
            if rule == "stratBayes":
                continue
            if score < 3:
                break
            estimate = min(hi, lo + (hi - lo) * (score - 1) // 5)
        if rule == "stratBayes":
            return mean_std(post)[0], 30
        return estimate, 30
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
        if rule in ("g35", "g40", "g50") and q >= 18 and sd < 275:
            return statistics.median(means[-5:]), q
        if rule == "mix" and q >= 18 and sd < 275:
            return statistics.median(means[-5:]), q
        if rule == "old" and wrong_streak >= 8:
            return 1.0, q
        base = min(max(round(m), 1), 10987)
        rank = min(max(base + rng.randint(-150, 150), 1), 10987)
        guess = 0.0 if (rule == "mix" and q % 3 == 0) else ({"g35": 0.35, "g40": 0.40, "g50": 0.50}.get(rule, 0.25))
        p = guess + (1 - guess) * logistic((true_level - rank) / 400)
        if rule == "mix" and q % 3 == 0:
            p *= 0.75   # 反向回想比再认更难，模拟真实记忆差异
        resp = 1.0 if rng.random() < p else 0.0
        post = update(post, rank, resp, guess)
        means.append(mean_std(post)[0])
        wrong_streak = 0 if resp else wrong_streak + 1
    m, _ = mean_std(post)
    return (statistics.median(means[-5:]) if rule in ("mid", "new", "mix", "g35", "g40", "g50") else m), 30


def main():
    for level in (1000, 3000, 6000):
        print(f"\n真实水平 {level}")
        for rule in ("old", "mid", "new", "mix", "g35", "g40", "g50", "strat", "stratBayes", "twoStage", "hybrid"):
            results = [one(level, rule, 10000 + i) for i in range(200)]
            estimates = [x[0] for x in results]
            qs = [x[1] for x in results]
            mae = statistics.mean(abs(x - level) for x in estimates)
            sd = statistics.pstdev(estimates)
            med = statistics.median(estimates)
            print(f"  {rule}: 中位数 {med:.0f} · MAE {mae:.0f} · 波动SD {sd:.0f} · 平均题数 {statistics.mean(qs):.1f}")


if __name__ == "__main__":
    main()
