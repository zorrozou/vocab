#!/usr/bin/env python3
"""Anchor existing mastery without changing schedules, claims or restore epochs.

Run with the API stopped during deployment. Every changed account gets an exact
pre-migration backup, a new revision and an ordinary incremental change record.
Dry-run is the default; --apply also requires a fresh SQLite backup destination.
"""
import argparse, copy, json, sqlite3, sys, time
from pathlib import Path


def migrate(server_root, backup=None):
    sys.path.insert(0, str(Path(server_root).resolve()))
    from app import auth, state_segments
    from app.state_changes import record_change
    from app.study_policy import origin, legacy_mastered, validate_evidence
    database=Path(server_root)/'data/users.db'
    if not database.is_file(): raise FileNotFoundError(database)
    auth.USERS_DB=database
    with sqlite3.connect(database,timeout=30) as conn:
        if backup is not None:
            backup=Path(backup)
            if backup.exists(): raise FileExistsError(backup)
            with sqlite3.connect(backup) as target: conn.backup(target)
            backup.chmod(0o600)
        conn.execute('BEGIN IMMEDIATE')
        counts={'accounts':0,'cards':0,'legacy_mastered':0,'applied':backup is not None}
        for account,raw,updated,revision in conn.execute('SELECT account_id,state_json,updated_at,state_revision FROM account_state').fetchall():
            before=auth.load_verified_state(conn,account,raw,auth.validate_state_revision(revision))
            after=copy.deepcopy(before); changed=False
            for card in after.get('cards',{}).values():
                if card.get('studyEvidence') is not None:
                    validate_evidence(card['studyEvidence']); continue
                card['studyEvidence']=origin(card);changed=True;counts['cards']+=1
                counts['legacy_mastered']+=int(legacy_mastered(card))
            if not changed: continue
            counts['accounts']+=1
            encoded=auth.serialize_state(after,max_bytes=auth.MAX_LARGE_DELTA_STATE_BYTES)
            if backup is None: continue
            now=max(time.time(),updated+.000001);new_revision=auth.next_state_revision(revision)
            conn.execute('INSERT INTO account_state_backups(account_id,state_json,created_at,reason) VALUES(?,?,?,?)',(account,raw,now,'before_study_policy_v1'))
            conn.execute('UPDATE account_state SET state_json=?,updated_at=?,state_revision=? WHERE account_id=?',(encoded,now,new_revision,account))
            state_segments.write(conn,account,new_revision,after)
            record_change(conn,account,revision,new_revision,after.get('restoreEpoch',0),before,after,now)
        if backup is None: conn.rollback()
        else: conn.commit()
        return counts


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server-root',type=Path,default=Path(__file__).resolve().parents[1]/'server')
    parser.add_argument('--apply',action='store_true')
    parser.add_argument('--backup',type=Path)
    args=parser.parse_args()
    if args.apply != (args.backup is not None): parser.error('--apply and --backup must be supplied together')
    print(json.dumps(migrate(args.server_root,args.backup),ensure_ascii=False))
