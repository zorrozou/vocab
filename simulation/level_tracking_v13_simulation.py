#!/usr/bin/env python3
"""v1.3 自适应水平追踪模拟：验证"长期探测真实水平"能力

场景：
  A 高估：定级把用户估到 6000，真实水平 4000 → 估值应降下来
  B 低估：定级估到 3000，真实水平 5000 → 估值应升上去
  C 准确+成长：起点 4000=真实 4000，每天真实水平 +5 词（学习效果）→ 估值应跟随上爬

对照：
  v1.2 旧规则（无扩散、无主动探测、复习权重 0.2/0.3 双向都计）
  v1.3 新规则（每日扩散 σ100、每日 3 探测全额证据、权重修正+每日被动权重封顶 1.5）

用户模型：P(认识排位 r 的词) = logistic((trueLevel - r) / 400)（与系统似然同型）
"""
import math
import random

GRID = [float(x) for x in range(0, 12001, 250)]


def logistic(x):
    return 1 / (1 + math.exp(-x))


def mean_std(post):
    m = sum(g * p for g, p in zip(GRID, post))
    s = math.sqrt(sum((g - m) ** 2 * p for g, p in zip(GRID, post)))
    return m, s


def update(post, rank, resp, weight):
    out, s = [], 0.0
    for i, p in enumerate(post):
        pk = logistic((GRID[i] - rank) / 400)
        like = (resp * pk + (1 - resp) * (1 - pk)) ** weight
        v = p * like
        out.append(v)
        s += v
    return [v / s for v in out]


def diffuse(post):
    m, s = mean_std(post)
    if s >= 400:
        return post
    k = math.exp(-(250 ** 2) / (2 * 100 ** 2))
    n = len(post)
    out = [post[i] + k * ((post[i - 1] if i > 0 else 0) + (post[i + 1] if i < n - 1 else 0)) for i in range(n)]
    z = sum(out)
    return [v / z for v in out]


def knows(true_level, rank, rng):
    return 1.0 if rng.random() < logistic((true_level - rank) / 400) else 0.0


def simulate(days, true0, start_mean, growth, version, seed=7):
    rng = random.Random(seed)
    # 定级收敛后的初始后验：以 start_mean 为均值、std≈300 的高斯（直接构造）
    raw = [math.exp(-((g - start_mean) ** 2) / (2 * 300 ** 2)) for g in GRID]
    z = sum(raw)
    post = [v / z for v in raw]
    pointer = int(start_mean)
    hist = []
    for day in range(days):
        true_level = true0 + growth * day
        m, sd = mean_std(post)
        if version == "v1.3":
            post = diffuse(post)
            m, sd = mean_std(post)
            # 主动探测：2 上 1 下，全额证据
            for lo, hi in [(m + 0.5 * sd, m + sd), (m + 1.5 * sd, m + 2 * sd), (m - sd, m - 0.5 * sd)]:
                rank = max(1, min(10991, rng.uniform(lo, hi)))
                post = update(post, rank, knows(true_level, rank, rng), 1.0)
        # 新词 10 个（在 pointer 处）：不熟悉 w1.0↓ / 学会了 w0.5↑
        for i in range(10):
            rank = pointer + i
            resp = knows(true_level, rank, rng)
            post = update(post, rank, resp, 1.0 if resp == 0 else 0.5)
        pointer += 10
        # 复习 30 个（排位在 pointer-1500 ~ pointer 间，即学过的词）
        day_w = 0.0
        for _ in range(30):
            rank = max(1, pointer - rng.uniform(50, 1500))
            resp = knows(true_level, rank, rng)
            if version == "v1.3":
                if resp == 0:
                    w = 0.4 if rng.random() < 0.3 else 0.2   # 部分成熟卡
                    if day_w + w <= 1.5:
                        post = update(post, rank, 0, w); day_w += w
                else:
                    m_now, _ = mean_std(post)
                    if rank > m_now and day_w + 0.15 <= 1.5:
                        post = update(post, rank, 1, 0.15); day_w += 0.15
            else:
                post = update(post, rank, resp, 0.2 if resp == 0 else 0.3)
        # 跳位规则（双版本一致）
        m, sd = mean_std(post)
        if m - pointer > 500 and sd < 800:
            pointer = int(m)
        hist.append((day + 1, m, sd, true_level))
    return hist


def show(title, hist):
    print(f"\n== {title} ==")
    for d, m, sd, tl in hist:
        if d == 1 or d % 10 == 0:
            print(f"  第{d:>3}天  估值 {m:7.0f} (±{sd:3.0f})   真实 {tl:6.0f}   偏差 {m - tl:+7.0f}")


if __name__ == "__main__":
    for name, t0, start, growth in [
        ("A 高估 6000→真实4000", 4000, 6000, 0),
        ("B 低估 3000→真实5000", 5000, 3000, 0),
        ("C 准确4000+每天成长5词", 4000, 4000, 5),
    ]:
        for ver in ("v1.2", "v1.3"):
            h = simulate(60, t0, start, growth, ver)
            show(f"{name} · {ver}", h)
