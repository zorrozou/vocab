"""One dependency-free eligibility gate for diagnostics and the FSRS optimizer."""
from collections import Counter
from datetime import datetime, timezone

MIN_OBSERVATIONS = 400


def training_data(state, now=None, words=None):
    now = now or datetime.now(timezone.utc)
    if isinstance(now, (int, float)):
        now = datetime.fromtimestamp(now, timezone.utc)
    records, excluded, owners = [], Counter(), {}
    cards = state.get('cards') or {}
    if not isinstance(cards,dict): raise ValueError('Invalid cards in learning state')
    id_words = {}
    for word, card in cards.items():
        if not isinstance(card,dict) or not isinstance(card.get('fsrsHistory'),dict): continue
        events=card['fsrsHistory'].get('events')
        if not isinstance(events,list): continue
        for event in events:
            if isinstance(event,dict) and isinstance(event.get('id'),str): id_words.setdefault(event['id'],set()).add(word)
    conflicting_ids={key for key,value in id_words.items() if len(value)>1}
    for word, card in cards.items():
        if not isinstance(card,dict) or not isinstance(card.get('fsrsHistory'),dict):
            excluded['missing_history'] += 1
            continue
        reason, own, payloads = None, {}, {}
        history = card.get('fsrsHistory') or {}
        events = history.get('events') or []
        if words is not None and word not in words: reason = 'unknown_word'
        elif card.get('pendingFsrs') or card.get('fsrsIssue'): reason = 'pending_or_invalid'
        elif not isinstance(history.get('base'),dict) or history['base'].get('is_new') is not True: reason = 'missing_origin'
        elif not isinstance(events, list) or not events: reason = 'missing_history'
        else:
            for event in events:
                try:
                    key, rating, raw = event['id'], event['rating'], event['at']
                    if not isinstance(key, str) or not key or key in conflicting_ids or type(rating) is not int or rating not in (1, 2, 3, 4): raise ValueError()
                    at = datetime.fromisoformat(raw.replace('Z', '+00:00'))
                    if at.tzinfo is None or at > now: raise ValueError()
                    at = at.astimezone(timezone.utc)
                    signature = (word, rating, at)
                    if key in owners and owners[key] != signature: raise ValueError('conflicting event')
                    if key in own and own[key] != (at, word, key, rating): raise ValueError('conflicting event')
                    if key in payloads and payloads[key] != event: raise ValueError('conflicting event payload')
                    payloads[key] = event
                    own[key] = (at, word, key, rating)
                except (KeyError, TypeError, AttributeError, ValueError, OverflowError):
                    reason = 'invalid_event'; break
            if not reason and (not isinstance(card.get('appliedFsrs'), list) or any(not isinstance(key,str) for key in card['appliedFsrs']) or set(card['appliedFsrs']) != set(own)):
                reason = 'incomplete_history'
        if reason:
            excluded[reason] += 1
            continue
        for key, (at, _, _, rating) in own.items(): owners[key] = (word, rating, at)
        # The pinned optimizer consumes the first 64 reviews of each card.
        records.extend(sorted(own.values(), key=lambda r: (r[0], r[2]))[:64])
    # Cross-card reuse of even an identical event is never a second observation.
    records.sort(key=lambda r: (r[0], r[1], r[2]))
    previous, effective = {}, []
    for record in records:
        at, word, _, _ = record
        if word in previous and (at - previous[word]).total_seconds() >= 86400:
            effective.append(record)
        previous[word] = at
    cutoff = effective[int(len(effective) * .8)][0] if effective else None
    train = [r for r in effective if r[0] < cutoff]
    test = [r for r in effective if r[0] >= cutoff]
    reasons = []
    if len(effective) < MIN_OBSERVATIONS: reasons.append('insufficient_observations')
    if len(train) < 320 or len(test) < 80: reasons.append('insufficient_split')
    if {r[3] == 1 for r in train} != {True, False}: reasons.append('training_missing_outcome')
    if {r[3] == 1 for r in test} != {True, False}: reasons.append('validation_missing_outcome')
    return records, {'effective': len(effective), 'required': MIN_OBSERVATIONS,
                     'train': len(train), 'validation': len(test),
                     'train_forgotten': sum(r[3] == 1 for r in train),
                     'validation_forgotten': sum(r[3] == 1 for r in test),
                     'eligible': not reasons, 'reasons': reasons, 'excluded_cards': dict(excluded)}
