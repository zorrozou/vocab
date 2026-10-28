#!/usr/bin/env python3
"""An actual backup restore fences a cursor whose revision happens to match."""
import json, os, shutil, socket, subprocess, sys, tempfile, time, urllib.error, urllib.request, uuid
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
def port_number():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0)); return sock.getsockname()[1]
def request(port,path,method='GET',body=None,token=None):
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    req=urllib.request.Request(f'http://127.0.0.1:{port}'+path,None if body is None else json.dumps(body).encode(),headers,method=method)
    with urllib.request.urlopen(req,timeout=10) as response: return json.load(response)
def start(runtime,port,log):
    proc=subprocess.Popen([sys.executable,'-m','uvicorn','app.main:app','--host','127.0.0.1','--port',str(port),'--log-level','warning'],cwd=runtime,stdout=log,stderr=log)
    for _ in range(150):
        if proc.poll() is not None: raise RuntimeError(f'fixture exited {proc.returncode}')
        try:
            with urllib.request.urlopen(f'http://127.0.0.1:{port}/api/v1/me/state',timeout=.3): pass
        except urllib.error.HTTPError as error:
            if error.code==401: return proc
        except OSError: pass
        time.sleep(.1)
    proc.terminate(); proc.wait(timeout=10)
    raise RuntimeError('fixture did not start')
def stop(proc):
    proc.terminate()
    try: proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill(); proc.wait(timeout=5)
    assert proc.returncode in (0,-15), proc.returncode
def backup(*args):
    result=subprocess.run([sys.executable,str(ROOT/'server/backup_state.py'),*map(str,args)],capture_output=True,text=True)
    assert result.returncode==0, (result.stdout,result.stderr)

with tempfile.TemporaryDirectory(prefix='vocab-generation-restore-') as directory:
    root=Path(directory); runtime=root/'server'; runtime.mkdir(); (runtime/'data').mkdir(); (runtime/'static').mkdir()
    shutil.copytree(ROOT/'server/app',runtime/'app',ignore=shutil.ignore_patterns('__pycache__'))
    shutil.copy2(ROOT/'data/lexicon_v0.1.sqlite',runtime/'data/lexicon_v0.1.sqlite')
    shutil.copy2(ROOT/'web/index.html',runtime/'static/index.html')
    port=port_number()
    with (root/'server.log').open('w+') as log:
        proc=start(runtime,port,log)
        try:
            auth=request(port,'/api/v1/auth/register','POST',{'username':'rollback_'+uuid.uuid4().hex[:8],'password':'test_password_123'})
            token=auth['token']; state={'v':1,'cards':{'apple':{'pos':1}},'log':[],'pendingNew':[],'settings':{}}
            request(port,'/api/v1/me/state','PUT',state,token)
            snap=request(port,'/api/v1/me/state/snapshots?representation=stored','POST',{},token)
            old_generation=snap['generation']; revision=snap['state_revision']
            old_view=request(port,'/api/v1/me/state',token=token)
            assert old_view['sync_generation']==old_generation
        finally: stop(proc)
        snapshot=root/'backup'; backup('create','--data',runtime/'data','--output',snapshot,'--writers-stopped')
        proc=start(runtime,port,log)
        try:
            state['cards']['banana']={'pos':2}
            later=request(port,'/api/v1/me/state','PUT',state,token)
            assert int(later['state_revision']) > int(revision)
        finally: stop(proc)
        stage=root/'stage'; backup('restore','--backup',snapshot,'--output',stage)
        restored=root/'restored'; restored.mkdir(); shutil.move(str(stage),str(restored/'data'))
        shutil.copytree(ROOT/'server/app',restored/'app',ignore=shutil.ignore_patterns('__pycache__'))
        (restored/'static').mkdir(); shutil.copy2(ROOT/'web/index.html',restored/'static/index.html')
        proc=start(restored,port,log)
        try:
            restored_state=request(port,'/api/v1/me/state',token=token)
            assert restored_state['state_revision']==revision and set(restored_state['state']['cards'])=={'apple'}
            assert restored_state['sync_generation']!=old_generation
            assert restored_state['updated_at']==old_view['updated_at']
            for endpoint, extra in (('guarded-restore', {'state':state}), ('guarded-checkpoint', {})):
                body={'expected_updated_at':old_view['updated_at'], 'generation':old_generation, 'state_revision':revision, **extra}
                try: request(port,'/api/v1/me/state/'+endpoint,'POST',body,token)
                except urllib.error.HTTPError as error: assert error.code==409
                else: raise AssertionError('old preview accepted at equal revision and timestamp')
                body['generation']=restored_state['sync_generation']; body['state_revision']=str(int(revision)+1)
                try: request(port,'/api/v1/me/state/'+endpoint,'POST',body,token)
                except urllib.error.HTTPError as error: assert error.code==409
                else: raise AssertionError('wrong revision accepted')
            unchanged=request(port,'/api/v1/me/state',token=token)
            assert unchanged['state_revision']==revision and unchanged['state']==restored_state['state']
            try: request(port,f'/api/v1/me/state/changes?after={revision}&generation={old_generation}',token=token)
            except urllib.error.HTTPError as error: assert error.code==409
            else: raise AssertionError('old generation accepted at an equal revision')
            try: request(port,'/api/v1/me/state/snapshots/'+snap['snapshot_id']+'?page=0',token=token)
            except urllib.error.HTTPError as error: assert error.code==404
            else: raise AssertionError('old snapshot survived restoration')
            new=request(port,'/api/v1/me/state/snapshots?representation=stored','POST',{},token)
            assert new['generation']!=old_generation and new['state_revision']==revision
            checkpoint=request(port,'/api/v1/me/state/guarded-checkpoint','POST',{'expected_updated_at':restored_state['updated_at'],
                'generation':restored_state['sync_generation'],'state_revision':revision},token)
            recovered=request(port,'/api/v1/me/state/guarded-restore','POST',{'state':state,'expected_updated_at':checkpoint['updated_at'],
                'generation':restored_state['sync_generation'],'state_revision':checkpoint['state_revision']},token)
            assert recovered['state']['cards'].keys() >= {'apple','banana'}
        finally: stop(proc)
print('PASS offline backup restore and server restart fence equal-revision old cursors')
