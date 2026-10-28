"""Guest identity is server-issued and independent of caller-supplied device names."""
import hashlib, sqlite3, sys, tempfile
from pathlib import Path
from fastapi import HTTPException
sys.path.insert(0, 'server')
from app import main as m
with tempfile.TemporaryDirectory() as tmp:
    m.PERSONAL_DB = Path(tmp) / 'personal.db'
    m.init_db()
    a, b = m.issue_guest()['token'], m.issue_guest()['token']
    assert len(a) == 64 and a != b
    assert m.personal_owner('any-device', '', a) == m.personal_owner('different-device', '', a)
    assert m.personal_owner('any-device', '', a) != m.personal_owner('any-device', '', b)
    with sqlite3.connect(m.PERSONAL_DB) as conn:
        rows = conn.execute('SELECT token_hash FROM guest_credentials').fetchall()
    assert {r[0] for r in rows} == {hashlib.sha256(t.encode()).hexdigest() for t in (a,b)}
    for token in ('', '0'*64, '../bad', a.upper()):
        try: m.personal_owner('any-device', '', token)
        except HTTPException as e: assert e.status_code == 401
        else: raise AssertionError('invalid guest credential accepted')
    try: m.personal_owner('any-device', 'Bearer invalid', a)
    except HTTPException as e: assert e.status_code == 401
    else: raise AssertionError('invalid account authorization accepted')
print('PASS guest credentials are issued, stored hashed and checked independently of device')
