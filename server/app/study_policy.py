"""Versioned recall evidence, independent of trimmed activity/FSRS histories.

The migration origin is immutable. Missing fields from an older client never
erase evidence; a real new Again revokes even grandfathered mastery.
"""
from copy import deepcopy
from datetime import datetime, timezone, date
import math, json
from fastapi import HTTPException


def instant(value):
    try:
        d = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return d.timestamp() if d.tzinfo else None
    except (TypeError, AttributeError, ValueError, OverflowError):
        return None


def legacy_mastered(card):
    if any(event.get("rating") not in (2, 3, 4) for event in (card.get("pendingFsrs") or {}).get("events", [])):
        return False
    f = card.get("fsrs")
    if f is None:
        return card.get("stage") == 6
    return (isinstance(f, dict) and f.get("state") == 2 and
            type(f.get("stability")) in (int, float) and math.isfinite(f["stability"]) and f["stability"] >= 180 and
            type(f.get("difficulty")) in (int, float) and 1 <= f["difficulty"] <= 10)


def history_events(card):
    out = {}
    for group in ("fsrsHistory", "pendingFsrs"):
        for event in (card.get(group) or {}).get("events", []):
            out[event["id"]] = event
    return out


def origin(card, at=None):
    return {"version": 1, "originAt": at or datetime.now(timezone.utc).isoformat(),
            "legacy": legacy_mastered(card),
            "originIds": sorted(set(history_events(card)) | set(card.get("appliedFsrs") or [])), "events": {}}


def validate_evidence(e):
    def invalid():
        raise HTTPException(422, {"code": "invalid-study-evidence", "message": "学习证据格式无效，原进度已保留"})
    if not isinstance(e, dict) or e.get("version") != 1 or type(e.get("legacy")) is not bool or instant(e.get("originAt")) is None:
        invalid()
    if not isinstance(e.get("originIds"), list) or any(not isinstance(x, str) for x in e["originIds"]): invalid()
    if not isinstance(e.get("events"), dict): invalid()
    for key, item in e["events"].items():
        if not isinstance(key, str) or not key or not isinstance(item, dict): invalid()
        if instant(item.get("at")) is None or type(item.get("rating")) is not int or item["rating"] not in (1, 2, 3, 4): invalid()
        if item.get("kind") not in ("learn", "acceptance", "review", "drill", "unknown") or type(item.get("verified")) is not bool: invalid()
        if any(item.get(flag) is not None and type(item[flag]) is not bool for flag in ("guessed", "hinted")): invalid()
        try: date.fromisoformat(item.get("day", ""))
        except (ValueError, TypeError): invalid()
        prior = item.get("priorAt")
        if prior is not None and (instant(prior) is None or instant(prior) > instant(item["at"])): invalid()


def merge_evidence(left, right, merged):
    metadata = [c["studyEvidence"] for c in (left, right) if c and c.get("studyEvidence") is not None]
    for e in metadata: validate_evidence(e)
    if not metadata:
        # Anchor old state before an old client advances it, whenever possible.
        metadata = [origin(left or right or merged)]
    selected = min(metadata, key=lambda e: (instant(e["originAt"]), e["originAt"], json.dumps([e["legacy"],sorted(e["originIds"])])))
    out = deepcopy(selected)
    events = out["events"]
    for e in metadata:
        for key, item in e["events"].items():
            if key in events and events[key] != item:
                # A previous old-client merge may only know the FSRS event.
                prior = events[key]
                if instant(prior["at"]) != instant(item["at"]) or prior["rating"] != item["rating"] or (prior["kind"] != "unknown" and item["kind"] != "unknown"):
                    raise HTTPException(409, "同一评分的学习证据冲突，请保留两端进度")
                if item["kind"] == "unknown": continue
            events[key] = deepcopy(item)
    original = set(out["originIds"])
    for key, event in history_events(merged).items():
        if key in original: continue
        if key in events:
            if events[key]["rating"] != event["rating"] or instant(events[key]["at"]) != instant(event["at"]):
                raise HTTPException(409, "学习证据与调度评分不一致")
        else:
            events[key] = {"at": event["at"], "day": event["at"][:10], "rating": event["rating"], "kind": "unknown", "verified": False}
    return out


def is_mastered(card):
    e = card.get("studyEvidence")
    if e is None: return legacy_mastered(card)
    if e.get("version") != 1: return False
    f = card.get("fsrs")
    if f is None:
        valid = card.get("stage") == 6 and e["legacy"]
    else:
        valid = f.get("state") == 2 and math.isfinite(f.get("stability", 0)) and f.get("stability", 0) > 0 and 1 <= f.get("difficulty", 0) <= 10
    if not valid: return False
    pending = {x["id"] for x in (card.get("pendingFsrs") or {}).get("events", [])}
    days, last_gap, forgotten, previous = set(), 0, False, None
    for key, item in sorted(e["events"].items(), key=lambda p: (instant(p[1]["at"]), p[0])):
        at = instant(item["at"])
        prior = instant(item.get("priorAt"))
        candidates = [x for x in (previous, prior) if x is not None]
        gap = at - max(candidates) if candidates else 0
        previous = at
        if item["rating"] == 1:
            forgotten = True; days.clear(); last_gap = 0
        elif key not in pending and item["kind"] in ("review", "drill") and item["verified"] and not item.get("guessed") and not item.get("hinted") and item["rating"] >= 3 and gap >= 86400:
            days.add(item["day"]); last_gap = gap
    return (e["legacy"] and not forgotten) or (f is not None and f.get("stability", 0) >= 180 and len(days) >= 3 and last_gap >= 7 * 86400)
