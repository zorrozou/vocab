# -*- coding: utf-8 -*-
"""艾宾浩斯背单词：一年期每日负载模拟
场景 A：固定阶梯（D1/D7/D15/D30 + 长期池45天循环），每天固定10新词，无上限无毕业
场景 B：阶梯 + 30词/天上限（复习优先、新词节流）+ 长期池连续4次通过后毕业
场景 C：同 B，但各阶段通过率降低10个百分点（敏感性与压力测试）
"""
import sys, random
from pathlib import Path

sys.path.insert(0, str(Path(sys.executable).parent.parent.parent))
from daimon_runtime import setup_plot

import pandas as pd
import seaborn as sns
import matplotlib.pyplot as plt

STAGE_INTERVAL = {1: 1, 2: 6, 3: 8, 4: 15, 5: 45}   # 通过该阶段后距下次复习的天数
GRADUATE_AFTER = 4                                   # 长期池连续通过次数 -> 毕业
BASE_P = {1: 0.82, 2: 0.85, 3: 0.88, 4: 0.90, 5: 0.92}
HARD_P = {k: v - 0.10 for k, v in BASE_P.items()}


def simulate(days=365, cap=None, graduate=False, pass_p=None, seed=7):
    rng = random.Random(seed)
    words = []  # [stage, due_day, consecutive_longterm_passes]
    rows = []
    for day in range(1, days + 1):
        due = [i for i, w in enumerate(words) if w[0] != 6 and w[1] <= day]
        if cap is None:
            to_review, backlog = due, 0
        else:
            to_review, backlog = due[:cap], max(0, len(due) - cap)
        for i in to_review:
            w = words[i]
            if rng.random() < pass_p[w[0]]:
                if w[0] == 5:
                    w[2] += 1
                    if graduate and w[2] >= GRADUATE_AFTER:
                        w[0], w[1] = 6, 10 ** 9
                    else:
                        w[1] = day + STAGE_INTERVAL[5]
                else:
                    w[0] += 1
                    w[1] = day + (STAGE_INTERVAL[5] if w[0] == 5 else STAGE_INTERVAL[w[0]])
                    if w[0] == 5:
                        w[2] = 0
            else:
                w[0] = max(1, w[0] - 1)   # 降一级
                w[1] = day + 1
                w[2] = 0
        reviews = len(to_review)
        new_today = 10 if cap is None else min(10, max(0, cap - reviews))
        for _ in range(new_today):
            words.append([1, day + STAGE_INTERVAL[1], 0])
        graduated = sum(1 for w in words if w[0] == 6)
        rows.append(dict(day=day, reviews=reviews, new=new_today,
                         backlog=backlog, graduated=graduated, learned=len(words)))
    return pd.DataFrame(rows)


dfA = simulate(cap=None, graduate=False, pass_p=BASE_P)
dfB = simulate(cap=30, graduate=True, pass_p=BASE_P)
dfC = simulate(cap=30, graduate=True, pass_p=HARD_P)

for df in (dfA, dfB, dfC):
    df["reviews_ma"] = df["reviews"].rolling(7, min_periods=1).mean()
    df["new_ma"] = df["new"].rolling(7, min_periods=1).mean()

setup_plot()
fig = plt.figure(figsize=(10, 8.6))
gs = fig.add_gridspec(2, 2, height_ratios=[1.15, 1], hspace=0.32, wspace=0.22)

ax1 = fig.add_subplot(gs[0, :])
ax1.plot(dfA["day"], dfA["reviews_ma"], color="#c0392b", lw=2,
         label="A · 无上限无毕业：每天固定 10 新词")
ax1.plot(dfB["day"], dfB["reviews_ma"], color="#1f6fd6", lw=2,
         label="B · 30 词上限 + 复习优先 + 毕业机制")
ax1.plot(dfC["day"], dfC["reviews_ma"], color="#d9941a", lw=1.6, ls="--",
         label="C · 同 B，通过率 -10%（压力测试）")
ax1.axhline(30, color="#555555", lw=1, ls=":", alpha=0.8)
ax1.text(3, 31.2, "30 词/天上限", fontsize=9, color="#555555")
cross = dfA.loc[dfA["reviews_ma"] > 30, "day"].min()
ax1.annotate(f"A 第 {int(cross)} 天触顶", xy=(cross, 30), xytext=(cross + 18, 44),
             fontsize=9, color="#c0392b",
             arrowprops=dict(arrowstyle="->", color="#c0392b", lw=1))
ax1.set_xlim(1, 365)
ax1.set_ylabel("每日复习词数（7 天均值）")
ax1.set_xlabel("学习第几天")
ax1.set_title("一年期复习负载模拟：30 词上限规则是否成立")
ax1.legend(loc="upper left", fontsize=9, frameon=True)

ax2 = fig.add_subplot(gs[1, 0])
ax2.fill_between(dfB["day"], dfB["new_ma"], color="#1f6fd6", alpha=0.35, lw=0)
ax2.plot(dfB["day"], dfB["new_ma"], color="#1f6fd6", lw=1.6, label="B 每日新词")
ax2.plot(dfC["day"], dfC["new_ma"], color="#d9941a", lw=1.2, ls="--", label="C 每日新词")
ax2.axhline(10, color="#555555", lw=1, ls=":", alpha=0.7)
ax2.set_xlim(1, 365)
ax2.set_ylim(0, 10.8)
ax2.set_ylabel("每日新学词数（7 天均值）")
ax2.set_xlabel("学习第几天")
ax2.set_title("新词节流：复习优先时新词自动让位")
ax2.legend(fontsize=9, frameon=True)

ax3 = fig.add_subplot(gs[1, 1])
ax3.plot(dfB["day"], dfB["backlog"], color="#1f6fd6", lw=1.6, label="B 积压（到期未复习）")
ax3.plot(dfC["day"], dfC["backlog"], color="#d9941a", lw=1.2, ls="--", label="C 积压")
ax3b = ax3.twinx()
ax3b.plot(dfB["day"], dfB["graduated"], color="#2e8b57", lw=1.8, label="B 累计毕业词")
ax3b.set_ylabel("累计毕业词数", color="#2e8b57")
ax3b.tick_params(axis="y", labelcolor="#2e8b57")
ax3.set_xlim(1, 365)
ax3.set_ylim(bottom=0)
ax3b.set_ylim(bottom=0)
ax3.set_ylabel("当日积压词数")
ax3.set_xlabel("学习第几天")
ax3.set_title("积压与毕业：队列是否自我消化")
h1, l1 = ax3.get_legend_handles_labels()
h2, l2 = ax3b.get_legend_handles_labels()
ax3.legend(h1 + h2, l1 + l2, fontsize=9, frameon=True, loc="upper left")

fig.savefig("review_load_simulation.png", dpi=220, bbox_inches="tight")

print("=== 场景 A（无上限无毕业）===")
print(f"7天均值复习量首次>30: 第 {int(cross)} 天")
print(f"第365天复习量(7天均值): {dfA['reviews_ma'].iloc[-1]:.0f} 词/天")
print(f"一年累计学词: {int(dfA['learned'].iloc[-1])}")
print()
print("=== 场景 B（30上限+复习优先+毕业）===")
print(f"新词为0的天数: {int((dfB['new'] == 0).sum())} / 365")
print(f"日均新词: {dfB['new'].mean():.1f}")
print(f"一年累计学词: {int(dfB['learned'].iloc[-1])}（其中毕业 {int(dfB['graduated'].iloc[-1])}）")
print(f"最大单日积压: {int(dfB['backlog'].max())} 词；年末积压: {int(dfB['backlog'].iloc[-1])}")
print(f"第365天复习量(7天均值): {dfB['reviews_ma'].iloc[-1]:.0f} 词/天")
print()
print("=== 场景 C（同B，通过率-10%）===")
print(f"新词为0的天数: {int((dfC['new'] == 0).sum())} / 365")
print(f"日均新词: {dfC['new'].mean():.1f}")
print(f"一年累计学词: {int(dfC['learned'].iloc[-1])}（其中毕业 {int(dfC['graduated'].iloc[-1])}）")
print(f"最大单日积压: {int(dfC['backlog'].max())} 词；年末积压: {int(dfC['backlog'].iloc[-1])}")
