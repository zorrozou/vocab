"""Bounded, transaction-local change records for the stored account state.

The journal describes committed JSON, not independently stored FSRS parameters.
An incomplete history is signalled to readers; it is never fabricated.
"""
import copy
import hashlib
import json
import re

PAGE_BYTES = 128 * 1024
MAX_RECORD_BYTES = 12 * 1024 * 1024
MAX_RECORDS_PER_ACCOUNT = 32
MAX_ACCOUNT_BYTES = 16 * 1024 * 1024
MAX_GLOBAL_BYTES = 128 * 1024 * 1024
MAX_OPERATIONS = 2048
MAX_STAGED_OPERATIONS = 8192


def validate_upload_ops(ops, max_operations=MAX_OPERATIONS):
    """Validate an unambiguous, bounded patch before taking the write lock."""
    if not isinstance(ops, list) or not 1 <= len(ops) <= max_operations:
        raise ValueError('invalid operation count')
    seen, nested = set(), set()
    for op in ops:
        if not isinstance(op, dict) or op.get('op') not in ('set', 'remove', 'append_log'):
            raise ValueError('invalid operation')
        if set(op) != ({'op', 'path', 'value'} if op['op'] in ('set', 'append_log') else {'op', 'path'}):
            raise ValueError('invalid operation fields')
        path = op['path']
        if not isinstance(path, list) or len(path) > 2 or any(not isinstance(k, str) or len(k) > 512 for k in path):
            raise ValueError('invalid operation path')
        if path and path[0] == '__proto__':
            raise ValueError('invalid root field')
        if not path and (op['op'] != 'set' or not isinstance(op['value'], dict) or len(ops) != 1):
            raise ValueError('invalid root replacement')
        if op['op'] == 'append_log':
            events = op['value']
            if path != ['log'] or not isinstance(events, list) or not 1 <= len(events) <= 2048:
                raise ValueError('invalid log append')
            ids = set()
            for event in events:
                event_id = event.get('eventId') if isinstance(event, dict) else None
                if not isinstance(event_id, str) or not re.fullmatch(r'[a-f0-9-]{8,64}', event_id) or event_id in ids:
                    raise ValueError('invalid log event id')
                ids.add(event_id)
        item = tuple(path)
        if item in seen or (len(path) == 1 and path[0] in nested) or (len(path) == 2 and (path[0],) in seen):
            raise ValueError('duplicate or overlapping operation')
        seen.add(item)
        if len(path) == 2:
            nested.add(path[0])


def apply_upload_ops(before, ops):
    """Apply a prevalidated patch to a private copy of one stored baseline."""
    state = copy.deepcopy(before)
    for op in ops:
        path = op['path']
        if not path:
            state = copy.deepcopy(op['value'])
            continue
        if not isinstance(state, dict):
            raise ValueError('missing base state')
        target = state
        if len(path) == 2:
            target = state.get(path[0])
            if not isinstance(target, dict):
                raise ValueError('missing map parent')
        key = path[-1]
        if op['op'] == 'append_log':
            existing = target.get(key)
            if not isinstance(existing, list):
                raise ValueError('missing log baseline')
            by_id = {}
            for event in existing:
                event_id = event.get('eventId') if isinstance(event, dict) else None
                if event_id is not None:
                    if not isinstance(event_id, str) or (event_id in by_id and not same_json(by_id[event_id], event)):
                        raise ValueError('conflicting log baseline')
                    by_id[event_id] = event
            for event in op['value']:
                event_id = event['eventId']
                if event_id in by_id:
                    if not same_json(by_id[event_id], event):
                        raise ValueError('conflicting log event')
                else:
                    existing.append(copy.deepcopy(event))
                    by_id[event_id] = event
        elif op['op'] == 'remove':
            if key not in target:
                raise ValueError('missing field to remove')
            del target[key]
        else:
            target[key] = copy.deepcopy(op['value'])
    if not isinstance(state, dict):
        raise ValueError('invalid result')
    return state


def same_json(left, right):
    # Python considers True == 1 and 1 == 1.0; JSON types must not disappear.
    if type(left) is not type(right):
        return False
    if isinstance(left, (dict, list)):
        return json.dumps(left, sort_keys=True, ensure_ascii=False, separators=(',', ':'), allow_nan=False) == json.dumps(right, sort_keys=True, ensure_ascii=False, separators=(',', ':'), allow_nan=False)
    if isinstance(left, float):
        return json.dumps(left, allow_nan=False) == json.dumps(right, allow_nan=False)
    return left == right


def state_delta(before, after, compact_log=False):
    """Patch top-level members and individual map entries; arrays stay atomic."""
    if before is None:
        return [{"op": "set", "path": [], "value": after}]
    ops = []
    for name in sorted(before.keys() | after.keys()):
        if name not in after:
            ops.append({"op": "remove", "path": [name]})
        elif name not in before:
            ops.append({"op": "set", "path": [name], "value": after[name]})
        elif not same_json(before[name], after[name]):
            old, new = before[name], after[name]
            if (compact_log and name == 'log' and isinstance(old, list) and isinstance(new, list)
                    and 0 < len(new) - len(old) <= 2048 and same_json(old, new[:len(old)])):
                appended = new[len(old):]
                candidate = {'op':'append_log', 'path':['log'], 'value':appended}
                try:
                    validate_upload_ops([candidate])
                    existing = {event.get('eventId') for event in old if isinstance(event, dict) and isinstance(event.get('eventId'), str)}
                    if any(event['eventId'] in existing for event in appended):
                        raise ValueError('event already present')
                    ops.append(candidate)
                except ValueError:
                    ops.append({'op':'set', 'path':[name], 'value':new})
            elif compact_log and name == 'log' and isinstance(old, list) and isinstance(new, list):
                prefix = 0
                while prefix < min(len(old), len(new)) and same_json(old[prefix], new[prefix]):
                    prefix += 1
                suffix = 0
                while suffix < min(len(old) - prefix, len(new) - prefix) and same_json(old[-suffix - 1], new[-suffix - 1]):
                    suffix += 1
                items = new[prefix:len(new)-suffix if suffix else len(new)]
                if len(items) <= 2048:
                    ops.append({'op':'splice_log', 'path':['log'], 'value':{'index':prefix, 'delete':len(old)-prefix-suffix, 'items':items}})
                else:
                    ops.append({'op':'set', 'path':[name], 'value':new})
            elif isinstance(old, dict) and isinstance(new, dict):
                sub = []
                for key in sorted(old.keys() | new.keys()):
                    if key not in new:
                        sub.append({"op": "remove", "path": [name, key]})
                    elif key not in old or not same_json(old[key], new[key]):
                        sub.append({"op": "set", "path": [name, key], "value": new[key]})
                    if len(sub) + len(ops) > MAX_OPERATIONS:
                        break
                if len(sub) + len(ops) <= MAX_OPERATIONS:
                    ops.extend(sub)
                else:
                    ops.append({"op": "set", "path": [name], "value": new})
            else:
                ops.append({"op": "set", "path": [name], "value": new})
    if len(ops) > MAX_OPERATIONS:
        return [{"op": "set", "path": [], "value": after}]
    return ops


def evict_oldest_payload(conn, account_id=None):
    """Prune the oldest legacy payload first if a complete compact alternative exists."""
    where, args = ('AND c.account_id=?', (account_id,)) if account_id is not None else ('', ())
    row = conn.execute(f"""SELECT c.account_id,c.revision,length(c.payload),
        EXISTS(SELECT 1 FROM account_state_change_compact p WHERE p.account_id=c.account_id AND p.revision=c.revision)
        FROM account_state_changes c WHERE (length(c.payload)>0 OR EXISTS(
          SELECT 1 FROM account_state_change_compact p WHERE p.account_id=c.account_id AND p.revision=c.revision)) {where}
        ORDER BY CASE WHEN length(c.payload)>0 THEN 0 ELSE 1 END,c.created_at,c.rowid LIMIT 1""", args).fetchone()
    if row is None:
        raise ValueError('orphaned compact journal exceeds quota')
    account, revision, legacy_bytes, has_compact = row
    if legacy_bytes and has_compact:
        conn.execute("UPDATE account_state_changes SET payload=?,digest=? WHERE account_id=? AND revision=?",
                     (b'', '', account, revision))
    else:
        conn.execute('DELETE FROM account_state_changes WHERE account_id=? AND revision=?', (account, revision))


def record_change(conn, account_id, base_revision, revision, epoch, before, after, now, reset=False):
    """Record or explicitly leave a gap, in the caller's account-state transaction."""
    if type(epoch) is not int or not 0 <= epoch <= 2**53 - 1:
        reset, epoch = True, -1
    compact = None
    if reset:
        encoded = b''
    else:
        try:
            encoded = json.dumps({"ops": state_delta(before, after)}, ensure_ascii=False,
                                 separators=(',', ':'), allow_nan=False).encode('utf-8')
            compact_ops = state_delta(before, after, compact_log=True)
            if any(op['op'] in ('append_log', 'splice_log') for op in compact_ops):
                compact = json.dumps({'ops':compact_ops}, ensure_ascii=False,
                                     separators=(',', ':'), allow_nan=False).encode('utf-8')
        except (RecursionError, TypeError, ValueError, UnicodeError):
            # A state may be valid but too deeply nested for the wrapped patch.
            # Preserve the state write and require a fresh baseline instead.
            reset, encoded, compact = True, b'', None
    # A very large change becomes a reset marker: the durable state still commits,
    # but a reader must obtain a fresh snapshot instead of seeing a partial patch.
    if len(encoded) > MAX_RECORD_BYTES:
        reset, encoded, compact = True, b'', None
    conn.execute("""INSERT INTO account_state_changes
                    (account_id,revision,base_revision,restore_epoch,reset,payload,digest,created_at)
                    VALUES(?,?,?,?,?,?,?,?)""",
                 (account_id, revision, base_revision, epoch, int(reset), encoded,
                  hashlib.sha256(encoded).hexdigest(), now))
    if compact is not None and len(compact) < len(encoded):
        conn.execute('INSERT INTO account_state_change_compact(account_id,revision,payload,digest) VALUES(?,?,?,?)',
                     (account_id,revision,compact,hashlib.sha256(compact).hexdigest()))
    # A reader whose required revision was pruned receives 410 and must resnapshot.
    conn.execute("""DELETE FROM account_state_changes WHERE account_id=? AND revision NOT IN
                    (SELECT revision FROM account_state_changes WHERE account_id=? ORDER BY revision DESC LIMIT ?)""",
                 (account_id, account_id, MAX_RECORDS_PER_ACCOUNT))
    while conn.execute("SELECT coalesce(sum(length(payload)),0)+(SELECT coalesce(sum(length(payload)),0) FROM account_state_change_compact WHERE account_id=?) FROM account_state_changes WHERE account_id=?", (account_id,account_id)).fetchone()[0] > MAX_ACCOUNT_BYTES:
        evict_oldest_payload(conn, account_id)
    while conn.execute("SELECT coalesce(sum(length(payload)),0)+(SELECT coalesce(sum(length(payload)),0) FROM account_state_change_compact) FROM account_state_changes").fetchone()[0] > MAX_GLOBAL_BYTES:
        evict_oldest_payload(conn)
