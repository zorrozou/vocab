# -*- coding: utf-8 -*-
"""自适应定级模拟：四种真实水平用户，验证网格贝叶斯定级器的收敛速度与误差
协议（对应 PRD §3.10）：
- Day 1 粗扫：500/1000/1500/2000/2500/3000 六个词频带各 2 个探测词
- Day 2+ 收窄：围绕后验均值 ±350 的高不确定区加密探测，每天 12 个
- 反馈：认识=1 / 不认识=0 / 8% 概率模糊=0.5；用户覆盖曲线 logistic(S=400)
- 收敛：后验标准差 < 500 或累计 40 个探测
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(sys.executable).parent.parent.parent))
from daimon_runtime import setup_plot
import matplotlib.pyplot as plt

GRID = np.arange(0, 12001, 250, dtype=float)
S = 400.0
COARSE_BANDS = [500, 1000, 1500, 2000, 2500, 3000]
PROBES_PER_DAY = 12
MAX_DAYS = 6
FUZZY_P = 0.08


def logistic(x):
    return 1.0 / (1.0 + np.exp(-x))


def p_know(r0, rank):
    return logistic((r0 - rank) / S)


def run_user(r0_true, seed):
    rng = np.random.default_rng(seed)
    post = np.ones_like(GRID)
    post /= post.sum()
    history = []          # (probe_count, day, mean, std)
    count, day, converged = 0, 0, False
    while not converged and day < MAX_DAYS:
        day += 1
        if day == 1:
            ranks = [int(b + rng.integers(-100, 101)) for b in COARSE_BANDS for _ in range(2)]
        else:
            mean = float((GRID * post).sum())
            ranks = [int(np.clip(rng.normal(mean, 350), 250, 12000)) for _ in range(PROBES_PER_DAY)]
        for rank in ranks:
            pk = p_know(r0_true, rank)
            resp = 0.5 if rng.random() < FUZZY_P else (1.0 if rng.random() < pk else 0.0)
            like = resp * p_know(GRID, rank) + (1.0 - resp) * (1.0 - p_know(GRID, rank))
            post *= like
            post /= post.sum()
            count += 1
            mean = float((GRID * post).sum())
            std = float(np.sqrt(((GRID - mean) ** 2 * post).sum()))
            history.append((count, day, mean, std))
            if std < 500 or count >= 40:
                converged = True
                break
    return history, day, converged


TRUE_LEVELS = [500, 2000, 4000, 7000]
SEEDS = [1, 7, 42]
results = {}
print("真实水平 | 收敛天数(3次) | 收敛时探测数 | 最终估计 | 误差")
for r0 in TRUE_LEVELS:
    runs = [run_user(r0, s) for s in SEEDS]
    results[r0] = runs
    days = [r[1] for r in runs]
    finals = [r[0][-1] for r in runs]
    ests = [f[2] for f in finals]
    errs = [e - r0 for e in ests]
    print(f"{r0:>6}  |  {days}  |  {[f[0] for f in finals]}  |  {[round(e) for e in ests]}  |  {[round(e) for e in errs]}")

setup_plot()
fig, axes = plt.subplots(2, 2, figsize=(10, 7.4), sharex=True)
fig.subplots_adjust(hspace=0.34, wspace=0.2)
for ax, r0 in zip(axes.flat, TRUE_LEVELS):
    runs = results[r0]
    for i, (hist, day, conv) in enumerate(runs):
        c = [h[0] for h in hist]
        m = [h[2] for h in hist]
        s = [h[3] for h in hist]
        ax.plot(c, m, lw=1.8, label=f"第 {i+1} 次模拟" if r0 == TRUE_LEVELS[0] else None)
        ax.fill_between(c, np.array(m) - np.array(s), np.array(m) + np.array(s), alpha=0.18)
    ax.axhline(r0, color="#c0392b", lw=1.2, ls="--")
    ax.text(2, r0 + 220, f"真实水平 {r0}", fontsize=9, color="#c0392b")
    ax.set_ylim(max(0, r0 - 2600), min(12000, r0 + 2600))
    ax.set_xlim(0, 48)
    ax.set_xlabel("累计探测词数")
    ax.set_ylabel("估计的词汇边界 R*")
axes.flat[0].legend(fontsize=9, frameon=True, loc="lower right")
fig.suptitle("自适应定级收敛模拟：后验均值 ±1σ（每天 12 个探测词）", fontsize=13)
fig.savefig("placement_simulation.png", dpi=220, bbox_inches="tight")
print("\n图表已保存: placement_simulation.png")
