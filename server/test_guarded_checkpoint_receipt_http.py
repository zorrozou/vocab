#!/usr/bin/env python3
"""Ordinary checkpoint receipts remain atomic with large-state features disabled."""
import json, os, urllib.error, urllib.request, uuid
from concurrent.futures import ThreadPoolExecutor
BASE=os.environ.get('VOCAB_TEST_BASE','http://127.0.0.1:18765').rstrip('/')
def call(path, method='GET', body=None, token=None):
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    req=urllib.request.Request(BASE+path,None if body is None else json.dumps(body).encode(),headers,method=method)
    with urllib.request.urlopen(req,timeout=45) as response: return json.load(response)
def reject(code,path,method='GET',body=None,token=None):
    try: call(path,method,body,token)
    except urllib.error.HTTPError as error: assert error.code==code,(path,error.code,code,error.read());return
    raise AssertionError('unexpected success '+path)
seed=call('/api/v1/__ui_fixture/recovery-case','POST',{}); token=seed['token']
state=call('/api/v1/me/state',token=token); epoch=state['state'].get('restoreEpoch',0)
body={'batch_id':uuid.uuid4().hex,'generation':state['sync_generation'],'base_revision':state['state_revision'],'restore_epoch':epoch}
preview='/api/v1/me/state/guarded-checkpoint-receipt-preview';path='/api/v1/me/state/guarded-checkpoint-idempotent'
cap=call('/api/v1/me/state/delta-capabilities',token=token);assert cap['guarded_checkpoint_receipt_v1'] is True and cap['experimental_large_checkpoint_v1'] is False
assert call(preview,'POST',{k:body[k] for k in ('generation','base_revision','restore_epoch')},token)['ok']
call('/api/v1/__ui_fixture/state-changes-failure','POST',{'enabled':True});reject(500,path,'POST',body,token);call('/api/v1/__ui_fixture/state-changes-failure','POST',{'enabled':False})
assert not call('/api/v1/me/state/backups',token=token)['backups'];assert call('/api/v1/me/state',token=token)['state_revision']==body['base_revision']
with ThreadPoolExecutor(max_workers=3) as pool: results=list(pool.map(lambda _:call(path,'POST',body,token),range(3)))
assert all(x==results[0] for x in results);result=results[0]
assert result['state_revision']==str(int(body['base_revision'])+1) and result['restore_epoch']==epoch+1
assert len(call('/api/v1/me/state/backups',token=token)['backups'])==1
reject(409,path,'POST',{**body,'restore_epoch':epoch+1},token)
reject(422,path,'POST',{**body,'restore_epoch':True},token)
other=call('/api/v1/__ui_fixture/recovery-case','POST',{})['token'];call('/api/v1/__ui_fixture/oversize-stored-state','POST',{'token':other,'size':8*1024*1024+65536})
manifest=call('/api/v1/me/state/snapshots?representation=stored','POST',{},other)
reject(413,preview,'POST',{'generation':manifest['generation'],'base_revision':manifest['state_revision'],'restore_epoch':manifest['restore_epoch']},other)
reject(413,path,'POST',{'batch_id':uuid.uuid4().hex,'generation':manifest['generation'],'base_revision':manifest['state_revision'],'restore_epoch':manifest['restore_epoch']},other)
print('PASS ordinary checkpoint receipt retry, rollback, validation and 8 MiB bound')
