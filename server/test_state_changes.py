#!/usr/bin/env python3
"""Apply recorded deltas independently, including JSON type distinctions."""
import copy, json, random, sqlite3
from app import state_changes
from app.state_changes import MAX_OPERATIONS, state_delta

def apply(before, operations):
    result = copy.deepcopy(before)
    for op in operations:
        path = op['path']
        if not path:
            assert op['op'] == 'set'
            result = copy.deepcopy(op['value'])
            continue
        target = result
        for key in path[:-1]: target = target[key]
        if op['op'] == 'remove': del target[path[-1]]
        else: target[path[-1]] = copy.deepcopy(op['value'])
    return result

def check(old, new):
    ops = state_delta(old, new)
    result = apply(old, ops)
    assert json.dumps(result, sort_keys=True, ensure_ascii=False) == json.dumps(new, sort_keys=True, ensure_ascii=False)
    assert len(ops) <= MAX_OPERATIONS

check(None, {'cards':{'词🙂':{'x':1}}, 'flag':True})
check({'x':True, 'cards':{'word':{'x':1}}}, {'x':1, 'cards':{'word':{'x':True}}})
check({'value':-0.0}, {'value':0.0})
base={'cards':{'apple':{'pos':1}},'settings':{}}
ops=[{'op':'set','path':['cards','banana'],'value':{'pos':2}}, {'op':'set','path':['settings','newPerDay'],'value':10}]
state_changes.validate_upload_ops(ops)
patched=state_changes.apply_upload_ops(base,ops)
assert base=={'cards':{'apple':{'pos':1}},'settings':{}} and patched['cards']['banana']['pos']==2
for bad in ([], [{'op':'set','path':['cards'],'value':{}},{'op':'remove','path':['cards','apple']}],
            [{'op':'remove','path':[]}], [{'op':'set','path':['__proto__'],'value':{}}]):
    try: state_changes.validate_upload_ops(bad)
    except ValueError: pass
    else: raise AssertionError('invalid upload patch accepted')
check({'cards':{str(i): i for i in range(3000)}}, {'cards':{str(i): i+1 for i in range(3000)}})
rng = random.Random(712)
for _ in range(300):
    def obj():
        return {k: {w:rng.choice([None, True, 1, 1.0, '词', [1,2]]) for w in rng.sample(['a','b','c'],rng.randrange(4))}
                for k in rng.sample(['cards','other','prefs'],rng.randrange(4))}
    check(obj(), obj())
db=sqlite3.connect(':memory:')
db.execute('CREATE TABLE account_state_changes(account_id TEXT,revision INTEGER,base_revision INTEGER,restore_epoch INTEGER,reset INTEGER,payload BLOB,digest TEXT,created_at REAL,PRIMARY KEY(account_id,revision))')
db.execute('CREATE TABLE account_state_change_compact(account_id TEXT,revision INTEGER,payload BLOB,digest TEXT,PRIMARY KEY(account_id,revision))')
db.execute('CREATE TRIGGER compact_delete AFTER DELETE ON account_state_changes BEGIN DELETE FROM account_state_change_compact WHERE account_id=OLD.account_id AND revision=OLD.revision; END')
old={'log':[{'eventId':'aaaaaaaa','word':'old'}]*1}
new={'log':old['log']+[{'eventId':'bbbbbbbb','word':'new'}]}
compact=state_delta(old,new,compact_log=True)
assert compact == [{'op':'append_log','path':['log'],'value':[new['log'][-1]]}]
assert state_changes.apply_upload_ops(old,compact)==new
assert state_delta(old,{'log':new['log']+[{'word':'legacy'}]},compact_log=True)[0]['op']=='set'
middle={'log':[new['log'][0],{'word':'middle'},new['log'][1]]}
splice=state_delta(new,middle,compact_log=True)[0]
assert splice == {'op':'splice_log','path':['log'],'value':{'index':1,'delete':0,'items':[{'word':'middle'}]}}
v=splice['value']; reconstructed=copy.deepcopy(new); reconstructed['log'][v['index']:v['index']+v['delete']]=v['items']
assert reconstructed==middle
trim=state_delta(middle,{'log':[middle['log'][-1]]},compact_log=True)[0]
assert trim['op']=='splice_log' and trim['value']=={'index':0,'delete':2,'items':[]}
state_changes.record_change(db,'compact',0,1,0,old,new,0)
assert db.execute('SELECT count(*) FROM account_state_change_compact').fetchone()[0]==1
db.execute('DELETE FROM account_state_changes WHERE account_id=?',('compact',))
assert db.execute('SELECT count(*) FROM account_state_change_compact').fetchone()[0]==0
large={'log':[{'eventId':f'{i:032x}','word':f'word{i:04d}','d':'2026-10-27','kind':'review','rating':3} for i in range(1200)]}
inserted=copy.deepcopy(large); inserted['log'].insert(600,{'eventId':'f'*32,'word':'new','d':'2026-10-27','kind':'review','rating':4})
state_changes.record_change(db,'large',0,1,0,large,inserted,0)
full_size=db.execute('SELECT length(payload) FROM account_state_changes WHERE account_id=?',('large',)).fetchone()[0]
compact_size=db.execute('SELECT length(payload) FROM account_state_change_compact WHERE account_id=?',('large',)).fetchone()[0]
assert compact_size < full_size // 100, (compact_size, full_size)
db.execute('DELETE FROM account_state_changes WHERE account_id=?',('large',))
state_changes.MAX_ACCOUNT_BYTES=900
state_changes.MAX_GLOBAL_BYTES=1800
previous=large
for i in range(3):
    following=copy.deepcopy(previous)
    following['log'].insert(600+i,{'eventId':f'{1201+i:032x}','word':f'new{i}','d':'2026-10-27','kind':'review','rating':4})
    state_changes.record_change(db,'large',i,i+1,0,previous,following,i+1)
    previous=following
assert db.execute('SELECT count(*) FROM account_state_changes WHERE account_id=?',('large',)).fetchone()[0]==3
assert db.execute('SELECT count(*) FROM account_state_changes WHERE account_id=? AND length(payload)=0',('large',)).fetchone()[0]==3
assert db.execute('SELECT count(*) FROM account_state_change_compact WHERE account_id=?',('large',)).fetchone()[0]==3
assert db.execute('SELECT sum(length(payload)) FROM account_state_change_compact WHERE account_id=?',('large',)).fetchone()[0]<=900
db.execute('SAVEPOINT rejected_compact')
db.execute("CREATE TRIGGER fail_compact BEFORE INSERT ON account_state_change_compact BEGIN SELECT RAISE(ABORT,'injected'); END")
try: state_changes.record_change(db,'rollback',0,1,0,large,inserted,4)
except sqlite3.IntegrityError: db.execute('ROLLBACK TO rejected_compact')
else: raise AssertionError('compact write failure not propagated')
db.execute('RELEASE rejected_compact')
assert db.execute('SELECT count(*) FROM account_state_changes WHERE account_id=?',('rollback',)).fetchone()[0]==0
db.execute('DELETE FROM account_state_changes WHERE account_id=?',('large',))
state_changes.MAX_ACCOUNT_BYTES=16*1024*1024
state_changes.MAX_GLOBAL_BYTES=128*1024*1024
db.commit()
state_changes.record_change(db,'account',0,1,0,None,{'v':1},1)
db.rollback()
assert db.execute('SELECT count(*) FROM account_state_changes').fetchone()[0] == 0
state_changes.MAX_RECORD_BYTES=20
state_changes.record_change(db,'account',0,1,0,None,{'v':'x'*100},1)
assert db.execute('SELECT reset,payload FROM account_state_changes').fetchone() == (1,b'')
state_changes.record_change(db,'other',0,1,True,None,{'v':1},1)
assert db.execute('SELECT restore_epoch,reset FROM account_state_changes WHERE account_id=?',('other',)).fetchone() == (-1,1)
db.execute('DELETE FROM account_state_changes')
state_changes.MAX_RECORD_BYTES=1000
state_changes.MAX_ACCOUNT_BYTES=90
state_changes.MAX_GLOBAL_BYTES=120
for revision in range(1,5):
    state_changes.record_change(db,'account',revision-1,revision,0,None,{'v':'x'*20},revision)
assert db.execute('SELECT sum(length(payload)) FROM account_state_changes WHERE account_id=?',('account',)).fetchone()[0] <= 90
assert db.execute('SELECT min(revision) FROM account_state_changes WHERE account_id=?',('account',)).fetchone()[0] > 1
state_changes.record_change(db,'other',0,1,0,None,{'v':'x'*20},5)
assert db.execute('SELECT sum(length(payload)) FROM account_state_changes').fetchone()[0] <= 120
assert db.execute('SELECT count(*) FROM account_state_changes WHERE account_id=?',('other',)).fetchone()[0] == 1
print('PASS state-change patch round trips, type changes, deletion, rollback, reset fallback and byte retention')
