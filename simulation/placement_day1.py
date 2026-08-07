# -*- coding: utf-8 -*-
"""Day-1 弹性定级模拟：探测不受每日 10 词限制，连续探测直到收敛（上限 48）
问题：是否所有水平的用户都能在第一天内收敛？各需要多少探测词？
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
CAP = 48
FUZZY_P = 0.08


def logistic(x):
    return 1.0 / (1.0 + np.exp(-x))


def p_know(r0, rank):
    return logistic((r0 - rank) / S)


def run_user(r0_true, seed):
    rng = np.random.default_rng(seed)
    post = np.ones_like(GRID)
    post /= post.sum()
    ranks = [int(b + rng.integers(-100, 101)) for b in COARSE_BANDS for _ in range(2)]
    count = 0
    while count < CAP:
        while count < len(ranks) and count < CAP:
            rank = ranks[count]
            pk = p_know(r0_true, rank)
            resp = 0.5 if rng.random() < FUZZY_P else (1.0 if rng.random() < pk else 0.0)
            like = resp * p_know(GRID, rank) + (1.0 - resp) * (1.0 - p_know(GRID, rank))
            post *= like
            post /= post.sum()
            count += 1
            mean = float((GRID * post).sum())
            std = float(np.sqrt(((GRID - mean) ** 2 * post).sum()))
            if std < 500 and count >= 12:
                return count, mean, mean - r0_true, True
        mean = float((GRID * post).sum())
        ranks.append(int(np.clip(rng.normal(mean, 350), 250, 12000)))
    mean = float((GRID * post).sum())
    return count, mean, mean - r0_true, False


TRUE_LEVELS = [500, 2000, 4000, 7000]
SEEDS = list(range(10))
data = {}
print("真实水平 | 收敛探测数(10次) | 最大 | 平均 | 误差范围")
for r0 in TRUE_LEVELS:
    runs = [run_user(r0, s) for s in SEEDS]
    counts = [r[0] for r in runs]
    errs = [r[2] for r in runs]
    allconv = all(r[3] for r in runs)
    data[r0] = (counts, errs)
    print(f"{r0:>6}  |  {sorted(counts)}  |  {max(counts)}  |  {np.mean(counts):.1f}  |  "
          f"{min(errs):+.0f} ~ {max(errs):+.0f}  |  全部收敛: {allconv}")

setup_plot()
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(10, 4.6))
fig.subplots_adjust(wspace=0.25)
labels = [str(r0) for r0 in TRUE_LEVELS]
counts_data = [data[r0][0] for r0 in TRUE_LEVELS]
errs_data = [data[r0][1] for r0 in TRUE_LEVELS]

bp1 = ax1.boxplot(counts_data, tick_labels=labels, widths=0.5, patch_artist=True)
for b in bp1["boxes"]:
    b.set_facecolor("#dce9f7")
    b.set_edgecolor("#1f6fd6")
ax1.axhline(40, color="#c0392b", lw=1.2, ls="--")
ax1.text(0.6, 41, "建议 Day-1 探测上限 40", fontsize=9, color="#c0392b")
ax1.set_xlabel("用户真实词汇水平（词）")
ax1.set_ylabel("收敛所需探测词数")
ax1.set_title("Day-1 连续探测：多少次收敛？")
ax1.set_ylim(0, 50)

for i, errs in enumerate(errs_data, start=1):
    ax2.scatter([i] * len(errs), errs, color="#1f6fd6", alpha=0.7, s=28, zorder=3)
ax2.axhline(0, color="#555555", lw=1)
ax2.axhspan(-500, 500, color="#2e8b57", alpha=0.12)
ax2.text(0.55, 540, "±500（一个词频带）", fontsize=9, color="#2e8b57")
ax2.set_xticks(range(1, 5))
ax2.set_xticklabels(labels)
ax2.set_xlabel("用户真实词汇水平（词）")
ax2.set_ylabel("定级误差（估计 − 真实，词）")
ax2.set_title("收敛时刻的定级误差")
fig.savefig("placement_day1.png", dpi=220, bbox_inches="tight")
print("\n图表已保存: placement_day1.png")
