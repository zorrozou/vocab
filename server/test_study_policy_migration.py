"""Migration is idempotent and leaves every schedule and offline claim unchanged."""
import importlib.util, json, sqlite3, sys, tempfile
from pathlib import Path
sys.path.insert(0,'server')
from app import auth
from app.study_policy import is_mastered
spec=importlib.util.spec_from_file_location('migration',Path('pipeline/migrate_study_policy.py'))
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
with tempfile.TemporaryDirectory(prefix='vocab-policy-migration-') as temporary:
    root=Path(temporary);(root/'data').mkdir();auth.USERS_DB=root/'data/users.db';auth.init_users()
    before={'v':1,'restoreEpoch':7,'cards':{'known':{'fsrs':{'state':2,'stability':200,'difficulty':5},'due':'2026-01-01'},'conflict':{'stage':6,'fsrs':{'state':2,'stability':1,'difficulty':5}}},'log':[],'pendingNew':['pear'],'settings':{'newPerDay':10,'dailyCap':100}}
    with sqlite3.connect(auth.USERS_DB) as conn:
        conn.execute('INSERT INTO account_state(account_id,state_json,updated_at,state_revision) VALUES(?,?,?,?)',('a'*32,json.dumps(before),1,1))
        tables={name:list(conn.execute('SELECT * FROM '+name)) for (name,) in conn.execute("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'daily_%'")}
    assert module.migrate(root)=={'accounts':1,'cards':2,'legacy_mastered':1,'applied':False}
    assert module.migrate(root,root/'before.sqlite')['legacy_mastered']==1
    with sqlite3.connect(auth.USERS_DB) as conn:
        raw,revision=conn.execute('SELECT state_json,state_revision FROM account_state').fetchone();after=json.loads(raw)
        assert revision==2 and after['restoreEpoch']==7 and is_mastered(after['cards']['known']) and not is_mastered(after['cards']['conflict'])
        for card in after['cards'].values():card.pop('studyEvidence')
        assert after==before
        assert json.loads(conn.execute('SELECT state_json FROM account_state_backups').fetchone()[0])==before
        for name,rows in tables.items():assert list(conn.execute('SELECT * FROM '+name))==rows
        assert conn.execute('SELECT reset FROM account_state_changes').fetchone()==(0,)
    assert module.migrate(root,root/'second.sqlite')['accounts']==0
    with sqlite3.connect(root/'before.sqlite') as conn:assert conn.execute('SELECT state_revision FROM account_state').fetchone()==(1,)
print('PASS mastery migration preserves exact pre-state, restore boundary, offline claims and idempotence')
