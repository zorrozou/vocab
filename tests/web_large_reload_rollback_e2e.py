#!/usr/bin/env python3
"""Exercise Web large-store reload across an actual stopped-writer DB backup restore."""
import json, os, shutil, socket, subprocess, sys, tempfile, time, urllib.error, urllib.request, uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def port_number():
    with socket.socket() as sock: sock.bind(('127.0.0.1',0));return sock.getsockname()[1]
def request(port,path,method='GET',body=None,token=None):
    headers={'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    req=urllib.request.Request(f'http://127.0.0.1:{port}'+path,None if body is None else json.dumps(body).encode(),headers,method=method)
    with urllib.request.urlopen(req,timeout=15) as response:return json.load(response)
def start(runtime,port,log):
    proc=subprocess.Popen([sys.executable,'-m','uvicorn','app.main:app','--host','127.0.0.1','--port',str(port),'--log-level','warning'],cwd=runtime,stdout=log,stderr=log,env={**os.environ,'VOCAB_EXPERIMENTAL_LARGE_DELTAS':'1'})
    for _ in range(200):
        if proc.poll() is not None:raise RuntimeError(f'fixture exited {proc.returncode}')
        try:
            with urllib.request.urlopen(f'http://127.0.0.1:{port}/api/v1/me/state',timeout=.3):pass
        except urllib.error.HTTPError as e:
            if e.code==401:return proc
        except OSError:pass
        time.sleep(.1)
    proc.terminate();proc.wait(timeout=15);raise RuntimeError('isolated server did not start')
def stop(proc):
    proc.terminate()
    try:proc.wait(timeout=15)
    except subprocess.TimeoutExpired:proc.kill();proc.wait(timeout=5)
    assert proc.returncode in (0,-15),proc.returncode
def backup(*args):
    result=subprocess.run([sys.executable,str(ROOT/'server/backup_state.py'),*map(str,args)],capture_output=True,text=True)
    assert result.returncode==0,(result.stdout,result.stderr)
def browser(mode,port,profile,auth,expect):
    env=os.environ.copy();env.update(VOCAB_TEST_BASE=f'http://127.0.0.1:{port}',VOCAB_TEST_PROFILE=str(profile),VOCAB_TEST_AUTH=str(auth),VOCAB_TEST_EXPECT=str(expect))
    subprocess.run(['node',str(ROOT/'tests/web_large_reload_rollback_e2e.cjs'),mode],env=env,check=True,timeout=120)
with tempfile.TemporaryDirectory(prefix='vocab-normal-rollback-') as directory:
    temp=Path(directory);runtime=temp/'server';runtime.mkdir();(runtime/'data').mkdir();(runtime/'static').mkdir()
    shutil.copytree(ROOT/'server/app',runtime/'app',ignore=shutil.ignore_patterns('__pycache__'))
    shutil.copy2(ROOT/'data/lexicon_v0.1.sqlite',runtime/'data/lexicon_v0.1.sqlite');shutil.copy2(ROOT/'web/index.html',runtime/'static/index.html')
    port=port_number();auth_file=temp/'auth.json';expected=temp/'expected.json';profile=temp/'profile'
    with (temp/'server.log').open('w+') as log:
        proc=start(runtime,port,log)
        try:
            auth=request(port,'/api/v1/auth/register','POST',{'username':'rollback_'+uuid.uuid4().hex[:8],'password':'test_password_123'});auth_file.write_text(json.dumps(auth))
            state={'v':1,'calibrated':True,'frontier':7,'pointer':8,'probeCount':0,'cards':{'apple':{'pos':7,'stage':1,'due':'2099-01-01T00:00:00Z'}},'log':[],'pendingNew':[],'settings':{'newPerDay':0,'dailyCap':10},'streak':0}
            request(port,'/api/v1/me/state','PUT',state,auth['token'])
        finally:stop(proc)
        snapshot=temp/'backup';backup('create','--data',runtime/'data','--output',snapshot,'--writers-stopped')
        proc=start(runtime,port,log)
        try:
            head=request(port,'/api/v1/me/state',token=auth['token']);revision=head['state_revision'];generation=head['sync_generation']
            for index in range(10):
                body={'batch_id':uuid.uuid4().hex,'generation':generation,'base_revision':revision,'restore_epoch':0,
                      'ops':[{'op':'set','path':['cards',f'bulk{index}'],'value':{'pos':100+index,'extra':'x'*(900*1024)}}]}
                revision=request(port,'/api/v1/me/state/experimental-large-deltas','POST',body,auth['token'])['state_revision']
            browser('prepare',port,profile,auth_file,expected)
        finally:stop(proc)
        stage=temp/'stage';backup('restore','--backup',snapshot,'--output',stage)
        restored=temp/'restored';restored.mkdir();shutil.move(str(stage),str(restored/'data'));shutil.copytree(ROOT/'server/app',restored/'app',ignore=shutil.ignore_patterns('__pycache__'));(restored/'static').mkdir();shutil.copy2(ROOT/'web/index.html',restored/'static/index.html')
        proc=start(restored,port,log)
        try:browser('verify',port,profile,auth_file,expected)
        finally:stop(proc)
print('PASS real database backup rollback and large Web reload')
