#!/usr/bin/env python3
"""Atomic shared admission. Run against tests/ui_stub_server.py, never production."""
import copy
import json
import os
import urllib.error
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone, timedelta

BASE = os.environ.get("VOCAB_TEST_BASE", "http://127.0.0.1:18765").rstrip("/")


def call(path, body=None, token=None, method=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(BASE + path, None if body is None else json.dumps(body).encode(), headers, method=method)
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)


def reject(body, code, token=None):
    try:
        call("/api/v1/me/study-plan", body, token)
    except urllib.error.HTTPError as exc:
        assert exc.code == code, (exc.code, exc.read())
    else:
        raise AssertionError("expected rejection")


def account(cap=100, new=10, log=None):
    a = call("/api/v1/auth/register", {"username": "plan_" + uuid.uuid4().hex[:12], "password": "isolated_test_123"})
    s = {"v": 1, "calibrated": True, "frontier": 1, "pointer": 1, "probeCount": 0,
         "cards": {}, "log": log or [], "pendingNew": [], "settings": {"dailyCap": cap, "newPerDay": new}}
    call("/api/v1/me/state", s, a["token"], "PUT")
    return a


day = datetime.now(timezone.utc).date().isoformat()
body = {"day": day, "offset_minutes": 0}
def reserve(a, words=(), completed=(), exhausted=False):
    return call("/api/v1/me/study-plan", {**body, "candidates": list(words), "completed": list(completed), "new_exhausted": exhausted}, a["token"])


def w(name, kind="review", **kw):
    return {"word": name, "kind": kind, **kw}


# At 99, simultaneous independent devices can reserve only one further word.
prior = [{**w("prior" + str(i)), "d": day, "rating": 3, "eventId": uuid.uuid4().hex} for i in range(99)]
a = account(log=prior)
initial = call("/api/v1/me/state", token=a["token"])
with ThreadPoolExecutor(max_workers=6) as pool:
    replies = list(pool.map(lambda i: reserve(a, [w("new" + str(i), "learn")]), range(6)))
assert sum(len(r["approved"]) for r in replies) == 1
assert all(len(r["items"]) == 100 for r in replies)
plan = reserve(a)
assert len(plan["items"]) == 100 and sum(i["new_word"] for i in plan["items"]) == 1
assert plan["account_id"] == a["user"]["account_id"]
assert plan["requires_sync"], "a client omitting server progress needs a fresh pull"
after = call("/api/v1/me/state", token=a["token"])
assert after == initial, "reservation is not a fabricated learning grade or state revision"
allowed = next(i["word"] for i in plan["items"] if i["new_word"])
assert reserve(a, [w(allowed, "learn")])["approved"] == [allowed], "retry must reuse the same slot"
assert reserve(a, [w("prior0")])["approved"] == ["prior0"], "counted-word practice remains possible at capacity"

# New-word target is reserved even if another client first requests only drills.
b = account(cap=4, new=2)
assert len(reserve(b, [w("r"+str(i)) for i in range(4)])["approved"]) == 2
plan = reserve(b, [w("n0", "learn", from_pending=True), w("n1", "learn"), w("n2", "learn")])
assert plan["approved"] == ["n0", "n1"] and len(plan["items"]) == 4
assert next(i for i in plan["items"] if i["word"] == "n0")["from_pending"] is True
assert not reserve(b, [w("n2", "learn")])["approved"]
assert len(reserve(a)["items"]) == 100, "different accounts have independent pools"

# Queue presentation order cannot let reviews consume the ten reserved new slots.
c = account()
plan = reserve(c, [w("r"+str(i)) for i in range(100)] + [w("n"+str(i), "learn") for i in range(10)])
assert len(plan["items"]) == 100 and sum(i["new_word"] for i in plan["items"]) == 10
assert set(reserve(c)["approved"]) == set(), "read does not allocate more work"

# At the actual end of the vocabulary, the unused new slots can go to review.
d = account(cap=4, new=2)
plan = reserve(d, [w("onlynew", "learn")] + [w("r"+str(i)) for i in range(4)], exhausted=True)
assert len(plan["items"]) == 4 and sum(i["new_word"] for i in plan["items"]) == 1

# Both uploaded progress and unsent device progress consume capacity. An old
# device's overflow remains auditable; importing it cannot authorize more words.
overflow = reserve(a, [w("another", "learn")], completed=[w("legacyextra", "learn")])
assert overflow["over_limit"] and len(overflow["items"]) == 101 and overflow["approved"] == []
assert any(i["word"] == "legacyextra" and i["completed"] for i in reserve(a)["items"])
e = account(cap=3, new=1)
plan = reserve(e, [w("new", "learn"), w("other")], completed=[w("offline0"), w("offline1")])
assert len(plan["items"]) == 3 and plan["approved"] == ["new"]

# Issued offline reservations cannot be revoked by lowering a setting. Raising
# the limit is allowed after the setting has actually reached the server.
state = call("/api/v1/me/state", token=b["token"])["state"]
state["settings"].update(dailyCap=1, newPerDay=0)
call("/api/v1/me/state", state, b["token"], "PUT")
assert reserve(b)["cap"] == 4 and reserve(b)["new_target"] == 2
state = call("/api/v1/me/state", token=b["token"])["state"]
state["settings"].update(dailyCap=6, newPerDay=3)
call("/api/v1/me/state", state, b["token"], "PUT")
plan = reserve(b, [w("n2", "learn"), w("r2")])
assert plan["cap"] == 6 and plan["new_target"] == 3 and len(plan["items"]) == 6

reject(body, 401)
reject({**body, "offset_minutes": True}, 422, a["token"])
reject({**body, "candidates": [w("x", "shadow")]}, 422, a["token"])
reject({**body, "new_exhausted": "true"}, 422, a["token"])
reject({**body, "day": "2000-01-01"}, 409, a["token"])
# Different device time zones must send the local day corresponding to the
# declared offset; accepting yesterday would resurrect an expired reservation.
plus14 = (datetime.now(timezone.utc) + timedelta(hours=14)).date().isoformat()
offset = call("/api/v1/me/study-plan", {"day": plus14, "offset_minutes": 840}, d["token"])
assert offset["day"] == plus14

# Shared probe count remains three even when another device requests different
# questions, or a reserved probe is later also reserved as a new word.
f = account()
with ThreadPoolExecutor(max_workers=6) as pool:
    replies = list(pool.map(lambda i: reserve(f, [w("probe"+str(i), "probe")]), range(6)))
assert sum(len(r["approved"]) for r in replies) == 3
plan = reserve(f)
first = plan["items"][0]["word"]
reserve(f, [w(first, "learn")])
assert reserve(f, [w("fourth", "probe")])["approved"] == []
assert sum(i["probe_word"] for i in reserve(f)["items"]) == 3

# A stale client must not allocate a known server card as an unseen word.
state = call("/api/v1/me/state", token=f["token"])["state"]
state["cards"]["known"] = {"pos": 1}
call("/api/v1/me/state", state, f["token"], "PUT")
plan = reserve(f, [w("known", "learn")])
assert plan["approved"] == [] and plan["requires_sync"]
assert not any(i["word"] == "known" for i in plan["items"])
print("PASS shared daily reservations: concurrent last slot/probes, idempotency, new target, exhaustion, unsent/legacy history, settings, stale progress and account/date isolation")
