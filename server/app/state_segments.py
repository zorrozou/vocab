"""Transactional, ordered per-entry representation of an account state.

During migration the existing JSON remains a compatibility mirror. Readers
must verify both representations and fail closed on mismatch. Callers manage
one SQLite transaction encompassing state, segments, journal and revision.
"""
import hashlib
import json

THRESHOLD_BYTES = 1024 * 1024


class SegmentError(ValueError):
    pass


def initialize(conn):
    conn.execute('''CREATE TABLE IF NOT EXISTS account_state_segment_meta(
        account_id TEXT PRIMARY KEY, revision INTEGER NOT NULL, manifest TEXT NOT NULL,
        byte_length INTEGER NOT NULL, digest TEXT NOT NULL)''')
    conn.execute('''CREATE TABLE IF NOT EXISTS account_state_segment_items(
        account_id TEXT NOT NULL, field_index INTEGER NOT NULL, item_index INTEGER NOT NULL,
        item_key TEXT, value_json TEXT NOT NULL,
        PRIMARY KEY(account_id,field_index,item_index))''')


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False)


def clear(conn, account):
    if not conn.in_transaction: raise SegmentError('segment update requires a transaction')
    conn.execute('DELETE FROM account_state_segment_items WHERE account_id=?', (account,))
    conn.execute('DELETE FROM account_state_segment_meta WHERE account_id=?', (account,))
    conn.execute('UPDATE account_state SET segments_version=0 WHERE account_id=?', (account,))


def write(conn, account, revision, state, *, force=False):
    if not conn.in_transaction: raise SegmentError('segment update requires a transaction')
    if not isinstance(state, dict) or type(revision) is not int or revision < 1:
        raise SegmentError('invalid state or revision')
    encoded = encode(state).encode('utf-8')
    if not force and len(encoded) < THRESHOLD_BYTES:
        clear(conn, account)
        return False
    manifest, rows = [], []
    for field_index, (name, value) in enumerate(state.items()):
        if not isinstance(name, str): raise SegmentError('invalid field name')
        if isinstance(value, dict):
            manifest.append({'name':name, 'kind':'map', 'count':len(value)})
            for item_index, (key, item) in enumerate(value.items()):
                if not isinstance(key, str): raise SegmentError('invalid map key')
                rows.append((account, field_index, item_index, key, encode(item)))
        elif isinstance(value, list):
            manifest.append({'name':name, 'kind':'array', 'count':len(value)})
            for item_index, item in enumerate(value):
                rows.append((account, field_index, item_index, None, encode(item)))
        else:
            manifest.append({'name':name, 'kind':'scalar', 'value':value})
    # Preserve unchanged rows so a small edit does not rewrite every entry.
    # Field and array indices remain positional: moving an entry updates the
    # affected positions, while removed positions must be deleted explicitly.
    existing = {(field, index): (key, raw) for field, index, key, raw in conn.execute(
        'SELECT field_index,item_index,item_key,value_json FROM account_state_segment_items WHERE account_id=?', (account,))}
    desired = {(field, index): (key, raw) for _, field, index, key, raw in rows}
    removed = [(account, field, index) for field, index in existing.keys() - desired.keys()]
    changed = [row for row in rows if existing.get((row[1], row[2])) != (row[3], row[4])]
    conn.executemany('DELETE FROM account_state_segment_items WHERE account_id=? AND field_index=? AND item_index=?', removed)
    conn.executemany('''INSERT INTO account_state_segment_items VALUES(?,?,?,?,?)
        ON CONFLICT(account_id,field_index,item_index) DO UPDATE SET
        item_key=excluded.item_key,value_json=excluded.value_json''', changed)
    conn.execute('''INSERT INTO account_state_segment_meta VALUES(?,?,?,?,?)
        ON CONFLICT(account_id) DO UPDATE SET revision=excluded.revision,manifest=excluded.manifest,
        byte_length=excluded.byte_length,digest=excluded.digest''',
        (account, revision, encode(manifest), len(encoded), hashlib.sha256(encoded).hexdigest()))
    if conn.execute('UPDATE account_state SET segments_version=1 WHERE account_id=?', (account,)).rowcount != 1:
        raise SegmentError('account state missing')
    return True


def read(conn, account, revision, legacy_json):
    """Return verified reconstructed state, or None when no segments exist."""
    flag = conn.execute('SELECT segments_version FROM account_state WHERE account_id=?', (account,)).fetchone()
    meta = conn.execute('SELECT revision,manifest,byte_length,digest FROM account_state_segment_meta WHERE account_id=?', (account,)).fetchone()
    if not flag or flag[0] not in (0, 1): raise SegmentError('segment marker invalid')
    if flag[0] == 0:
        if meta or conn.execute('SELECT 1 FROM account_state_segment_items WHERE account_id=? LIMIT 1', (account,)).fetchone():
            raise SegmentError('unexpected segments')
        return None
    if not meta: raise SegmentError('segments missing')
    try:
        stored_revision, manifest_raw, byte_length, digest = meta
        if type(stored_revision) is not int or stored_revision != revision or type(byte_length) is not int or byte_length < 2:
            raise SegmentError('segment revision invalid')
        manifest = json.loads(manifest_raw)
        if not isinstance(manifest, list): raise SegmentError('segment manifest invalid')
        rows = conn.execute('''SELECT field_index,item_index,item_key,value_json FROM account_state_segment_items
                               WHERE account_id=? ORDER BY field_index,item_index''', (account,)).fetchall()
        result, cursor = {}, 0
        for field_index, field in enumerate(manifest):
            if not isinstance(field, dict) or not isinstance(field.get('name'), str) or field['name'] in result:
                raise SegmentError('segment field invalid')
            name, kind = field['name'], field.get('kind')
            if kind == 'scalar':
                if set(field) != {'name','kind','value'}: raise SegmentError('segment scalar invalid')
                result[name] = field['value']
                continue
            if kind not in ('map','array') or set(field) != {'name','kind','count'} or type(field['count']) is not int or field['count'] < 0:
                raise SegmentError('segment collection invalid')
            if field['count'] > len(rows) - cursor: raise SegmentError('segment count invalid')
            value = {} if kind == 'map' else []
            for index in range(field['count']):
                if cursor >= len(rows): raise SegmentError('segment missing')
                current_field, current_index, key, raw = rows[cursor]; cursor += 1
                if current_field != field_index or current_index != index: raise SegmentError('segment order invalid')
                item = json.loads(raw)
                if kind == 'map':
                    if not isinstance(key, str) or key in value: raise SegmentError('segment map key invalid')
                    value[key] = item
                else:
                    if key is not None: raise SegmentError('segment array key invalid')
                    value.append(item)
            result[name] = value
        if cursor != len(rows): raise SegmentError('unexpected segment')
        data = encode(result).encode('utf-8')
        legacy = encode(json.loads(legacy_json)).encode('utf-8')
        if len(data) != byte_length or hashlib.sha256(data).hexdigest() != digest or data != legacy:
            raise SegmentError('segment integrity mismatch')
        return result
    except (TypeError, ValueError, UnicodeError, RecursionError) as error:
        raise SegmentError('stored state segments are invalid') from error
