#!/usr/bin/env python3
"""Staging persistence, migration and transactional quota tests."""
import base64, hashlib, json, os, sqlite3, subprocess, sys, tempfile, time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from fastapi import HTTPException
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'server'))
from app import delta_staging as stage

def body(batch,payload):
    return {'batch_id':batch,'generation':'a'*32,'base_revision':'0','restore_epoch':0,
            'byte_length':len(payload),'part_count':(len(payload)+stage.PART_BYTES-1)//stage.PART_BYTES,
            'sha256':hashlib.sha256(payload).hexdigest()}
def verify(*args): pass
with tempfile.TemporaryDirectory(prefix='vocab-delta-stage-') as tmp:
    db=Path(tmp)/'state.db'
    # Migrate a pre-nonce temporary table without changing the original bytes.
    with sqlite3.connect(db) as conn:
        conn.execute('''CREATE TABLE account_delta_stages(account_id TEXT,batch_id TEXT,generation TEXT,base_revision TEXT,restore_epoch INTEGER,byte_length INTEGER,part_count INTEGER,digest TEXT,created_at REAL,expires_at REAL,PRIMARY KEY(account_id,batch_id))''')
        payload=b'[1]'; manifest=body('b'*32,payload)
        conn.execute('INSERT INTO account_delta_stages VALUES(?,?,?,?,?,?,?,?,?,?)',('owner',manifest['batch_id'],manifest['generation'],'0',0,len(payload),1,manifest['sha256'],time.time(),time.time()+3600))
        stage.initialize(conn)
    stage.put(db,'owner',manifest['batch_id'],0,{'data':base64.b64encode(payload).decode()})
    code="from app.delta_staging import assemble; import sys; m,b,n=assemble(sys.argv[1],'owner','b'*32); print(b.decode(),len(n))"
    env={**os.environ,'PYTHONPATH':str(root/'server')}
    result=subprocess.run([sys.executable,'-c',code,str(db)],env=env,text=True,capture_output=True,check=True)
    assert result.stdout.strip()=='[1] 32'
    stage.delete(db,'owner',manifest['batch_id'])
    # Competing requests reserve quota under one SQLite write transaction.
    stage.MAX_GLOBAL_BYTES=10
    data=b'123456'; first=body('c'*32,data); second=body('d'*32,data)
    def create(item):
        try: return stage.create(db,item['batch_id'],item,verify)
        except HTTPException as error: return error.status_code
    with ThreadPoolExecutor(max_workers=2) as pool: result=list(pool.map(create,[first,second]))
    assert sum(isinstance(value,dict) for value in result)==1 and 503 in result
    with sqlite3.connect(db) as conn:
        assert conn.execute('SELECT count(*) FROM account_delta_stages').fetchone()[0]==1
        conn.execute('UPDATE account_delta_stages SET expires_at=0')
    assert isinstance(create(second),dict)  # Expired quota is reclaimed before reservation.
print('PASS durable stage restart, nonce migration and concurrent global quotas')
