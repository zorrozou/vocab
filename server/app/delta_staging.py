"""Bounded, account-scoped staging for an atomic multi-part delta submission.

Parts are immutable and invisible to learning-state readers. The caller must
validate the assembled operations and commit them through the normal delta
transaction. A stage is only a retry aid, never a synchronization cursor.
"""
import base64
import binascii
import hashlib
import re
import secrets
import sqlite3
import time

from fastapi import HTTPException

PART_BYTES = 256 * 1024
MAX_BYTES = 16 * 1024 * 1024
MAX_ACCOUNT_BYTES = 32 * 1024 * 1024
MAX_GLOBAL_BYTES = 128 * 1024 * 1024
MAX_ACCOUNT_STAGES = 3
MAX_GLOBAL_STAGES = 4096
TTL_SECONDS = 3600
HEX_ID = re.compile(r'^[0-9a-f]{32}$')
SHA256 = re.compile(r'^[0-9a-f]{64}$')


def initialize(conn):
    conn.execute('''CREATE TABLE IF NOT EXISTS account_delta_stages(
        account_id TEXT NOT NULL, batch_id TEXT NOT NULL, generation TEXT NOT NULL,
        base_revision TEXT NOT NULL, restore_epoch INTEGER NOT NULL,
        byte_length INTEGER NOT NULL, part_count INTEGER NOT NULL, digest TEXT NOT NULL,
        created_at REAL NOT NULL, expires_at REAL NOT NULL, stage_nonce TEXT NOT NULL,
        PRIMARY KEY(account_id,batch_id))''')
    if 'stage_nonce' not in {row[1] for row in conn.execute('PRAGMA table_info(account_delta_stages)')}:
        conn.execute('ALTER TABLE account_delta_stages ADD COLUMN stage_nonce TEXT')
        for account,batch in conn.execute('SELECT account_id,batch_id FROM account_delta_stages').fetchall():
            conn.execute('UPDATE account_delta_stages SET stage_nonce=? WHERE account_id=? AND batch_id=?',(secrets.token_hex(16),account,batch))
    conn.execute('''CREATE TABLE IF NOT EXISTS account_delta_stage_parts(
        account_id TEXT NOT NULL, batch_id TEXT NOT NULL, part INTEGER NOT NULL,
        payload BLOB NOT NULL, digest TEXT NOT NULL,
        PRIMARY KEY(account_id,batch_id,part))''')
    conn.execute('CREATE INDEX IF NOT EXISTS account_delta_stages_expiry ON account_delta_stages(expires_at)')


def _cleanup(conn, now):
    conn.execute('''DELETE FROM account_delta_stage_parts WHERE EXISTS
        (SELECT 1 FROM account_delta_stages s WHERE s.account_id=account_delta_stage_parts.account_id
         AND s.batch_id=account_delta_stage_parts.batch_id AND s.expires_at<=?)''', (now,))
    conn.execute('DELETE FROM account_delta_stages WHERE expires_at<=?', (now,))


def validate_manifest(body):
    fields = {'batch_id','generation','base_revision','restore_epoch','byte_length','part_count','sha256'}
    if not isinstance(body, dict) or set(body) != fields:
        raise HTTPException(422, '增量暂存清单无效')
    batch, generation, revision, epoch = (body[k] for k in ('batch_id','generation','base_revision','restore_epoch'))
    length, count, digest = (body[k] for k in ('byte_length','part_count','sha256'))
    if not isinstance(batch,str) or not HEX_ID.fullmatch(batch) or not isinstance(generation,str) or not HEX_ID.fullmatch(generation):
        raise HTTPException(422, '增量暂存标识无效')
    if not isinstance(revision,str) or not re.fullmatch(r'0|[1-9][0-9]{0,18}',revision) or int(revision)>2**63-1:
        raise HTTPException(422, '学习状态修订号无效')
    if type(epoch) is not int or not 0<=epoch<=2**53-1:
        raise HTTPException(422, '学习状态恢复版本无效')
    if type(length) is not int or not 1<=length<=MAX_BYTES:
        raise HTTPException(413, '增量暂存超过大小上限')
    if type(count) is not int or count != (length+PART_BYTES-1)//PART_BYTES:
        raise HTTPException(422, '增量暂存分片数量无效')
    if not isinstance(digest,str) or not SHA256.fullmatch(digest):
        raise HTTPException(422, '增量暂存校验和无效')
    return batch,generation,revision,epoch,length,count,digest


def create(db, account, body, verify):
    batch,generation,revision,epoch,length,count,digest=validate_manifest(body)
    now=time.time()
    conn=sqlite3.connect(db,timeout=15)
    try:
        conn.execute('BEGIN IMMEDIATE')
        row=conn.execute('''SELECT generation,base_revision,restore_epoch,byte_length,part_count,digest,expires_at
                            FROM account_delta_stages WHERE account_id=? AND batch_id=?''',(account,batch)).fetchone()
        # Existing stages remain retryable after their commit advances revision.
        verify(conn,generation,revision,epoch,not (row and row[6]>now))
        if row and row[6]>now:
            if row[:6]!=(generation,revision,epoch,length,count,digest):
                raise HTTPException(409,'增量暂存标识已用于不同内容')
            conn.commit()
            return {'batch_id':batch,'part_bytes':PART_BYTES,'expires_at':row[6]}
        _cleanup(conn,now)
        n,used=conn.execute('SELECT count(*),coalesce(sum(byte_length),0) FROM account_delta_stages WHERE account_id=?',(account,)).fetchone()
        global_count,total=conn.execute('SELECT count(*),coalesce(sum(byte_length),0) FROM account_delta_stages').fetchone()
        if n>=MAX_ACCOUNT_STAGES or used+length>MAX_ACCOUNT_BYTES:
            raise HTTPException(429,'增量暂存配额已满，请等待过期或完成其他操作')
        if global_count>=MAX_GLOBAL_STAGES or total+length>MAX_GLOBAL_BYTES:
            raise HTTPException(503,'服务器增量暂存空间不足，请稍后重试')
        expiry=now+TTL_SECONDS
        conn.execute('''INSERT INTO account_delta_stages(account_id,batch_id,generation,base_revision,restore_epoch,byte_length,part_count,digest,created_at,expires_at,stage_nonce) VALUES(?,?,?,?,?,?,?,?,?,?,?)''',(account,batch,generation,revision,epoch,length,count,digest,now,expiry,secrets.token_hex(16)))
        conn.commit()
        return {'batch_id':batch,'part_bytes':PART_BYTES,'expires_at':expiry}
    except Exception:
        conn.rollback();raise
    finally:
        conn.close()


def put(db,account,batch,index,body):
    if not isinstance(batch,str) or not HEX_ID.fullmatch(batch) or type(index) is not int or index<0:
        raise HTTPException(422,'增量暂存分片标识无效')
    if not isinstance(body,dict) or set(body)!={'data'} or not isinstance(body['data'],str) or len(body['data'])>4*((PART_BYTES+2)//3):
        raise HTTPException(422,'增量暂存分片无效')
    try: data=base64.b64decode(body['data'],validate=True)
    except (ValueError,binascii.Error): raise HTTPException(422,'增量暂存分片编码无效')
    digest=hashlib.sha256(data).hexdigest();now=time.time()
    conn=sqlite3.connect(db,timeout=15)
    try:
        conn.execute('BEGIN IMMEDIATE')
        row=conn.execute('SELECT byte_length,part_count,expires_at FROM account_delta_stages WHERE account_id=? AND batch_id=?',(account,batch)).fetchone()
        if not row: raise HTTPException(404,'增量暂存不存在')
        length,count,expiry=row
        if expiry<=now: raise HTTPException(410,'增量暂存已过期')
        if index>=count: raise HTTPException(416,'增量暂存分片超出范围')
        expected=min(PART_BYTES,length-index*PART_BYTES)
        if len(data)!=expected: raise HTTPException(422,'增量暂存分片长度无效')
        existing=conn.execute('SELECT digest,payload FROM account_delta_stage_parts WHERE account_id=? AND batch_id=? AND part=?',(account,batch,index)).fetchone()
        if existing:
            if existing[0]!=digest or existing[1]!=data: raise HTTPException(409,'增量暂存分片内容不一致')
        else: conn.execute('INSERT INTO account_delta_stage_parts VALUES(?,?,?,?,?)',(account,batch,index,data,digest))
        conn.commit();return {'ok':True,'part':index}
    except Exception:
        conn.rollback();raise
    finally: conn.close()


def assemble(db,account,batch):
    if not isinstance(batch,str) or not HEX_ID.fullmatch(batch): raise HTTPException(422,'增量暂存标识无效')
    conn=sqlite3.connect(db,timeout=15)
    try:
        conn.execute('BEGIN')
        row=conn.execute('''SELECT generation,base_revision,restore_epoch,byte_length,part_count,digest,expires_at,stage_nonce
                            FROM account_delta_stages WHERE account_id=? AND batch_id=?''',(account,batch)).fetchone()
        if not row: raise HTTPException(404,'增量暂存不存在')
        generation,revision,epoch,length,count,digest,expiry,nonce=row
        if expiry<=time.time(): raise HTTPException(410,'增量暂存已过期')
        parts=conn.execute('SELECT part,payload,digest FROM account_delta_stage_parts WHERE account_id=? AND batch_id=? ORDER BY part',(account,batch)).fetchall()
        if len(parts)!=count or any(i!=part[0] or hashlib.sha256(part[1]).hexdigest()!=part[2] for i,part in enumerate(parts)):
            raise HTTPException(409,'增量暂存分片不完整或损坏')
        payload=b''.join(part[1] for part in parts)
        if len(payload)!=length or hashlib.sha256(payload).hexdigest()!=digest: raise HTTPException(409,'增量暂存校验失败')
        conn.commit()
        return {'batch_id':batch,'generation':generation,'base_revision':revision,'restore_epoch':epoch},payload,nonce
    finally: conn.close()


def delete(db,account,batch):
    if not isinstance(batch,str) or not HEX_ID.fullmatch(batch): raise HTTPException(422,'增量暂存标识无效')
    conn=sqlite3.connect(db,timeout=15)
    try:
        conn.execute('BEGIN IMMEDIATE')
        changed=conn.execute('DELETE FROM account_delta_stages WHERE account_id=? AND batch_id=?',(account,batch)).rowcount
        if not changed: raise HTTPException(404,'增量暂存不存在')
        conn.execute('DELETE FROM account_delta_stage_parts WHERE account_id=? AND batch_id=?',(account,batch))
        conn.commit();return {'ok':True}
    except Exception:
        conn.rollback();raise
    finally: conn.close()
