# -*- coding: utf-8 -*-
"""目标 3000 词/年：每天 8 个新词时的每日负载模拟
阶梯：间隔 1/6/8/15 天 + 长期池 45 天循环，连续4次通过毕业，通过率 82%~92%
FSRS近似：间隔 1/3/7/16/45/120 天，保持率按设计 ≈90%，长期池连续3次通过毕业
"""
import sys, random
from pathlib import Path

sys.path.insert(0, str(Path(sys.executable).parent.parent.parent))
from daimon_runtime import setup_plot

import pandas as pd
import matplotlib.pyplot as plt

NEW_PER_DAY = 8

CONF = {
    "ladder": dict(intervals={1: 1, 2: 6, 3: 8, 4: 15, 5: 45},
                   pass_p={1: 0.82, 2: 0.85, 3: 0.88, 4: 0.90, 5: 0.92},
                   graduate_after=4, max_stage=5),
    "fsrs": dict(intervals={1: 1, 2: 3, 3: 7, 4: 16, 5: 45, 6: 120},
                 pass_p={1: 0.90, 2: 0.90, 3: 0.90, 4: 0.90, 5: 0.90, 6: 0.92},
                 graduate_after=3, max_stage=6),
}


def simulate(kind, days=365, seed=7):
    cfg = CONF[kind]
    rng = random.Random(seed)
    words = []  # [stage, due_day, consecutive_top_passes]
    rows = []
    for day in range(1, days + 1):
        reviews = 0
        for w in words:
            if w[0] == 0 or w[1] > day:
                continue
            reviews += 1
            if rng.random() < cfg["pass_p"][w[0]]:
                if w[0] == cfg["max_stage"]:
                    w[2] += 1
                    if w[2] >= cfg["graduate_after"]:
                        w[0], w[1] = 0, 10 ** 9
                    else:
                        w[1] = day + cfg["intervals"][w[0]]
                else:
                    w[0] += 1
                    w[1] = day + cfg["intervals"][w[0]]
                    if w[0] == cfg["max_stage"]:
                        w[2] = 0
            else:
                w[0] = max(1, w[0] - 1)
                w[1] = day + 1
                w[2] = 0
        for _ in range(NEW_PER_DAY):
            words.append([1, day + cfg["intervals"][1], 0])
        graduated = sum(1 for w in words if w[0] == 0)
        rows.append(dict(day=day, reviews=reviews, total=reviews + NEW_PER_DAY,
                         graduated=graduated, learned=len(words)))
    df = pd.DataFrame(rows)
    df["reviews_ma"] = df["reviews"].rolling(7, min_periods=1).mean()
    df["total_ma"] = df["total"].rolling(7, min_periods=1).mean()
    return df


dfL = simulate("ladder")
dfF = simulate("fsrs")

setup_plot()
fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(10, 7.6), height_ratios=[1.25, 1],
                               sharex=True)
fig.subplots_adjust(hspace=0.18)

ax1.plot(dfL["day"], dfL["total_ma"], color="#c0392b", lw=2,
         label="固定阶梯：复习+新词（7 天均值）")
ax1.plot(dfF["day"], dfF["total_ma"], color="#1f6fd6", lw=2,
         label="FSRS 近似：复习+新词（7 天均值）")
ax1.axhspan(50, 60, color="#2e8b57", alpha=0.10)
ax1.text(6, 61.5, "标准档日负载区间 50~60 词 ≈ 25~30 分钟", fontsize=9, color="#2e8b57")
ssL = dfL["total_ma"].iloc[-30:].mean()
ssF = dfF["total_ma"].iloc[-30:].mean()
ax1.annotate(f"稳态 ≈ {ssL:.0f} 词/天", xy=(365, ssL), xytext=(262, ssL + 9),
             fontsize=9.5, color="#c0392b",
             arrowprops=dict(arrowstyle="->", color="#c0392b", lw=1))
ax1.annotate(f"稳态 ≈ {ssF:.0f} 词/天", xy=(365, ssF), xytext=(262, ssF - 13),
             fontsize=9.5, color="#1f6fd6",
             arrowprops=dict(arrowstyle="->", color="#1f6fd6", lw=1))
ax1.set_xlim(1, 365)
ax1.set_ylim(bottom=0)
ax1.set_ylabel("每日总学习量（词）")
ax1.set_title(f"目标 3000 词/年：每天 {NEW_PER_DAY} 个新词时的日负载")
ax1.legend(loc="upper left", fontsize=9, frameon=True)

ax2.plot(dfL["day"], dfL["learned"], color="#c0392b", lw=1.6, label="固定阶梯 · 累计接触新词")
ax2.plot(dfF["day"], dfF["learned"], color="#1f6fd6", lw=1.6, label="FSRS 近似 · 累计接触新词")
ax2.plot(dfF["day"], dfF["graduated"], color="#1f6fd6", lw=2, ls="--",
         label="FSRS 近似 · 累计毕业词")
ax2.axhline(3000, color="#2e8b57", lw=1.2, ls=":")
ax2.text(6, 3060, "年度目标 3000 词", fontsize=9, color="#2e8b57")
ax2.set_xlim(1, 365)
ax2.set_ylim(bottom=0)
ax2.set_ylabel("累计词数")
ax2.set_xlabel("学习第几天")
ax2.legend(loc="upper left", fontsize=9, frameon=True)

fig.savefig("review_load_3000.png", dpi=220, bbox_inches="tight")

print(f"固定阶梯 @8新词/天: 稳态日总量 ≈ {ssL:.0f}（复习 {dfL['reviews_ma'].iloc[-30:].mean():.0f} + 新词 {NEW_PER_DAY}）")
print(f"  一年接触新词 {int(dfL['learned'].iloc[-1])}，毕业 {int(dfL['graduated'].iloc[-1])}")
print(f"FSRS近似 @8新词/天: 稳态日总量 ≈ {ssF:.0f}（复习 {dfF['reviews_ma'].iloc[-30:].mean():.0f} + 新词 {NEW_PER_DAY}）")
print(f"  一年接触新词 {int(dfF['learned'].iloc[-1])}，毕业 {int(dfF['graduated'].iloc[-1])}")
minsF = (dfF['reviews_ma'].iloc[-30:].mean() * 20 + NEW_PER_DAY * 70) / 60
minsL = (dfL['reviews_ma'].iloc[-30:].mean() * 20 + NEW_PER_DAY * 70) / 60
print(f"估算每日用时: 阶梯 ≈ {minsL:.0f} 分钟, FSRS ≈ {minsF:.0f} 分钟（复习20秒/词, 新词70秒/词含跟读）")
