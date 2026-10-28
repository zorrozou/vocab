"""Password migration, concurrency and identity replacement safety."""
import concurrent.futures, sqlite3, sys, tempfile, threading
from pathlib import Path
from fastapi import FastAPI, HTTPException
sys.path.insert(0,'server')
from app import auth
with tempfile.TemporaryDirectory() as tmp:
    auth.USERS_DB=Path(tmp)/'users.db'
    app=FastAPI();auth.mount_auth(app)
    routes={route.path:route.endpoint for route in app.routes if hasattr(route,'endpoint')}
    register,login=routes['/api/v1/auth/register'],routes['/api/v1/auth/login']
    signup=register(auth.RegisterIn(username='alice',password='test_password_123'),None)
    with sqlite3.connect(auth.USERS_DB) as conn:
        row=conn.execute('SELECT password_hash,salt FROM users WHERE username=?',('alice',)).fetchone()
    assert row[0].startswith('$argon2id$v=19$m=19456,t=2,p=1$') and row[1]==''
    try:login(auth.LoginIn(username='alice',password='wrong'),None)
    except HTTPException as e:assert e.status_code==401
    else:raise AssertionError('incorrect password accepted')
    assert login(auth.LoginIn(username='alice',password='test_password_123'),None)['user']['account_id']==signup['user']['account_id']
    salt='ab'*16; old=auth.hash_pwd('legacy_password',salt)
    with sqlite3.connect(auth.USERS_DB) as conn:
        conn.execute("INSERT INTO users(id,username,nickname,password_hash,salt,created_at,last_login_at,account_id,legacy_personal) VALUES(?, ?, ?, ?, ?, 0,0,?,0)",(5,'legacy','Legacy',old,salt,'a'*32))
    try:login(auth.LoginIn(username='legacy',password='bad_password'),None)
    except HTTPException as e: assert e.status_code==401
    else: raise AssertionError('incorrect legacy password accepted')
    with sqlite3.connect(auth.USERS_DB) as conn:
        assert conn.execute('SELECT password_hash,salt FROM users WHERE id=5').fetchone()==(old,salt)
    slots=[auth._PASSWORD_SLOTS.acquire(blocking=False) for _ in range(4)]
    assert all(slots)
    try:
        try: register(auth.RegisterIn(username='busy',password='test_password_123'),None)
        except HTTPException as e: assert e.status_code==503 and e.headers['Retry-After']=='1'
        else: raise AssertionError('unbounded hash operations accepted')
    finally:
        for _ in slots: auth._PASSWORD_SLOTS.release()
    original=auth.verify_password_record; gate=threading.Barrier(2); local=threading.local()
    def concurrent_verify(password,row):
        result=original(password,row)
        if row and row[0]==5 and not getattr(local,'waited',False):
            local.waited=True;gate.wait(timeout=5)
        return result
    auth.verify_password_record=concurrent_verify
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        calls=[pool.submit(login,auth.LoginIn(username='legacy',password='legacy_password'),None) for _ in range(2)]
        assert all(f.result()['user']['account_id']=='a'*32 for f in calls)
    auth.verify_password_record=original
    with sqlite3.connect(auth.USERS_DB) as conn:
        migrated=conn.execute('SELECT password_hash,salt FROM users WHERE id=5').fetchone()
    assert migrated[0].startswith('$argon2id$') and migrated[1]==''
    assert login(auth.LoginIn(username='legacy',password='legacy_password'),None)['user']['id']==5
    # Replace the account after its old password has been checked, before token issuance.
    replaced=False
    def replace_after_verify(password,row):
        global replaced
        valid,upgrade=original(password,row)
        if valid and row and row[0]==5 and not replaced:
            replaced=True
            with sqlite3.connect(auth.USERS_DB) as conn:
                conn.execute('DELETE FROM users WHERE id=5')
                conn.execute("INSERT INTO users(id,username,nickname,password_hash,salt,created_at,last_login_at,account_id,legacy_personal) VALUES(5,'legacy','New',?,?,0,0,?,0)",(auth.hash_pwd('other_password',salt),salt,'b'*32))
        return valid,upgrade
    auth.verify_password_record=replace_after_verify
    try:login(auth.LoginIn(username='legacy',password='legacy_password'),None)
    except HTTPException as e:assert e.status_code==401
    else:raise AssertionError('replaced account inherited an old verification')
    finally:auth.verify_password_record=original
    with sqlite3.connect(auth.USERS_DB) as conn:
        assert conn.execute("SELECT COUNT(*) FROM tokens WHERE account_id=?",('b'*32,)).fetchone()[0]==0
    assert login(auth.LoginIn(username='legacy',password='other_password'),None)['user']['account_id']=='b'*32
    for raw in ('$argon2id$v=19$m=999999999,t=2,p=1$AAAA$AAAA','invalid'):
        assert auth.verify_password_record('x',(8,'x',raw,'', 'c'*32))==(False,False)
print('PASS Argon2id registration, legacy migration, concurrent login and account-replacement fencing')
