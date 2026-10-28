#!/usr/bin/env python3
"""Immutable, account-scoped FSRS parameter versions survive changes and restart."""
import copy, json, sqlite3, subprocess, sys, tempfile
from pathlib import Path
from fastapi import HTTPException
sys.path.insert(0, sys.argv[1] if len(sys.argv) > 1 else 'server')
from app import main as m, auth

with tempfile.TemporaryDirectory() as temp:
    m.PERSONAL_DB = Path(temp) / 'personal.db'
    m.init_db()
    scheduler_a = m._FsrsScheduler(desired_retention=.86, enable_fuzzing=False)
    scheduler_b = m._FsrsScheduler(desired_retention=.94, enable_fuzzing=False)
    active = {7: scheduler_a, 8: scheduler_b}
    m.fsrs_for_user = lambda uid, account_id: active[uid]
    m.identity_by_token = lambda token: {'Bearer seven': (7, 'a' * 32), 'Bearer eight': (8, 'b' * 32)}.get(token)
    req = m.FsrsIn(is_new=True, rating=3, now='2026-10-20T00:00:00Z', deterministic=True)
    first = m.fsrs_review(req, authorization='Bearer seven')
    old_key = first['scheduler_key']
    active[7] = scheduler_b
    second = m.fsrs_review(req, authorization='Bearer seven')
    assert second['scheduler_key'] != old_key
    # Clear all in-memory caches: the recorded version must come from the DB.
    m._FSRS_USER_CACHE.clear()
    recovered = m.fsrs_review(req.model_copy(update={'scheduler_key':old_key}), authorization='Bearer seven')
    assert recovered == first
    app_parent = str(Path(m.__file__).resolve().parents[1])
    child = """import sys
sys.path.insert(0, sys.argv[1])
from pathlib import Path
from app import main
main.PERSONAL_DB = Path(sys.argv[2])
main.fsrs_for_user = lambda uid, account_id: main._FsrsScheduler(desired_retention=.94)
scheduler, key = main.fsrs_scheduler_version(7, sys.argv[3], 'a' * 32)
assert scheduler.desired_retention == .86 and key == sys.argv[3]
"""
    subprocess.run([sys.executable, '-c', child, app_parent, str(m.PERSONAL_DB), old_key], check=True)
    # The same root may have independently applied events with different versions.
    event_a = {"id":"version-a", "rating":3, "at":"2026-10-20T00:00:00Z"}
    event_b = {"id":"version-b", "rating":3, "at":"2026-10-25T00:00:00Z"}
    base = {"is_new":True, "state":1, "stability":0, "difficulty":0, "rating":3}
    def branch(event, scheduler_key):
        result = m.fsrs_review(req.model_copy(update={"now": event["at"], "scheduler_key": scheduler_key}), authorization="Bearer seven")
        fsrs = {k:result[k] for k in ("state", "stability", "difficulty", "due", "step", "scheduled_days")}
        fsrs["lastReview"] = result["last_review"]
        card = {"fsrs":fsrs, "due":fsrs["due"], "appliedFsrs":[event["id"]],
                "fsrsHistory":{"base":base, "events":[event], "schedulerKey":scheduler_key}}
        return {"v":1,"cards":{"apple":card},"log":[],"pendingNew":[],"settings":{}}
    mixed = auth.merge_learning_states(branch(event_a, old_key), branch(event_b, second["scheduler_key"]))
    events = mixed["cards"]["apple"]["pendingFsrs"]["events"]
    assert [event["schedulerKey"] for event in events] == [old_key, second["scheduler_key"]]
    def replay(events, force=None):
        body = dict(base)
        for event in events:
            body.update(rating=event["rating"], now=event["at"], deterministic=True,
                        scheduler_key=force or event["schedulerKey"])
            result = m.fsrs_review(m.FsrsIn(**body), authorization="Bearer seven")
            body = {k:result[k] for k in ("state", "stability", "difficulty", "due", "step", "last_review")}
        return result
    # An older Web client keeps unknown fields but ignores the per-event versions.
    # Its all-current replay must not be mistaken for a verified mixed replay.
    old_client = copy.deepcopy(mixed)
    old_card = old_client["cards"]["apple"]
    wrong = replay(events, force=second["scheduler_key"])
    old_card["fsrs"] = {k:wrong[k] for k in ("state", "stability", "difficulty", "due", "step", "scheduled_days")}
    old_card["fsrs"]["lastReview"] = wrong["last_review"]
    old_card["appliedFsrs"] = ["version-a", "version-b"]
    old_card.pop("pendingFsrs")
    unsafe = auth.merge_learning_states(mixed, old_client)["cards"]["apple"]
    assert "pendingFsrs" in unsafe and "fsrsReplayVersions" not in unsafe
    # A new client explicitly records each applied version and may settle the union.
    verified_client = copy.deepcopy(old_client)
    verified_card = verified_client["cards"]["apple"]
    correct = replay(events)
    verified_card["fsrs"] = {k:correct[k] for k in ("state", "stability", "difficulty", "due", "step", "scheduled_days")}
    verified_card["fsrs"]["lastReview"] = correct["last_review"]
    verified_card["fsrsReplayVersions"] = {e["id"]:e["schedulerKey"] for e in events}
    accepted = auth.merge_learning_states(mixed, verified_client)["cards"]["apple"]
    assert "pendingFsrs" not in accepted and accepted["fsrs"] == verified_card["fsrs"]

    mixed_result = replay(events)
    assert mixed_result == replay(events)  # same IDs and recorded versions reproduce exactly
    assert mixed_result["due"] != replay(events, force=old_key)["due"]
    # A superset with an unknown applied version cannot be accepted merely because
    # another device knows that event's version: recompute from the verified union.
    unverified = copy.deepcopy(mixed)
    card = unverified["cards"]["apple"]
    card["fsrsHistory"]["events"][0].pop("schedulerKey")
    card["appliedFsrs"] = ["version-a", "version-b"]
    card.pop("pendingFsrs")
    recompute = auth.merge_learning_states(unverified, branch(event_a, old_key))["cards"]["apple"]
    assert [e["schedulerKey"] for e in recompute["pendingFsrs"]["events"]] == [old_key, second["scheduler_key"]]
    # The same event ID with conflicting recorded versions is never deduplicated silently.
    conflict = copy.deepcopy(branch(event_a, old_key))
    conflict["cards"]["apple"]["fsrsHistory"]["events"][0]["schedulerKey"] = second["scheduler_key"]
    try:
        auth.merge_learning_states(branch(event_a, old_key), conflict)
        raise AssertionError("conflicting versions for one event accepted")
    except HTTPException as e:
        assert e.status_code == 409

    # Legacy and migrated forms of the same event must not double-count it.
    migrated = branch(event_a, old_key)
    migrated["cards"]["apple"]["fsrsHistory"]["events"][0]["schedulerKey"] = old_key
    same = auth.merge_learning_states(branch(event_a, old_key), migrated)["cards"]["apple"]
    assert len(same["fsrsHistory"]["events"]) == 1 and "pendingFsrs" not in same

    # Another account cannot use this user's saved historical parameters.
    try:
        m.fsrs_review(req.model_copy(update={'scheduler_key':old_key}), authorization='Bearer eight')
        raise AssertionError('another account could access a historical parameter version')
    except HTTPException as e:
        assert e.status_code == 409
    # Tampering or a different FSRS library version cannot silently alter a replay.
    with sqlite3.connect(m.PERSONAL_DB) as conn:
        encoded = conn.execute('SELECT config_json FROM fsrs_scheduler_versions WHERE owner=? AND scheduler_key=?', ('account:' + 'a' * 32, old_key)).fetchone()[0]
        tampered = json.loads(encoded); tampered['desired_retention'] = .8
        conn.execute('UPDATE fsrs_scheduler_versions SET config_json=? WHERE owner=? AND scheduler_key=?', (json.dumps(tampered), 'account:' + 'a' * 32, old_key))
    try:
        m.fsrs_review(req.model_copy(update={'scheduler_key':old_key}), authorization='Bearer seven')
        raise AssertionError('tampered scheduler snapshot accepted')
    except HTTPException as e:
        assert e.status_code == 409
print('PASS scheduler versions survive parameter change and restart; owner isolation and tamper rejection')
