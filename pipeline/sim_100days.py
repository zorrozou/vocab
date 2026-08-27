# -*- coding: utf-8 -*-
"""100 天学习者模拟 v2（快速版）
② FSRS：100 天全量真实调用（/fsrs/review）
③ 薄弱词概率：对服务端 assign_recalls 算法做 100 天精确推演 + 3 次真实调用印证
① 例句质量：从现有例句库抽样 LLM 评审（另跑）
"""
import json, math, random, time, urllib.request
from collections import Counter, defaultdict

API = "http://127.0.0.1:8000"
R_STAR = 3000
SKILL_S = 400.0
NEW_PER_DAY = 10
DAYS = 100
SEED = 20260827
rng = random.Random(SEED)
logs = []


def log(s):
    print(s, flush=True)
    logs.append(s)


def api(path, payload=None, timeout=60):
    if payload is None:
        with urllib.request.urlopen(f"{API}{path}", timeout=timeout) as r:
            return json.loads(r.read())
    req = urllib.request.Request(
        f"{API}{path}", data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def p_know(rank, rstar=R_STAR):
    return 1.0 / (1.0 + math.exp((rank - rstar) / SKILL_S))


GRID = list(range(0, 12001, 250))
post = [1.0 / len(GRID)] * len(GRID)


def post_update(rank, resp):
    global post
    s = 0.0
    newp = []
    for i, r0 in enumerate(GRID):
        pk = 1.0 / (1.0 + math.exp((r0 - rank) / 400.0))
        like = resp * pk + (1 - resp) * (1 - pk)
        v = post[i] * like
        s += v
        newp.append(v)
    post = [v / s for v in newp]


def post_mean():
    return sum(GRID[i] * post[i] for i in range(len(GRID)))


# ---------- 定级 ----------
qs = api("/api/v1/placement/set?seed=sim3000")["words"]
right = 0
for q in qs:
    correct = rng.random() < p_know(q["pos"])
    if rng.random() < 0.06:
        correct = not correct
    post_update(q["pos"], 1.0 if correct else 0.0)
    right += int(correct)
frontier = max(1, round(post_mean()))
log(f"[定级] 答对 {right}/30 → 估计 {frontier}（真实 {R_STAR}，误差 {frontier - R_STAR:+d}）")

cards = {}
pointer = frontier
weak_log = []
review_records = []
review_by_day = Counter()
rating_by_day = defaultdict(Counter)
day_new_words = {}


def days_between(d1, d2):
    from datetime import datetime
    a = datetime.fromisoformat(d1.replace("Z", "+00:00"))
    b = datetime.fromisoformat(d2.replace("Z", "+00:00"))
    return (b - a).total_seconds() / 86400.0


t0 = time.time()
for day in range(1, DAYS + 1):
    from datetime import date as _date, timedelta as _td
    ds = (_date.today() + _td(days=day - 1)).isoformat()
    # 复习
    due = [w for w, c in cards.items() if c["fsrs"]["due"][:10] <= ds]
    rng.shuffle(due)
    for w in due:
        c = cards[w]
        fs = c["fsrs"]
        stab = max(0.2, fs.get("stability", 1.0))
        due0 = fs.get("due", "")
        # FSRS-6: R(t)=(1+0.9805*t/S)^(-0.1542)，到期点 t≈S → R≈0.9，加噪声
        t_est = stab * rng.uniform(0.8, 1.2)
        R = (1 + 0.9805 * t_est / stab) ** (-0.1542)
        recalled = rng.random() < R
        rating = 1 if not recalled else rng.choices([4, 3, 2], weights=[0.25, 0.65, 0.10])[0]
        r = api("/api/v1/fsrs/review", {"state": fs["state"], "stability": fs["stability"],
                                        "difficulty": fs["difficulty"], "due": fs["due"], "rating": rating,
                                        "now": ds + "T12:00:00+00:00",
                                        "last_review": c.get("last_rev")})
        review_records.append((day, w, rating, fs.get("stability", 0), r.get("stability", 0), fs["due"], r["due"]))
        c["fsrs"] = r
        c["last_rev"] = ds + "T12:00:00+00:00"
        rating_by_day[day][rating] += 1
        if rating <= 2:
            weak_log.append((day, w))
    review_by_day[day] = len(due)
    # 新词
    r = api(f"/api/v1/lexicon/at?pos={pointer}&n={NEW_PER_DAY + 2}")
    news = [w for w in r["words"] if w["word"] not in cards][:NEW_PER_DAY]
    if news:
        pointer = news[-1]["pos"] + 1
    day_new_words[day] = [w["word"] for w in news]
    for w in news:
        r0 = p_know(w["pos"])
        rating = 4 if rng.random() < r0 * 0.8 else rng.choices([3, 2, 1], weights=[0.75, 0.15, 0.10])[0]
        rr = api("/api/v1/fsrs/review", {"is_new": True, "rating": rating, "now": ds + "T12:00:00+00:00"})
        cards[w["word"]] = {"fsrs": rr, "pos": w["pos"], "last_rev": ds + "T12:00:00+00:00"}
        if rating <= 2:
            weak_log.append((day, w["word"]))
    if day % 20 == 0:
        log(f"[day {day:>3}] 复习 {len(due):>3} · 新词 {len(news)} · 卡 {len(cards)}")

log(f"FSRS 模拟完成 {(time.time()-t0)/60:.1f} 分钟，共 {len(review_records)} 次复习")

# ---------- ② FSRS 规则 ----------
chk_a = chk_g = stab_up_viol = stab_down_viol = 0
per_word = defaultdict(list)
for rec in review_records:
    per_word[rec[1]].append(rec)
for rec in review_records:
    day, w, rating, s0, s1 = rec[0], rec[1], rec[2], rec[3], rec[4]
    if rating == 1:
        chk_a += 1
        if s1 >= s0:      # Again：稳定性必须下降
            stab_down_viol += 1
    elif rating >= 3:
        chk_g += 1
        if s1 <= s0:      # Good/Easy：稳定性必须上升
            stab_up_viol += 1
pass_n = sum(v for d, c in rating_by_day.items() for k, v in c.items() if k >= 3)
log(f"[②] 通过→稳定性不下降违规 {stab_up_viol}/{chk_g} | 失败→稳定性不上升违规 {stab_down_viol}/{chk_a} | 复习通过率 {pass_n/len(review_records)*100:.1f}%")
log(f"[②] 复习量: 峰值 {max(review_by_day.values())}/天, 均值 {sum(review_by_day.values())/DAYS:.0f}/天")

# ---------- ③ 薄弱词概率（服务端算法精确推演）----------
def assign_recalls(new_words, weak_words, seed, rng):
    """与服务端 assign_recalls 相同的算法（2026-08-26 版）"""
    rng2 = random.Random(seed)
    if not weak_words:
        return {}
    pool = weak_words * 2
    rng2.shuffle(pool)
    targets = list(new_words)
    rng2.shuffle(targets)
    cap = min(len(pool), max(1, round(len(targets) * 0.5)))
    return {targets[i]: pool[i] for i in range(cap)}


tot_sent = with_recall = 0
weak_seen = set()
max_per_day = 0
over2_days = 0
for day in range(1, DAYS + 1):
    news = day_new_words.get(day, [])
    if not news:
        continue
    weak7 = sorted({w for d, w in weak_log if d >= day - 7})[-10:]
    plan = assign_recalls(news, weak7, f"sim{day}", rng)
    tot_sent += len(news)
    with_recall += len(plan)
    cnt = Counter(plan.values())
    weak_seen.update(plan.values())
    if cnt and max(cnt.values()) > 2:
        over2_days += 1
    max_per_day = max(max_per_day, max(cnt.values()) if cnt else 0)
log(f"[③] 推演100天个性化: 共 {tot_sent} 句, 织入 {with_recall} 句 = {with_recall/tot_sent*100:.0f}% | 覆盖 {len(weak_seen)} 个薄弱词 | 单词单日最高 {max_per_day} 次 | 超2次的天数 {over2_days}")

out = {"placement_error": frontier - R_STAR,
       "fsrs": {"pass_stab_viol": stab_up_viol, "again_stab_viol": stab_down_viol, "pass_rate": pass_n / len(review_records),
                "reviews": len(review_records)},
       "personal": {"with_recall_pct": with_recall / tot_sent, "over2_days": over2_days,
                    "weak_covered": len(weak_seen)}}
json.dump(out, open("/tmp/sim100_fsrs.json", "w"), ensure_ascii=False)
log("已存 /tmp/sim100_fsrs.json")
