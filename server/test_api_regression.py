#!/usr/bin/env python3
"""全 API 回归：认证、词库、测验、例句、TTS、账号隔离与重测合并。

运行：python3 server/test_api_regression.py [BASE]
默认 BASE=http://127.0.0.1:8000。会创建随机测试账号，不接触真实用户数据。
"""
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8000").rstrip("/")
PASS = []


def req(path, body=None, method=None, token=None, timeout=90):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    r = urllib.request.Request(BASE + path, data=data, method=method, headers=headers)
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        raw = resp.read()
        return json.loads(raw) if raw else {}


def ok(name, detail=""):
    PASS.append(name)
    print("PASS", name, detail, flush=True)


def state(word, pos, count):
    return {
        "calibrated": True, "frontier": pos, "pointer": pos + 1,
        "probeCount": count, "posterior": [0.2, 0.8],
        "log": [{"d": "2026-10-26", "word": word, "rating": 3, "kind": "learn"}],
        "cards": {word: {"fsrs": {"state": 2, "stability": 5}}},
        "pendingNew": [], "personalized": {}, "settings": {"newPerDay": 10},
    }


def main():
    assert req("/api/v1/health").get("ok") is True
    ok("health")

    ts = int(time.time())
    tokens = []
    for tag, word, pos in (("a", "apple", 3000), ("b", "banana", 5000)):
        username = f"reg_{tag}_{ts}"
        auth = req("/api/v1/auth/register", {
            "username": username, "password": "regression_pass_123", "nickname": "回归"})
        token = auth["token"]
        tokens.append(token)
        try:
            req("/api/v1/auth/login", {"username": username, "password": "wrong_password"})
            raise AssertionError("错误密码竟然登录成功")
        except urllib.error.HTTPError as e:
            assert e.code == 401
        assert req("/api/v1/auth/login", {
            "username": username, "password": "regression_pass_123"})["token"]
        req("/api/v1/me/state", state(word, pos, 100), "PUT", token)
        got = req("/api/v1/me/state", token=token)["state"]
        assert set(got["cards"]) == {word}
        assert got["pointer"] == pos + 1
    ok("注册/登录/错误密码/账号隔离")

    # 同一账号重测：清空后验 → 新结果，不被旧 probeCount 撤销
    token = tokens[0]
    reset = state("apple", 3000, 1000)
    reset["placementResetAt"] = 200.0
    reset["posterior"] = None
    reset["probeCount"] = 0
    req("/api/v1/me/state", reset, "PUT", token)
    result = state("apple", 3000, 12)
    result["placementResetAt"] = 200.0
    result["posterior"] = [0.0, 1.0]
    result["frontier"] = 4200
    result["pointer"] = 4201
    req("/api/v1/me/state", result, "PUT", token)
    got = req("/api/v1/me/state", token=token)["state"]
    assert got["posterior"] == [0.0, 1.0] and got["probeCount"] == 12 and got["frontier"] == 4200
    ok("重新定级不被合并撤销")

    s1 = req("/api/v1/placement/set?seed=regression-a")["words"]
    s2 = req("/api/v1/placement/set?seed=regression-b")["words"]
    assert len(s1) == 30 and len(s2) == 30
    assert [w["word"] for w in s1] != [w["word"] for w in s2]
    pos = s1[0]["pos"]
    qf = req(f"/api/v1/quiz?pos={pos}&seed=42&mode=forward")
    assert len(qf["options"]) == 4 and sum(bool(o["ok"]) for o in qf["options"]) == 1
    qr = req(f"/api/v1/quiz?pos={pos}&seed=42&mode=reverse")
    assert qr["mode"] == "reverse" and qr.get("prompt") and len(qr["options"]) == 4
    ok("定级随机题/正反向测验")

    words = req("/api/v1/lexicon/at?pos=3000&n=10")["words"]
    assert len(words) >= 8 and all(w.get("senses") for w in words)
    ok("词库词条与义项")

    trio = req("/api/v1/sentence/trio?word=assert&weak=apple&cap=5000", timeout=240)
    assert len(trio["sentences"]) == 3 and trio.get("err") is None
    assert all(s.get("zh") for s in trio["sentences"])
    ok("三档例句与翻译")

    ensured = req("/api/v1/sentence/ensure?word=apple", timeout=180)
    assert ensured.get("text")
    ok("缺句补齐")

    weaved = req("/api/v1/sentence/weave?word=assert&weak=apple&cap=5000&device=regression", timeout=240)
    assert "text" in weaved
    ok("巩固句端点可用", f"len={len(weaved.get('text') or '')}")

    # 个性化同步生成（真实 LLM，可能耗时；检查最终能取到且字段完整）
    device = f"regression-{ts}"
    req("/api/v1/personalize", {
        "device": device, "date": "2026-10-26", "new_words": [],
        "weak_words": ["apple"], "learned_max_pos": 5000,
        "sync": True, "replace": True}, timeout=240)
    rows = []
    for _ in range(18):
        rows = req(f"/api/v1/personalized?device={device}&date=2026-10-26", timeout=240)["sentences"]
        if rows:
            break
        time.sleep(5)
    assert rows and all(r.get("text") and r.get("zh") for r in rows)
    ok("个性化例句生成与中文翻译")

    text = urllib.parse.quote("Regression checks keep the learning app reliable.")
    audio = urllib.request.urlopen(BASE + f"/api/v1/tts?text={text}", timeout=120).read()
    assert len(audio) > 500 and audio[:2] in (b"ID", b"\xff\xfb", b"\xff\xf3", b"\xff\xf2")
    ok("TTS 新文本音频生成")

    req("/api/v1/auth/logout", {}, token=tokens[1])
    try:
        req("/api/v1/me/state", token=tokens[1])
        raise AssertionError("注销后 token 仍可用")
    except urllib.error.HTTPError as e:
        assert e.code == 401
    ok("注销与 token 失效")

    print(f"\n全部 {len(PASS)} 组 API 回归通过")


if __name__ == "__main__":
    main()
