"""Run a disposable UI fixture without touching the project's databases."""
import asyncio, json, os, shutil, signal, sqlite3, sys, tempfile, threading, uuid
from pathlib import Path
root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='vocab-ui-server-') as directory:
    isolated = Path(directory)
    shutil.copytree(root / 'server' / 'app', isolated / 'app', ignore=shutil.ignore_patterns('__pycache__'))
    (isolated / 'data').mkdir()
    (isolated / 'static').mkdir()
    shutil.copy2(root / 'data' / 'lexicon_v0.1.sqlite', isolated / 'data' / 'lexicon_v0.1.sqlite')
    shutil.copy2(root / 'web' / 'index.html', isolated / 'static' / 'index.html')
    sys.path.insert(0, str(isolated))
    from app import main
    import uvicorn
    main.llm = lambda prompt: 'Apple is on the table. || 苹果在桌上。'
    main.validate_multi = lambda *args: None
    main.quality_check = lambda *args: 5
    main.ensure_tts = lambda *args: True
    from fastapi import Header, Request
    from fastapi.responses import JSONResponse, PlainTextResponse
    from app import auth
    scheduler_resolve_gate = threading.Event()
    scheduler_resolve_started = threading.Event()
    scheduler_resolve_control = {'hold':False}
    original_scheduler_loader = auth.load_owned_scheduler_versions
    def held_scheduler_loader(account_id, keys):
        if scheduler_resolve_control['hold']:
            scheduler_resolve_started.set()
            if not scheduler_resolve_gate.wait(20):
                raise RuntimeError('fixture scheduler gate timed out')
        return original_scheduler_loader(account_id, keys)
    auth.load_owned_scheduler_versions = held_scheduler_loader
    delta_stage_gate = threading.Event()
    delta_stage_started = threading.Event()
    delta_stage_control = {'batch_id':None}
    original_stage_assemble = auth.delta_staging.assemble
    def held_stage_assemble(db, account, batch):
        result = original_stage_assemble(db, account, batch)
        if delta_stage_control['batch_id'] == batch:
            delta_stage_started.set()
            if not delta_stage_gate.wait(20): raise RuntimeError('fixture delta stage gate timed out')
        return result
    auth.delta_staging.assemble = held_stage_assemble
    fixture = {'fsrs_offline': False, 'fixed_quiz': False, 'personal_offline': False, 'fsrs_delay': 0, 'fsrs_attempts': 0, 'fsrs_failures': 0, 'fsrs_successes': 0, 'sync_failures': 0, 'lexicon_delay': 0, 'lexicon_attempts': 0, 'lexicon_hold': False, 'lexicon_completed': 0, 'lexicon_fail_page': 0, 'fsrs_hold': False, 'fsrs_completed': 0, 'meaning_mode': 'normal', 'state_upload_mode': 'normal', 'state_upload_attempts': 0, 'state_get_hold': False, 'state_get_attempts': 0, 'state_get_completed': 0, 'disk_test_state': 'idle'}
    fixture['snapshot_corrupt_page'] = None
    fixture['change_corrupt_page'] = None
    fixture['delta_upload_attempts'] = 0
    fixture['delta_upload_successes'] = 0
    fixture['delta_stage_successes'] = 0
    fixture['snapshots_disabled'] = False
    fixture['scheduler_backup_oversize'] = False
    fixture['scheduler_resolve_attempts'] = 0
    interop = {}
    offline_account = {}
    lexicon_release = asyncio.Event()
    fsrs_release = asyncio.Event()
    state_get_release = asyncio.Event()
    state_expired_release = asyncio.Event()
    snapshot_page_release = asyncio.Event()
    snapshot_page_started = asyncio.Event()
    delta_response_release = asyncio.Event()
    delta_response_started = asyncio.Event()
    mutation_response_release = asyncio.Event()
    mutation_response_started = asyncio.Event()
    fixture['mutation_hold_response'] = None
    fixture['snapshot_hold_page'] = None
    fixture['scheduler_enrichment_failure'] = False
    fixture['scheduler_enrichment_padding'] = 0
    original_scheduler_enrichment = auth.enrich_fsrs_schedulers
    def injected_scheduler_enrichment(state, account_id):
        if fixture['scheduler_enrichment_failure']: raise RuntimeError('fixture scheduler enrichment failure')
        result = original_scheduler_enrichment(state, account_id)
        return {**result, 'fixtureEnrichment':'x'*fixture['scheduler_enrichment_padding']} if fixture['scheduler_enrichment_padding'] else result
    auth.enrich_fsrs_schedulers = injected_scheduler_enrichment
    fixture['delta_hold_response'] = False
    fixture['delta_held_error'] = False
    fixture['delta_stages_disabled'] = False
    fixture['delta_capabilities_disabled'] = False
    fixture['checkpoint_write_failure'] = False
    fixture['large_restore_write_failure'] = False
    fixture['delta_stage_legacy_cap'] = False
    fixture['guarded_merge_successes'] = 0

    @main.app.middleware('http')
    async def fixture_controls(request: Request, call_next):
        if request.method == 'POST' and request.url.path == '/api/v1/me/state/experimental-large-checkpoint' and fixture['checkpoint_write_failure']:
            return JSONResponse({'detail':'injected checkpoint failure'}, status_code=503)
        if request.method == 'POST' and request.url.path.startswith('/api/v1/me/state/delta-stages/') and request.url.path.endswith('/experimental-large-restore') and fixture['large_restore_write_failure']:
            return JSONResponse({'detail':'injected large restore failure'}, status_code=503)
        if request.method == 'GET' and request.url.path == '/api/v1/me/state/delta-capabilities' and fixture['delta_capabilities_disabled']:
            return JSONResponse({'detail':'not found'}, status_code=404)
        if request.method == 'POST' and request.url.path == '/api/v1/me/fsrs-schedulers/resolve':
            fixture['scheduler_resolve_attempts'] += 1
        if request.method == 'GET' and request.url.path == '/api/v1/me/fsrs-schedulers' and fixture['scheduler_backup_oversize']:
            return JSONResponse({'detail':'test fixture: too many scheduler versions'}, status_code=413)
        if request.method == 'POST' and request.url.path == '/api/v1/me/state/delta-stages' and fixture['delta_stages_disabled']:
            return JSONResponse({'detail':'not found'}, status_code=404)
        if request.method == 'POST' and request.url.path == '/api/v1/me/state/snapshots' and fixture['snapshots_disabled']:
            return JSONResponse({'detail':'not found'}, status_code=404)
        if (request.method == 'GET' and request.url.path.startswith('/api/v1/me/state/snapshots/')
                and fixture['snapshot_hold_page'] == request.query_params.get('page')):
            fixture['snapshot_hold_page'] = None
            snapshot_page_started.set()
            await snapshot_page_release.wait()
        is_held_lexicon = request.url.path == '/api/v1/lexicon/at' and fixture['lexicon_hold']
        tracked_lexicon = request.url.path == '/api/v1/lexicon/at' and (is_held_lexicon or fixture['lexicon_delay'] or fixture['lexicon_fail_page'])
        if tracked_lexicon:
            fixture['lexicon_attempts'] += 1
            if fixture['lexicon_fail_page'] == fixture['lexicon_attempts']:
                return JSONResponse({'detail': 'test fixture: lexicon unavailable'}, status_code=503)
            if is_held_lexicon:
                await lexicon_release.wait()
            elif fixture['lexicon_delay']:
                await asyncio.sleep(fixture['lexicon_delay'])
        if request.url.path == '/api/v1/fsrs/review':
            fixture['fsrs_attempts'] += 1
            if fixture['fsrs_hold']:
                await fsrs_release.wait()
            elif fixture['fsrs_delay']:
                await asyncio.sleep(fixture['fsrs_delay'])
        if request.url.path == '/api/v1/lexicon/word':
            mode = fixture['meaning_mode']
            if mode == 'offline':
                return JSONResponse({'detail': 'test fixture: meaning unavailable'}, status_code=503)
            if mode == 'wrong':
                return JSONResponse({'word':'apple', 'pos':1, 'senses':[{'pos':'n', 'text':'wrong meaning'}]})
            if mode == 'empty':
                return JSONResponse({'word':'pear', 'pos':1, 'senses':[]})
        if request.url.path == '/api/v1/personalize' and fixture['personal_offline']:
            return JSONResponse({'detail': 'test fixture: personalization unavailable'}, status_code=503)
        held_state_get = request.url.path == '/api/v1/me/state' and request.method == 'GET' and fixture['state_get_hold']
        if held_state_get:
            fixture['state_get_attempts'] += 1
            if fixture.get('state_get_hold_once'):
                fixture['state_get_hold'] = False
            await state_get_release.wait()
        state_upload = ((request.url.path == '/api/v1/me/state' and request.method == 'PUT') or
                        (request.url.path in ('/api/v1/me/state/deltas', '/api/v1/me/state/guarded-merge') and request.method == 'POST'))
        if state_upload:
            fixture['state_upload_attempts'] += 1
            if request.url.path == '/api/v1/me/state/deltas': fixture['delta_upload_attempts'] += 1
            if fixture['state_upload_mode'] == 'oversize':
                return PlainTextResponse('Request Entity Too Large', status_code=413)
            if fixture['state_upload_mode'] == 'conflict':
                return JSONResponse({'detail':'事件 401 已过期'}, status_code=409)
            if fixture['state_upload_mode'] == 'expired-hold':
                await state_expired_release.wait()
                return JSONResponse({'detail':'登录已过期'}, status_code=401)
        if state_upload and fixture['fsrs_offline']:
            fixture['sync_failures'] += 1
            return JSONResponse({'detail': 'test fixture: sync unavailable'}, status_code=503)
        if request.url.path == '/api/v1/fsrs/review' and fixture['fsrs_offline']:
            fixture['fsrs_failures'] += 1
            return JSONResponse({'detail': 'test fixture: FSRS unavailable'}, status_code=503)
        if request.url.path == '/api/v1/quiz' and fixture['fixed_quiz']:
            return JSONResponse({'word':'apple','pos':main.POS_OF[main.WORD2ID['apple']], 'mode':'forward',
                'options':[{'text':'correct fixture answer','ok':True}, {'text':'wrong one','ok':False},
                           {'text':'wrong two','ok':False}, {'text':'wrong three','ok':False}]})
        response = await call_next(request)
        if request.method == 'POST' and request.url.path == fixture['mutation_hold_response'] and response.status_code == 200:
            fixture['mutation_hold_response'] = None
            mutation_response_started.set()
            await mutation_response_release.wait()
        if request.method == 'POST' and request.url.path == '/api/v1/me/state/delta-stages' and fixture['delta_stage_legacy_cap'] and response.status_code == 200:
            raw = b''.join([chunk async for chunk in response.body_iterator])
            body = json.loads(raw); body.pop('max_operations', None)
            return JSONResponse(body, headers={'Cache-Control':'no-store'})
        if request.method == 'POST' and request.url.path == '/api/v1/me/state/guarded-merge' and response.status_code == 200:
            fixture['guarded_merge_successes'] += 1
        if request.method == 'POST' and request.url.path == '/api/v1/me/state/deltas' and response.status_code == 200:
            fixture['delta_upload_successes'] += 1
        if request.method == 'POST' and request.url.path.startswith('/api/v1/me/state/delta-stages/') and request.url.path.endswith('/commit') and response.status_code == 200:
            fixture['delta_stage_successes'] += 1
        if request.method == 'POST' and (request.url.path in ('/api/v1/me/state/deltas', '/api/v1/me/state/experimental-large-deltas', '/api/v1/me/state/experimental-large-checkpoint', '/api/v1/me/state/experimental-large-checkpoint-cancel', '/api/v1/me/state/experimental-large-restore-cancel') or (request.url.path.startswith('/api/v1/me/state/delta-stages/') and request.url.path.endswith(('/commit','/experimental-large-commit','/experimental-large-restore')))) and response.status_code == 200 and fixture['delta_hold_response']:
            fixture['delta_hold_response'] = False
            delta_response_started.set()
            await delta_response_release.wait()
            if fixture['delta_held_error']:
                fixture['delta_held_error'] = False
                return JSONResponse({'detail':'old session rejected'}, status_code=401)
        if (request.method == 'GET' and request.url.path.startswith('/api/v1/me/state/snapshots/')
                and response.status_code == 200 and fixture['snapshot_corrupt_page'] == request.query_params.get('page')):
            fixture['snapshot_corrupt_page'] = None
            body = b''.join([part async for part in response.body_iterator])
            value = json.loads(body)
            value['data'] = ('B' if value['data'][0] == 'A' else 'A') + value['data'][1:]
            return JSONResponse(value)
        if (request.method == 'GET' and request.url.path == '/api/v1/me/state/changes'
                and response.status_code == 200 and fixture['change_corrupt_page'] == request.query_params.get('page', '0')):
            fixture['change_corrupt_page'] = None
            body = b''.join([part async for part in response.body_iterator])
            value = json.loads(body)
            if value.get('change'):
                chunk = value['change']['data']
                value['change']['data'] = ('B' if chunk[0] == 'A' else 'A') + chunk[1:]
            return JSONResponse(value)
        if is_held_lexicon:
            fixture['lexicon_completed'] += 1
        if held_state_get:
            fixture['state_get_completed'] += 1
        if request.url.path == '/api/v1/fsrs/review':
            fixture['fsrs_completed'] += 1
            if response.status_code == 200:
                fixture['fsrs_successes'] += 1
        return response

    @main.app.post('/api/v1/__ui_fixture/snapshot-expire')
    def expire_test_snapshot(body: dict):
        identity = auth.identity_by_token('Bearer ' + body.get('token', ''))
        if not identity:
            return JSONResponse({'detail':'invalid fixture account'}, status_code=401)
        with sqlite3.connect(auth.USERS_DB) as db:
            changed = db.execute('UPDATE account_state_snapshots SET expires_at=0 WHERE snapshot_id=? AND account_id=?', (body.get('snapshot_id'), identity[1])).rowcount
        if changed != 1:
            return JSONResponse({'detail':'snapshot missing'}, status_code=404)
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/snapshots-disabled')
    def snapshots_disabled(body: dict):
        fixture['snapshots_disabled'] = body.get('disabled') is True
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/delta-receipt-expire')
    def expire_delta_receipt(body: dict):
        identity = auth.identity_by_token('Bearer ' + body.get('token', ''))
        if not identity:
            return JSONResponse({'detail':'invalid fixture account'}, status_code=401)
        with sqlite3.connect(auth.USERS_DB) as db:
            changed = db.execute('UPDATE account_state_batches SET created_at=0 WHERE account_id=? AND batch_id=?', (identity[1], body.get('batch_id'))).rowcount
        return {'changed':changed}

    @main.app.post('/api/v1/__ui_fixture/restore-receipt-expire')
    def expire_restore_receipt(body: dict):
        import time
        identity = auth.identity_by_token('Bearer ' + body.get('token', ''))
        if not identity:
            return JSONResponse({'detail':'invalid fixture account'}, status_code=401)
        with sqlite3.connect(auth.USERS_DB) as db:
            changed = db.execute('UPDATE account_restore_receipts SET created_at=? WHERE account_id=? AND batch_id=?',
                                 (time.time() if body.get('restore') is True else 0, identity[1], body.get('batch_id'))).rowcount
        return {'changed':changed}

    @main.app.post('/api/v1/__ui_fixture/delta-stage-legacy-cap')
    def legacy_delta_stage_cap(body: dict):
        fixture['delta_stage_legacy_cap'] = body.get('enabled') is True
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/scheduler-enrichment-padding')
    def set_scheduler_enrichment_padding(body: dict):
        size = body.get('size')
        if type(size) is not int or not 0 <= size <= 8*1024*1024:
            return JSONResponse({'detail':'invalid padding'}, status_code=422)
        fixture['scheduler_enrichment_padding'] = size
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/scheduler-enrichment-failure')
    def set_scheduler_enrichment_failure(body: dict):
        fixture['scheduler_enrichment_failure'] = body.get('enabled') is True
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/delta-stages-disabled')
    def disable_delta_stages(body: dict):
        fixture['delta_stages_disabled'] = body.get('disabled') is True
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/delta-capabilities-disabled')
    def disable_delta_capabilities(body: dict):
        fixture['delta_capabilities_disabled'] = body.get('disabled') is True
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/checkpoint-write-failure')
    def checkpoint_write_failure(body: dict):
        fixture['checkpoint_write_failure'] = body.get('enabled') is True
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/large-restore-write-failure')
    def large_restore_write_failure(body: dict):
        fixture['large_restore_write_failure'] = body.get('enabled') is True
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/delta-hold-response')
    async def hold_delta_response():
        delta_response_release.clear(); delta_response_started.clear(); fixture['delta_hold_response'] = True
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/mutation-hold-response')
    async def hold_mutation_response(body: dict):
        mode = body.get('mode')
        if mode not in ('restore', 'checkpoint'):
            return JSONResponse({'detail':'invalid mode'}, status_code=422)
        mutation_response_release.clear(); mutation_response_started.clear()
        fixture['mutation_hold_response'] = '/api/v1/me/state/guarded-' + mode
        return {'ok':True}

    @main.app.get('/api/v1/__ui_fixture/mutation-hold-status')
    async def mutation_hold_status():
        return {'started':mutation_response_started.is_set()}

    @main.app.post('/api/v1/__ui_fixture/mutation-release-response')
    async def release_mutation_response():
        mutation_response_release.set()
        return {'ok':True}

    @main.app.get('/api/v1/__ui_fixture/delta-hold-status')
    async def delta_hold_status():
        return {'started':delta_response_started.is_set()}

    @main.app.post('/api/v1/__ui_fixture/delta-held-error')
    def delta_held_error():
        fixture['delta_held_error'] = True
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/delta-release-response')
    async def release_delta_response():
        delta_response_release.set()
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/delta-receipt-limit')
    def test_delta_receipt_limit(body: dict):
        limit=body.get('limit')
        if type(limit) is not int or not 1 <= limit <= 256:
            return JSONResponse({'detail':'invalid limit'}, status_code=400)
        auth.DELTA_MAX_RECEIPTS=limit
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/scheduler-delete')
    def delete_test_scheduler(body: dict):
        identity = auth.identity_by_token('Bearer ' + body.get('token', ''))
        if not identity:
            return JSONResponse({'detail':'invalid fixture account'}, status_code=401)
        with sqlite3.connect(main.PERSONAL_DB) as db:
            changed = db.execute('DELETE FROM fsrs_scheduler_versions WHERE owner=? AND scheduler_key=?', ('account:' + identity[1], body.get('key'))).rowcount
        return {'deleted':changed}

    @main.app.post('/api/v1/__ui_fixture/scheduler-backup-oversize')
    def scheduler_backup_oversize(body: dict):
        fixture['scheduler_backup_oversize'] = body.get('enabled') is True
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/scheduler-corrupt')
    def corrupt_test_scheduler(body: dict):
        identity = auth.identity_by_token('Bearer ' + body.get('token', ''))
        if not identity:
            return JSONResponse({'detail':'invalid fixture account'}, status_code=401)
        with sqlite3.connect(main.PERSONAL_DB) as db:
            changed = db.execute("UPDATE fsrs_scheduler_versions SET config_json='{}' WHERE owner=? AND scheduler_key=?", ('account:' + identity[1], body.get('key'))).rowcount
        return {'changed':changed}

    @main.app.post('/api/v1/__ui_fixture/scheduler-resolve-hold')
    def hold_scheduler_resolve():
        scheduler_resolve_gate.clear(); scheduler_resolve_started.clear(); scheduler_resolve_control['hold']=True
        return {'ok':True}

    @main.app.get('/api/v1/__ui_fixture/scheduler-resolve-status')
    def scheduler_resolve_status():
        return {'started':scheduler_resolve_started.is_set(), 'attempts':fixture['scheduler_resolve_attempts']}

    @main.app.post('/api/v1/__ui_fixture/scheduler-resolve-release')
    def release_scheduler_resolve():
        scheduler_resolve_control['hold']=False; scheduler_resolve_gate.set()
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/snapshot-limits')
    def test_snapshot_limits(body: dict):
        # This fixture runs only with disposable databases on loopback.
        for name, attr in (('max_bytes', 'SNAPSHOT_MAX_BYTES'), ('global_bytes', 'SNAPSHOT_GLOBAL_BYTES'), ('max_keys', 'SNAPSHOT_MAX_KEYS_PER_ACCOUNT')):
            if name in body:
                value = body[name]
                if type(value) is not int or not 0 <= value <= 128 * 1024 * 1024:
                    return JSONResponse({'detail':'invalid limit'}, status_code=400)
                setattr(auth, attr, value)
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/snapshot-count')
    def count_test_snapshot(body: dict):
        identity = auth.identity_by_token('Bearer ' + body.get('token', ''))
        if not identity:
            return JSONResponse({'detail':'invalid fixture account'}, status_code=401)
        with sqlite3.connect(auth.USERS_DB) as db:
            count = db.execute('SELECT count(*) FROM account_state_snapshots WHERE account_id=?', (identity[1],)).fetchone()[0]
            active = db.execute('SELECT count(*) FROM account_state_snapshots WHERE account_id=? AND retired=0', (identity[1],)).fetchone()[0]
        return {'count':count, 'active_count':active}

    @main.app.post('/api/v1/__ui_fixture/snapshot-corrupt-page')
    def corrupt_snapshot_page(body: dict):
        page = body.get('page')
        if type(page) is not int or page < 0 or page > 1024:
            return JSONResponse({'detail':'invalid page'}, status_code=400)
        fixture['snapshot_corrupt_page'] = str(page)
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/change-corrupt-page')
    def corrupt_change_page(body: dict):
        page = body.get('page')
        if type(page) is not int or not 0 <= page <= 1024:
            return JSONResponse({'detail':'invalid page'}, status_code=400)
        fixture['change_corrupt_page'] = str(page)
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/snapshot-hold-page')
    async def hold_snapshot_page(body: dict):
        page = body.get('page')
        if type(page) is not int or not 0 <= page <= 1024:
            return JSONResponse({'detail':'invalid page'}, status_code=400)
        snapshot_page_release.clear(); snapshot_page_started.clear()
        fixture['snapshot_hold_page'] = str(page)
        return {'ok':True}

    @main.app.get('/api/v1/__ui_fixture/snapshot-hold-status')
    async def snapshot_hold_status():
        return {'started':snapshot_page_started.is_set()}

    @main.app.post('/api/v1/__ui_fixture/snapshot-release-page')
    async def release_snapshot_page():
        snapshot_page_release.set()
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/state-changes')
    def test_state_changes(body: dict):
        import base64
        identity = auth.identity_by_token('Bearer ' + body.get('token', ''))
        if not identity:
            return JSONResponse({'detail':'invalid fixture account'}, status_code=401)
        with sqlite3.connect(auth.USERS_DB) as db:
            rows = db.execute('SELECT revision,base_revision,restore_epoch,reset,payload,digest FROM account_state_changes WHERE account_id=? ORDER BY revision', (identity[1],)).fetchall()
        return {'changes':[{'revision':str(rev), 'base_revision':str(base), 'epoch':epoch, 'reset':bool(reset), 'payload':base64.b64encode(payload).decode(), 'sha256':digest} for rev,base,epoch,reset,payload,digest in rows]}

    @main.app.post('/api/v1/__ui_fixture/state-changes-byte-limit')
    def change_journal_limit(body: dict):
        from app import state_changes
        limit = body.get('limit')
        if type(limit) is not int or not 256 <= limit <= 16 * 1024 * 1024:
            return JSONResponse({'detail':'invalid fixture limit'}, status_code=422)
        state_changes.MAX_ACCOUNT_BYTES = limit
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/experimental-large-deltas')
    def experimental_large_deltas(body: dict):
        if body.get('enabled') is True: os.environ['VOCAB_EXPERIMENTAL_LARGE_DELTAS'] = '1'
        else: os.environ.pop('VOCAB_EXPERIMENTAL_LARGE_DELTAS', None)
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/oversize-stored-state')
    def inject_oversize_stored_state(body: dict):
        import time
        identity = auth.identity_by_token('Bearer ' + body.get('token', ''))
        size = body.get('size')
        if not identity or type(size) is not int or not 8*1024*1024 < size <= 10*1024*1024:
            return JSONResponse({'detail':'invalid fixture request'}, status_code=422)
        with sqlite3.connect(auth.USERS_DB, timeout=15) as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT state_json,updated_at,state_revision FROM account_state WHERE account_id=?',(identity[1],)).fetchone()
            if not row:
                return JSONResponse({'detail':'fixture state missing'}, status_code=404)
            old = json.loads(row[0]); state = dict(old); state['fixtureLarge'] = 'x' * size
            stamp = max(time.time(), row[1] + 0.000001); revision = auth.next_state_revision(row[2])
            raw = json.dumps(state, ensure_ascii=False, separators=(',',':'), allow_nan=False)
            db.execute('UPDATE account_state SET state_json=?,updated_at=?,state_revision=? WHERE account_id=?',(raw,stamp,revision,identity[1]))
            auth.record_change(db, identity[1], row[2], revision, state.get('restoreEpoch', 0), old, state, stamp)
        return {'revision':str(revision)}

    @main.app.post('/api/v1/__ui_fixture/escaped-stored-state')
    def inject_escaped_stored_state(body: dict):
        import time
        identity = auth.identity_by_token('Bearer ' + body.get('token', ''))
        if not identity: return JSONResponse({'detail':'invalid fixture account'}, status_code=401)
        with sqlite3.connect(auth.USERS_DB, timeout=15) as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT state_json,updated_at,state_revision FROM account_state WHERE account_id=?',(identity[1],)).fetchone()
            if not row: return JSONResponse({'detail':'fixture state missing'}, status_code=404)
            old = json.loads(row[0]); state = dict(old); state['fixtureLarge'] = '词' * 1_450_000
            raw = json.dumps(state, ensure_ascii=True)
            stamp = max(time.time(), row[1] + 0.000001); revision = auth.next_state_revision(row[2])
            db.execute('UPDATE account_state SET state_json=?,updated_at=?,state_revision=? WHERE account_id=?',(raw,stamp,revision,identity[1]))
            auth.record_change(db, identity[1], row[2], revision, state.get('restoreEpoch', 0), old, state, stamp)
        return {'physical_bytes':len(raw.encode('utf-8')), 'revision':str(revision)}

    @main.app.post('/api/v1/__ui_fixture/state-segment-action')
    def test_state_segment_action(body: dict):
        import hashlib
        identity = auth.identity_by_token('Bearer ' + body.get('token', ''))
        if not identity: return JSONResponse({'detail':'invalid fixture account'}, status_code=401)
        mode = body.get('mode')
        with sqlite3.connect(auth.USERS_DB, timeout=15) as db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT state_json,state_revision,segments_version FROM account_state WHERE account_id=?',(identity[1],)).fetchone()
            if not row: return JSONResponse({'detail':'fixture state missing'}, status_code=404)
            if mode == 'corrupt':
                db.execute('DELETE FROM account_state_segment_meta WHERE account_id=?',(identity[1],))
            elif mode == 'corrupt-item':
                db.execute("UPDATE account_state_segment_items SET value_json='null' WHERE rowid=(SELECT rowid FROM account_state_segment_items WHERE account_id=? LIMIT 1)", (identity[1],))
            elif mode == 'stale':
                db.execute('UPDATE account_state SET state_revision=state_revision+1 WHERE account_id=?',(identity[1],))
            elif mode == 'repair':
                auth.state_segments.write(db, identity[1], row[1], json.loads(row[0]), force=True)
            elif mode == 'trigger':
                db.execute('DROP TRIGGER IF EXISTS fixture_fail_segment')
                if body.get('enabled') is True:
                    db.execute("CREATE TRIGGER fixture_fail_segment BEFORE INSERT ON account_state_segment_items BEGIN SELECT RAISE(ABORT, 'fixture segment write failure'); END")
            elif mode == 'guard-unchanged':
                db.execute('DROP TRIGGER IF EXISTS fixture_guard_segment_update')
                db.execute('DROP TRIGGER IF EXISTS fixture_guard_segment_delete')
                if body.get('enabled') is True:
                    db.execute("CREATE TRIGGER fixture_guard_segment_update BEFORE UPDATE ON account_state_segment_items WHEN OLD.item_key='apple' BEGIN SELECT RAISE(ABORT, 'unchanged item rewritten'); END")
                    db.execute("CREATE TRIGGER fixture_guard_segment_delete BEFORE DELETE ON account_state_segment_items WHEN OLD.item_key='apple' BEGIN SELECT RAISE(ABORT, 'unchanged item deleted'); END")
            elif mode != 'info': return JSONResponse({'detail':'invalid mode'}, status_code=422)
            current = db.execute('SELECT state_json,state_revision,segments_version FROM account_state WHERE account_id=?',(identity[1],)).fetchone()
            count = db.execute('SELECT count(*) FROM account_state_segment_items WHERE account_id=?',(identity[1],)).fetchone()[0]
            return {'revision':str(current[1]),'version':current[2],'items':count,'mirror_sha256':hashlib.sha256(current[0].encode()).hexdigest()}

    @main.app.post('/api/v1/__ui_fixture/state-changes-prune')
    def prune_state_changes(body: dict):
        identity = auth.identity_by_token('Bearer ' + body.get('token', ''))
        if not identity:
            return JSONResponse({'detail':'invalid fixture account'}, status_code=401)
        with sqlite3.connect(auth.USERS_DB) as db:
            db.execute('DELETE FROM account_state_changes WHERE account_id=?', (identity[1],))
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/state-changes-failure')
    def test_state_change_failure(body: dict):
        with sqlite3.connect(auth.USERS_DB) as db:
            db.execute('DROP TRIGGER IF EXISTS fixture_fail_change')
            if body.get('enabled') is True:
                db.execute("CREATE TRIGGER fixture_fail_change BEFORE INSERT ON account_state_changes BEGIN SELECT RAISE(ABORT, 'fixture journal write failure'); END")
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/guarded-restore-receipt-failure')
    def test_guarded_restore_receipt_failure(body: dict):
        with sqlite3.connect(auth.USERS_DB) as db:
            db.execute('DROP TRIGGER IF EXISTS fixture_fail_guarded_restore_receipt')
            if body.get('enabled') is True:
                db.execute("CREATE TRIGGER fixture_fail_guarded_restore_receipt BEFORE INSERT ON account_guarded_restore_receipts BEGIN SELECT RAISE(ABORT, 'fixture receipt write failure'); END")
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/corrupt-guarded-restore-receipt')
    def corrupt_guarded_restore_receipt(body: dict):
        identity = auth.identity_by_token('Bearer ' + body.get('token', ''))
        if not identity: return JSONResponse({'detail':'invalid fixture account'}, status_code=401)
        with sqlite3.connect(auth.USERS_DB) as db:
            db.execute("UPDATE account_guarded_restore_receipts SET state_json='{}' WHERE account_id=? AND batch_id=?", (identity[1],body.get('batch_id')))
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/delta-stage-hold')
    def hold_delta_stage(body: dict):
        delta_stage_gate.clear(); delta_stage_started.clear()
        delta_stage_control['batch_id'] = body.get('batch_id')
        return {'ok':True}

    @main.app.get('/api/v1/__ui_fixture/delta-stage-hold')
    def delta_stage_hold_status():
        return {'started':delta_stage_started.is_set()}

    @main.app.post('/api/v1/__ui_fixture/delta-stage-release')
    def release_delta_stage():
        delta_stage_control['batch_id'] = None
        delta_stage_gate.set()
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/delta-stage-expire')
    def expire_delta_stage(body: dict):
        identity = auth.identity_by_token('Bearer ' + body.get('token', ''))
        if not identity:
            return JSONResponse({'detail':'invalid fixture account'}, status_code=401)
        with sqlite3.connect(auth.USERS_DB) as db:
            changed = db.execute('UPDATE account_delta_stages SET expires_at=0 WHERE account_id=? AND batch_id=?', (identity[1], body.get('batch_id', ''))).rowcount
        return {'changed':changed}

    @main.app.post('/api/v1/__ui_fixture/reset-sync-generation')
    def test_reset_sync_generation():
        import importlib.util
        spec = importlib.util.spec_from_file_location('fixture_backup_tool', root / 'server' / 'backup_state.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return {'generation':module.reset_sync_generation(auth.USERS_DB, create_if_missing=True)}

    @main.app.post('/api/v1/__ui_fixture/revision-set')
    def set_test_revision(body: dict):
        identity = auth.identity_by_token('Bearer ' + body.get('token', ''))
        raw = body.get('revision', '')
        if not identity or not isinstance(raw, str) or not raw.isascii() or not raw.isdigit():
            return JSONResponse({'detail':'invalid fixture revision'}, status_code=400)
        revision = int(raw)
        if not 1 <= revision <= 2**63 - 1:
            return JSONResponse({'detail':'invalid fixture revision'}, status_code=400)
        with sqlite3.connect(auth.USERS_DB) as db:
            changed = db.execute('UPDATE account_state SET state_revision=? WHERE account_id=?', (revision, identity[1])).rowcount
        if changed != 1:
            return JSONResponse({'detail':'fixture state missing'}, status_code=404)
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/recovery-case')
    def seed_recovery_case():
        username = 'recover_' + uuid.uuid4().hex[:8]
        password = 'test_password_123'
        register = next(route.endpoint for route in main.app.routes if getattr(route, 'path', None) == '/api/v1/auth/register')
        put_state = next(route.endpoint for route in main.app.routes if getattr(route, 'path', None) == '/api/v1/me/state' and 'PUT' in getattr(route, 'methods', set()))
        account = register(auth.RegisterIn(username=username, password=password), None)
        position = main.POS_OF[main.WORD2ID['apple']]
        state = {'v':1,'calibrated':True,'frontier':position,'pointer':position+1,'probeCount':0,
                 'cards':{'apple':{'pos':position,'stage':1,'due':'2099-01-01T00:00:00Z'}},
                 'log':[],'pendingNew':[],'settings':{'newPerDay':0,'dailyCap':10},'streak':0}
        put_state(state, 'Bearer ' + account['token'])
        fixture.update(fsrs_offline=False, fixed_quiz=False, personal_offline=False, fsrs_delay=0, fsrs_attempts=0)
        return {'username':username,'password':password,'token':account['token']}

    @main.app.post('/api/v1/__ui_fixture/staged-ui-setup')
    def setup_staged_ui():
        fixture['staged_ui_case'] = seed_recovery_case()
        return fixture['staged_ui_case']

    @main.app.get('/api/v1/__ui_fixture/staged-ui-case')
    def read_staged_ui():
        if not fixture.get('staged_ui_case'):
            return JSONResponse({'detail':'staged UI case missing'}, status_code=404)
        return fixture['staged_ui_case']

    @main.app.post('/api/v1/__ui_fixture/backup-missing-scheduler')
    def seed_backup_missing_scheduler():
        account = seed_recovery_case()
        identity = auth.identity_by_token('Bearer ' + account['token'])
        known = main.fsrs_review(main.FsrsIn(is_new=True, deterministic=True), 'Bearer ' + account['token'])['scheduler_key']
        with sqlite3.connect(auth.USERS_DB) as db:
            raw = db.execute('SELECT state_json FROM account_state WHERE account_id=?', (identity[1],)).fetchone()[0]
            state = json.loads(raw)
            state['cards']['apple']['pendingFsrs'] = {
                'base': {'is_new':False, 'state':1, 'stability':0, 'difficulty':0, 'rating':3},
                'events':[{'id':'known-parameter-event', 'rating':3, 'at':'2026-10-27T00:00:00Z', 'schedulerKey':known},
                          {'id':'missing-parameter-event', 'rating':3, 'at':'2026-10-27T00:00:01Z', 'schedulerKey':'a'*64}]}
            db.execute('UPDATE account_state SET state_json=?, state_revision=state_revision+1 WHERE account_id=?',
                       (json.dumps(state, separators=(',', ':')), identity[1]))
        fixture['scheduler_backup_oversize'] = True
        return account

    @main.app.post('/api/v1/__ui_fixture/replace-account')
    def replace_account(body: dict):
        identity = auth.identity_by_token('Bearer ' + body.get('token', ''))
        if not identity:
            return JSONResponse({'detail': 'invalid fixture account'}, status_code=401)
        uid, old_id = identity
        new_id = uuid.uuid4().hex
        with sqlite3.connect(auth.USERS_DB) as db:
            row = db.execute('SELECT username FROM users WHERE id=? AND account_id=?', (uid, old_id)).fetchone()
            if not row:
                return JSONResponse({'detail': 'fixture account missing'}, status_code=404)
            db.execute('UPDATE users SET account_id=? WHERE id=? AND account_id=?', (new_id, uid, old_id))
        login = next(route.endpoint for route in main.app.routes if getattr(route, 'path', None) == '/api/v1/auth/login')
        put_state = next(route.endpoint for route in main.app.routes if getattr(route, 'path', None) == '/api/v1/me/state' and 'PUT' in getattr(route, 'methods', set()))
        account = login(auth.LoginIn(username=row[0], password='test_password_123'), None)
        assert account['user']['id'] == uid and account['user']['account_id'] == new_id
        position = main.POS_OF[main.WORD2ID['apple']]
        state = {'v':1,'calibrated':True,'frontier':position,'pointer':position+1,'probeCount':0,
                 'cards':{word:{'pos':position + offset, 'stage':1, 'due':'2099-01-01T00:00:00Z'} for offset, word in enumerate(('banana', 'cherry'), 1)},
                 'log':[],'pendingNew':[],'settings':{'newPerDay':0,'dailyCap':10},'streak':0}
        put_state(state, 'Bearer ' + account['token'])
        return {'token':account['token'], 'oldAccountId':old_id, 'newAccountId':new_id}

    @main.app.post('/api/v1/__ui_fixture/password-legacy')
    def seed_legacy_password(body: dict):
        identity = auth.identity_by_token('Bearer ' + body.get('token', ''))
        if not identity:
            return JSONResponse({'detail': 'invalid fixture account'}, status_code=401)
        uid, account_id = identity
        salt = uuid.uuid4().hex
        with sqlite3.connect(auth.USERS_DB) as db:
            updated = db.execute('UPDATE users SET password_hash=?,salt=? WHERE id=? AND account_id=?',
                                 (auth.hash_pwd('test_password_123', salt), salt, uid, account_id)).rowcount
        assert updated == 1
        return {'ok': True}

    @main.app.get('/api/v1/__ui_fixture/password-status')
    def password_status(authorization: str = Header(default='')):
        identity = auth.identity_by_token(authorization)
        if not identity:
            return JSONResponse({'detail': 'invalid fixture account'}, status_code=401)
        uid, account_id = identity
        with sqlite3.connect(auth.USERS_DB) as db:
            stored = db.execute('SELECT password_hash,salt FROM users WHERE id=? AND account_id=?', (uid,account_id)).fetchone()
        assert stored is not None
        return {'scheme': 'argon2id' if stored[0].startswith('$argon2id$') and stored[1] == '' else 'legacy'}

    @main.app.post('/api/v1/__ui_fixture/interop-case')
    def seed_interop_case():
        interop.clear()
        interop.update(seed_recovery_case())
        return {'ok': True}

    @main.app.get('/api/v1/__ui_fixture/interop-case')
    def get_interop_case():
        return dict(interop)

    @main.app.post('/api/v1/__ui_fixture/offline-case')
    def seed_offline_case():
        username = 'offline_' + uuid.uuid4().hex[:9]
        password = 'test_password_123'
        register = next(route.endpoint for route in main.app.routes if getattr(route, 'path', None) == '/api/v1/auth/register')
        put_state = next(route.endpoint for route in main.app.routes if getattr(route, 'path', None) == '/api/v1/me/state' and 'PUT' in getattr(route, 'methods', set()))
        account = register(auth.RegisterIn(username=username, password=password), None)
        position = main.POS_OF[main.WORD2ID['apple']]
        state = {'v':1,'calibrated':True,'frontier':position,'pointer':position + 1,'probeCount':0,
                 'cards':{'apple':{'pos':position,'due':'2020-01-02T00:00:00Z',
                     'fsrs':{'state':2,'stability':5,'difficulty':5,'due':'2020-01-02T00:00:00Z',
                             'lastReview':'2020-01-01T00:00:00Z'}}},
                 'log':[],'pendingNew':[],'settings':{'newPerDay':0,'dailyCap':1},'streak':0}
        put_state(state, 'Bearer ' + account['token'])
        fixture.update(fsrs_offline=True, fixed_quiz=True, personal_offline=False, fsrs_delay=0, fsrs_attempts=0, fsrs_failures=0, fsrs_successes=0, sync_failures=0)
        offline_account.clear()
        offline_account.update(username=username, password=password, token=account['token'])
        return dict(offline_account)

    @main.app.get('/api/v1/__ui_fixture/offline-case')
    def get_offline_case():
        return dict(offline_account)

    @main.app.post('/api/v1/__ui_fixture/personal-case')
    def seed_personal_case():
        account = seed_offline_case()
        state_get = next(route.endpoint for route in main.app.routes if getattr(route, 'path', None) == '/api/v1/me/state' and 'GET' in getattr(route, 'methods', set()))
        state_put = next(route.endpoint for route in main.app.routes if getattr(route, 'path', None) == '/api/v1/me/state' and 'PUT' in getattr(route, 'methods', set()))
        token = 'Bearer ' + account['token']
        state = state_get(token)['state']
        state['personalized'] = {'apple': {'text': 'An old sentence.', 'recall': None, 'zh': '旧句'}}
        state_put(state, token)
        fixture.update(fsrs_offline=False, fixed_quiz=True, personal_offline=True)
        return account

    @main.app.post('/api/v1/__ui_fixture/budget-case')
    def seed_budget_case(body: dict):
        day = body.get('day', '')
        if len(day) != 10:
            return JSONResponse({'detail': 'invalid fixture day'}, status_code=400)
        account = seed_offline_case()
        state_get = next(route.endpoint for route in main.app.routes if getattr(route, 'path', None) == '/api/v1/me/state' and 'GET' in getattr(route, 'methods', set()))
        state_put = next(route.endpoint for route in main.app.routes if getattr(route, 'path', None) == '/api/v1/me/state' and 'PUT' in getattr(route, 'methods', set()))
        token = 'Bearer ' + account['token']
        state = state_get(token)['state']
        state['cards']['pear'] = {'pos': 2, 'stage': 1, 'due':'2021-01-02T00:00:00Z'}
        state['settings'] = {'newPerDay':5, 'dailyCap':3}
        state['log'] = [{'d':day, 'word':word, 'kind':'review', 'rating':3, 'eventId':uuid.uuid4().hex} for word in ('doneone', 'donetwo')]
        state_put(state, token)
        fixture.update(fsrs_offline=False, fixed_quiz=True, personal_offline=False)
        return account

    @main.app.post('/api/v1/__ui_fixture/queue-case')
    def seed_queue_case():
        account = seed_recovery_case()
        state_get = next(route.endpoint for route in main.app.routes if getattr(route, 'path', None) == '/api/v1/me/state' and 'GET' in getattr(route, 'methods', set()))
        state_put = next(route.endpoint for route in main.app.routes if getattr(route, 'path', None) == '/api/v1/me/state' and 'PUT' in getattr(route, 'methods', set()))
        token = 'Bearer ' + account['token']
        state = state_get(token)['state']
        state['settings'] = {'newPerDay': 1, 'dailyCap': 1}
        state_put(state, token)
        fixture.update(lexicon_delay=6, lexicon_attempts=0)
        return account

    @main.app.post('/api/v1/__ui_fixture/state-get-hold')
    async def hold_state_get():
        state_get_release.clear()
        fixture.update(state_get_hold=True, state_get_hold_once=False, state_get_attempts=0, state_get_completed=0)
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/state-get-hold-once')
    async def hold_one_state_get():
        state_get_release.clear()
        fixture.update(state_get_hold=True, state_get_hold_once=True, state_get_attempts=0, state_get_completed=0)
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/state-get-release')
    async def release_state_get():
        fixture['state_get_hold'] = False
        state_get_release.set()
        return {'ok':True}

    @main.app.get('/api/v1/__ui_fixture/state-get-status')
    def state_get_status():
        return {'attempts':fixture['state_get_attempts'], 'completed':fixture['state_get_completed']}

    @main.app.get('/api/v1/__ui_fixture/state-upload-status')
    def state_upload_status():
        return {'attempts':fixture['state_upload_attempts'], 'delta_attempts':fixture['delta_upload_attempts'],
                'delta_successes':fixture['delta_upload_successes'], 'stage_successes':fixture['delta_stage_successes'], 'guarded_successes':fixture['guarded_merge_successes']}

    @main.app.post('/api/v1/__ui_fixture/state-upload-mode')
    def state_upload_mode(body: dict):
        mode = body.get('mode')
        if mode not in {'normal', 'oversize', 'conflict', 'expired-hold'}:
            return JSONResponse({'detail':'invalid mode'}, status_code=400)
        fixture['state_upload_mode'] = mode
        if mode == 'expired-hold': state_expired_release.clear()
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/state-expired-release')
    async def release_expired_state():
        fixture['state_upload_mode'] = 'normal'
        state_expired_release.set()
        return {'ok':True}

    @main.app.get('/api/v1/__ui_fixture/disk-status')
    def disk_status():
        return {'state':fixture['disk_test_state']}

    @main.app.post('/api/v1/__ui_fixture/disk-transition')
    def disk_transition(body: dict):
        target = body.get('state')
        allowed = {'idle':'arm', 'arm':'blocked', 'blocked':'restore', 'restore':'restored'}
        if allowed.get(fixture['disk_test_state']) != target:
            return JSONResponse({'detail':'invalid disk test transition'}, status_code=409)
        fixture['disk_test_state'] = target
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/meaning-case')
    def seed_meaning_case():
        account = seed_recovery_case()
        get_state = next(route.endpoint for route in main.app.routes if getattr(route, 'path', None) == '/api/v1/me/state' and 'GET' in getattr(route, 'methods', set()))
        put_state = next(route.endpoint for route in main.app.routes if getattr(route, 'path', None) == '/api/v1/me/state' and 'PUT' in getattr(route, 'methods', set()))
        token = 'Bearer ' + account['token']
        state = get_state(token)['state']
        state['pendingNew'] = [{'word':'pear', 'pos':main.POS_OF[main.WORD2ID['pear']]}]
        state['settings'] = {'newPerDay':1, 'dailyCap':1}
        put_state(state, token)
        fixture['meaning_mode'] = 'wrong'
        return account

    @main.app.post('/api/v1/__ui_fixture/meaning-mode')
    def meaning_mode(body: dict):
        mode = body.get('mode')
        if mode not in {'offline', 'wrong', 'empty', 'normal'}:
            return JSONResponse({'detail':'invalid mode'}, status_code=400)
        fixture['meaning_mode'] = mode
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/queue-pages-case')
    def seed_queue_pages_case():
        username = 'pages_' + uuid.uuid4().hex[:8]
        password = 'test_password_123'
        register = next(route.endpoint for route in main.app.routes if getattr(route, 'path', None) == '/api/v1/auth/register')
        put_state = next(route.endpoint for route in main.app.routes if getattr(route, 'path', None) == '/api/v1/me/state' and 'PUT' in getattr(route, 'methods', set()))
        account = register(auth.RegisterIn(username=username, password=password), None)
        available = [entry for entry in main.seq if main.PTAG.get(entry['id'], '').startswith(main.CONTENT_POS)][:7]
        assert len(available) == 7
        cards = {main.ID2WORD[entry['id']]: {'pos':main.POS_OF[entry['id']], 'stage':1, 'due':'2099-01-01T00:00:00Z'} for entry in available[:6]}
        state = {'v':1, 'calibrated':True, 'frontier':1, 'pointer':1, 'probeCount':0, 'cards':cards,
                 'log':[], 'pendingNew':[], 'settings':{'newPerDay':1, 'dailyCap':1}, 'streak':0}
        put_state(state, 'Bearer ' + account['token'])
        fixture.update(lexicon_fail_page=2, lexicon_attempts=0, lexicon_delay=0, lexicon_hold=False)
        return {'username':username, 'password':password, 'token':account['token'], 'expected':main.ID2WORD[available[6]['id']]}

    @main.app.post('/api/v1/__ui_fixture/queue-end-case')
    def seed_queue_end_case():
        username = 'end_' + uuid.uuid4().hex[:8]
        password = 'test_password_123'
        register = next(route.endpoint for route in main.app.routes if getattr(route, 'path', None) == '/api/v1/auth/register')
        put_state = next(route.endpoint for route in main.app.routes if getattr(route, 'path', None) == '/api/v1/me/state' and 'PUT' in getattr(route, 'methods', set()))
        account = register(auth.RegisterIn(username=username, password=password), None)
        last = next(entry for entry in reversed(main.seq) if main.PTAG.get(entry['id'], '').startswith(main.CONTENT_POS))
        pos = main.POS_OF[last['id']]
        state = {'v':1, 'calibrated':True, 'frontier':pos, 'pointer':pos, 'probeCount':0, 'cards':{},
                 'log':[], 'pendingNew':[], 'settings':{'newPerDay':2, 'dailyCap':2}, 'streak':0}
        put_state(state, 'Bearer ' + account['token'])
        return {'username':username, 'password':password, 'expected':main.ID2WORD[last['id']]}

    @main.app.post('/api/v1/__ui_fixture/queue-pages-online')
    def queue_pages_online():
        fixture['lexicon_fail_page'] = 0
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/queue-switch-case')
    async def seed_queue_switch_case():
        old = seed_recovery_case()
        new = seed_recovery_case()
        state_get = next(route.endpoint for route in main.app.routes if getattr(route, 'path', None) == '/api/v1/me/state' and 'GET' in getattr(route, 'methods', set()))
        state_put = next(route.endpoint for route in main.app.routes if getattr(route, 'path', None) == '/api/v1/me/state' and 'PUT' in getattr(route, 'methods', set()))
        old_token = 'Bearer ' + old['token']
        old_state = state_get(old_token)['state']
        old_state['settings'] = {'newPerDay': 1, 'dailyCap': 1}
        state_put(old_state, old_token)
        # Recreate the second identity so its first state contains only the two
        # distinct cards; normal state PUT merges and would retain apple.
        replacement = replace_account({'token': new['token']})
        new['token'] = replacement['token']
        lexicon_release.clear()
        fixture.update(lexicon_hold=True, lexicon_delay=0, lexicon_attempts=0, lexicon_completed=0)
        return {'old': old, 'new': new}

    @main.app.post('/api/v1/__ui_fixture/queue-release')
    async def release_queue():
        fixture['lexicon_hold'] = False
        lexicon_release.set()
        return {'ok': True}

    @main.app.get('/api/v1/__ui_fixture/queue-status')
    def queue_status():
        return {'attempts': fixture['lexicon_attempts'], 'completed': fixture['lexicon_completed']}

    @main.app.post('/api/v1/__ui_fixture/acceptance-switch-case')
    async def seed_acceptance_switch_case(body: dict):
        day = body.get('day', '')
        if len(day) != 10:
            return JSONResponse({'detail': 'invalid fixture day'}, status_code=400)
        old = seed_recovery_case()
        new = seed_recovery_case()
        new['token'] = replace_account({'token': new['token']})['token']
        state_get = next(route.endpoint for route in main.app.routes if getattr(route, 'path', None) == '/api/v1/me/state' and 'GET' in getattr(route, 'methods', set()))
        state_put = next(route.endpoint for route in main.app.routes if getattr(route, 'path', None) == '/api/v1/me/state' and 'PUT' in getattr(route, 'methods', set()))
        token = 'Bearer ' + old['token']
        state = state_get(token)['state']
        state['log'] = [{'eventId':uuid.uuid4().hex, 'd':day, 'word':'apple', 'kind':'learn', 'rating':3}]
        state['settings'] = {'newPerDay':0, 'dailyCap':1}
        state_put(state, token)
        fsrs_release.clear()
        fixture.update(fsrs_hold=True, fsrs_completed=0, fsrs_attempts=0, fsrs_delay=0, fixed_quiz=True)
        return {'old':old, 'new':new}

    @main.app.post('/api/v1/__ui_fixture/fsrs-release')
    async def release_fsrs():
        fixture['fsrs_hold'] = False
        fsrs_release.set()
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/fsrs-relogin-case')
    async def seed_fsrs_relogin_case():
        account = seed_offline_case()
        fsrs_release.clear()
        fixture.update(fsrs_offline=False, fixed_quiz=True, fsrs_hold=True, fsrs_delay=0,
                       fsrs_attempts=0, fsrs_completed=0, fsrs_failures=0, fsrs_successes=0)
        return account

    @main.app.post('/api/v1/__ui_fixture/undo-case')
    def seed_undo_case():
        account = seed_offline_case()
        fixture.update(fsrs_offline=False, fixed_quiz=True, fsrs_delay=4, fsrs_attempts=0)
        return account

    @main.app.post('/api/v1/__ui_fixture/fsrs-online')
    def set_fsrs_online():
        fixture['fsrs_offline'] = False
        return {'ok':True}

    @main.app.post('/api/v1/__ui_fixture/personal-online')
    def set_personal_online():
        fixture['personal_offline'] = False
        return {'ok': True}

    @main.app.get('/api/v1/__ui_fixture/fsrs-status')
    def fsrs_status():
        return {'offline':fixture['fsrs_offline'],'failures':fixture['fsrs_failures'],'successes':fixture['fsrs_successes'], 'sync_failures':fixture['sync_failures'], 'attempts':fixture['fsrs_attempts'], 'completed':fixture['fsrs_completed']}

    @main.app.get('/api/v1/__ui_fixture')
    def fixture_identity():
        return {'fixture': 'vocab-ui-isolated-v1'}

    @main.app.get('/api/v1/__ui_fixture/identity')
    def fixture_instance():
        return {'fixture': 'vocab-ui-isolated-v1', 'nonce': os.environ.get('VOCAB_UI_FIXTURE_NONCE', '')}
    # Uvicorn restores the previous handler and re-raises SIGTERM after graceful
    # shutdown. Keep that re-raise from terminating Python before the enclosing
    # TemporaryDirectory context can remove its disposable database copies.
    signal.signal(signal.SIGTERM, lambda *_: None)
    uvicorn.run(main.app, host='127.0.0.1', port=int(os.environ.get('VOCAB_UI_PORT', '18765')), log_level='warning')
