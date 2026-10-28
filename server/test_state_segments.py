#!/usr/bin/env python3
"""Transactional segmented state, migration compatibility and corruption checks."""
import json, random, sqlite3, tempfile
from pathlib import Path
from app import state_segments as segments

with tempfile.TemporaryDirectory(prefix='vocab-state-segments-') as tmp:
    path=Path(tmp)/'state.db';db=sqlite3.connect(path)
    db.execute('PRAGMA journal_mode=WAL')
    db.execute('CREATE TABLE account_state(account_id TEXT PRIMARY KEY,state_json TEXT NOT NULL,state_revision INTEGER NOT NULL,segments_version INTEGER NOT NULL DEFAULT 0)')
    segments.initialize(db)
    state={'v':1,'cards':{f'word_{i:04d}':{'pos':i,'extra':'x'*2048} for i in range(4500)},
           'knowledge':{'é':{'a':1},'e\u0301':{'a':2}},'log':[{'word':'first'},None,{'word':'last'}],
           'emptyMap':{},'emptyList':[],'value':None}
    encoded=segments.encode(state);assert len(encoded.encode())>8*1024*1024
    db.execute('INSERT INTO account_state(account_id,state_json,state_revision) VALUES(?,?,?)',('a',encoded,1))
    assert segments.write(db,'a',1,state)
    db.commit()
    assert segments.read(db,'a',1,encoded)==state
    assert db.execute('SELECT segments_version FROM account_state WHERE account_id=?',('a',)).fetchone()==(1,)
    # A second connection must not see an in-flight replacement.
    changed={**state,'v':2};new=segments.encode(changed)
    db.execute('BEGIN IMMEDIATE');db.execute('UPDATE account_state SET state_json=?,state_revision=2 WHERE account_id=?',(new,'a'))
    segments.write(db,'a',2,changed)
    with sqlite3.connect(path) as reader:
        raw,rev=reader.execute('SELECT state_json,state_revision FROM account_state WHERE account_id=?',('a',)).fetchone()
        assert rev==1 and segments.read(reader,'a',rev,raw)==state
    db.rollback();assert segments.read(db,'a',1,encoded)==state
    # A one-card edit only changes that entry, not thousands of unchanged rows.
    edited={**state,'cards':{**state['cards'], 'word_0042':{'pos':42,'extra':'edited'}}}
    edited_raw=segments.encode(edited)
    db.execute('BEGIN IMMEDIATE');before_changes=db.total_changes
    db.execute('UPDATE account_state SET state_json=?,state_revision=2 WHERE account_id=?',(edited_raw,'a'))
    segments.write(db,'a',2,edited)
    assert db.total_changes-before_changes == 4  # mirror, one item, metadata, marker
    assert segments.read(db,'a',2,edited_raw)==edited
    db.rollback();assert segments.read(db,'a',1,encoded)==state
    # Array shifts, removed fields and reordered fields rewrite only affected
    # positions, and do not leave obsolete entries behind.
    reshaped={'log':[None,{'word':'last'}], 'cards':{'word_0001':state['cards']['word_0001']}, 'v':1}
    reshaped_raw=segments.encode(reshaped)
    db.execute('BEGIN IMMEDIATE');db.execute('UPDATE account_state SET state_json=?,state_revision=2 WHERE account_id=?',(reshaped_raw,'a'))
    segments.write(db,'a',2,reshaped,force=True)
    assert segments.read(db,'a',2,reshaped_raw)==reshaped
    assert db.execute('SELECT count(*) FROM account_state_segment_items WHERE account_id=?',('a',)).fetchone()[0]==3
    db.rollback();assert segments.read(db,'a',1,encoded)==state
    # Failed insertion rolls back both the compatibility mirror and segments.
    changed={**state,'cards':{**state['cards'],'new_word':{'pos':4501}}};new=segments.encode(changed)
    db.execute("CREATE TRIGGER fail_segment BEFORE INSERT ON account_state_segment_items BEGIN SELECT RAISE(ABORT, 'injected'); END")
    db.commit();db.execute('BEGIN IMMEDIATE')
    try:
        db.execute('UPDATE account_state SET state_json=?,state_revision=2 WHERE account_id=?',(new,'a'))
        segments.write(db,'a',2,changed)
    except sqlite3.IntegrityError: db.rollback()
    else: raise AssertionError('injected failure did not abort')
    assert segments.read(db,'a',1,encoded)==state
    db.execute('DROP TRIGGER fail_segment');db.commit()
    # Missing metadata, a wrong value, an extra item and stale revision all fail closed.
    for kind in ('metadata','value','extra','revision'):
        db.execute('BEGIN IMMEDIATE')
        if kind=='metadata': db.execute('DELETE FROM account_state_segment_meta WHERE account_id=?',('a',))
        elif kind=='value': db.execute("UPDATE account_state_segment_items SET value_json='null' WHERE account_id='a' AND field_index=1 AND item_index=0")
        elif kind=='extra': db.execute("INSERT INTO account_state_segment_items VALUES('a',9999,0,NULL,'null')")
        else: db.execute("UPDATE account_state_segment_meta SET revision=2 WHERE account_id='a'")
        try: segments.read(db,'a',1,encoded)
        except segments.SegmentError: pass
        else: raise AssertionError(kind+' corruption accepted')
        db.rollback()
    small={'cards':{},'log':[]};raw=segments.encode(small)
    db.execute('BEGIN IMMEDIATE');db.execute('UPDATE account_state SET state_json=?,state_revision=2 WHERE account_id=?',(raw,'a'))
    assert not segments.write(db,'a',2,small);db.commit()
    assert segments.read(db,'a',2,raw) is None
    assert db.execute('SELECT segments_version FROM account_state WHERE account_id=?',('a',)).fetchone()==(0,)
    # Repeated arbitrary field/collection changes must always reconstruct the
    # exact ordered mirror, including transitions between scalar and container.
    rng=random.Random(54832)
    db.execute('INSERT INTO account_state(account_id,state_json,state_revision) VALUES(?,?,?)',('b','{}',1))
    segments.write(db,'b',1,{},force=True);db.commit()
    for revision in range(2,82):
        names=['cards','log','é','e\u0301','v'];rng.shuffle(names)
        randomized={}
        for name in names[:rng.randrange(6)]:
            kind=rng.randrange(3)
            if kind==0: value={f'key_{i}':rng.randrange(100) for i in rng.sample(range(8),rng.randrange(9))}
            elif kind==1: value=[rng.choice([None,False,{'x':rng.randrange(9)}]) for _ in range(rng.randrange(9))]
            else: value=rng.choice([None,True,rng.randrange(9),'text'])
            randomized[name]=value
        randomized_raw=segments.encode(randomized)
        db.execute('UPDATE account_state SET state_json=?,state_revision=? WHERE account_id=?',(randomized_raw,revision,'b'))
        segments.write(db,'b',revision,randomized,force=True);db.commit()
        assert segments.encode(segments.read(db,'b',revision,randomized_raw))==randomized_raw
    db.close()
print('PASS segmented large state, atomic replacement, compatibility mirror and corruption fencing')
