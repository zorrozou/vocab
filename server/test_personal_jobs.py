#!/usr/bin/env python3
"""Exercise durable task claiming against the isolated app copy, without external LLM/TTS."""
import json
import sqlite3
import sys
import tempfile
import time
from pathlib import Path
from fastapi import HTTPException

sys.path.insert(0, sys.argv[1] if len(sys.argv) > 1 else 'server')
from app import main as m

from unittest.mock import patch
from urllib.error import HTTPError

# The production incident was an expired judging plan (HTTP 429). Both calls must
# use the same rubric. A low or malformed review is final, never a failover trigger.
real_quality = m.quality_check
sample = ('I ate an apple after lunch.', 'apple', None, '午饭后我吃了一个苹果。')
outage = HTTPError('https://review.invalid/', 429, 'limited', {}, None)
with patch.object(m, 'JUDGE_BASE', 'https://review.invalid'), patch.object(m, 'LLM_BASE', 'https://generator.invalid'):
    with patch('urllib.request.urlopen', side_effect=outage):
        try:
            m._request_review('review', m.JUDGE_BASE, '', 'reviewer')
        except m.ReviewUnavailable as error:
            assert str(error) == 'HTTP 429'
        else:
            raise AssertionError('outage must not become a low score')
    m._judge_retry_at = 0
    with patch.object(m, '_request_review', side_effect=[m.ReviewUnavailable('HTTP 429'), '5 5 4 5 5 5', '5 4 5 5 5 5']) as call:
        assert real_quality(*sample) == real_quality(*sample) == 4
        assert [args.args[1] for args in call.call_args_list] == [m.JUDGE_BASE, m.LLM_BASE, m.LLM_BASE]
        assert len({args.args[0] for args in call.call_args_list}) == 1
    for scores, expected in [('5 5 3 5 5 5', 3), ('5', 0)]:
        m._judge_retry_at = 0
        with patch.object(m, '_request_review', return_value=scores) as call:
            assert real_quality(*sample) == expected and call.call_count == 1

with tempfile.TemporaryDirectory() as tmp:
    m.PERSONAL_DB = Path(tmp) / 'personal.db'
    m.init_db()
    m.llm = lambda prompt: 'Apple and banana are on the table. || 苹果和香蕉在桌上。'
    m.validate_multi = lambda *args: None
    m.quality_check = lambda *args: 5
    m.ensure_tts = lambda *args: True
    guest = m.issue_guest()["token"]
    other_guest = m.issue_guest()["token"]
    def body(job_id, weak=('apple', 'banana'), replace=True):
        return m.PersonalizeIn(device='guest-secret', date='2026-10-27', weak_words=list(weak),
                               learned_max_pos=5000, sync=True, replace=replace, request_id=job_id)
    first = m.personalize(body('job-test-0001'), authorization='', x_guest_token=guest)
    assert first['status'] == 'queued'
    assert m.personalize(body('job-test-0001'), authorization='', x_guest_token=guest)['job_id'] == first['job_id']
    try:
        m.personalize(body('job-test-0001', weak=('apple',)), authorization='', x_guest_token=guest)
        raise AssertionError('changed idempotent request accepted')
    except HTTPException as e:
        assert e.status_code == 409
    abandoned = m.claim_personal_job()
    assert abandoned[0] == first['job_id']
    with sqlite3.connect(m.PERSONAL_DB) as conn:
        conn.execute('UPDATE personal_jobs SET lease_until=? WHERE id=?', (time.time() - 1, abandoned[0]))
    recovered = m.claim_personal_job()
    assert recovered[0] == abandoned[0] and recovered[-1] != abandoned[-1]
    # An expired worker cannot publish results after another worker acquired the job.
    m.generate(recovered[1], recovered[2], ['apple'], 5000, job_id=abandoned[0], job_lease=abandoned[-1])
    assert not m.personalized_job(job_id=first['job_id'], device='guest-secret', authorization='', x_guest_token=guest)['sentences']
    m.run_personal_job(recovered)
    result = m.personalized_job(job_id=first['job_id'], device='guest-secret', authorization='', x_guest_token=guest)
    assert result['status'] == 'complete' and {r['target'] for r in result['sentences']} == {'apple', 'banana'}
    try:
        m.personalized_job(job_id=first['job_id'], device='other-secret', authorization='', x_guest_token=other_guest)
        raise AssertionError('other guest could read task')
    except HTTPException as e:
        assert e.status_code == 404
    # A new replacement is isolated from an older batch, including late outputs.
    second = m.personalize(body('job-test-0002', weak=('apple',)), authorization='', x_guest_token=guest)
    assert m.personalized_job(job_id=first['job_id'], device='guest-secret', authorization='', x_guest_token=guest)['status'] == 'superseded'
    assert m.personalized(device='guest-secret', date='2026-10-27', authorization='', x_guest_token=guest)['sentences'] == []
    m.run_personal_job(m.claim_personal_job())
    visible = m.personalized(device='guest-secret', date='2026-10-27', authorization='', x_guest_token=guest)['sentences']
    assert len(visible) == 1 and visible[0]['target'] == 'apple'
    # Failures are visible as partial, rather than silently marking all targets complete.
    m.validate_multi = lambda cand, target, *args: 'invalid' if target == 'banana' else None
    third = m.personalize(body('job-test-0003', replace=False), authorization='', x_guest_token=guest)
    m.run_personal_job(m.claim_personal_job())
    partial = m.personalized_job(job_id=third['job_id'], device='guest-secret', authorization='', x_guest_token=guest)
    assert partial['status'] == 'partial' and [r['target'] for r in partial['sentences']] == ['apple']
    # With both review services down, zero published rows must be a failed job.
    m.validate_multi = lambda *args: None
    with patch.object(m, 'quality_check', side_effect=m.ReviewUnavailable('HTTP 503')):
        fourth = m.personalize(body('review-down-0004', replace=False), authorization='', x_guest_token=guest)
        m.run_personal_job(m.claim_personal_job())
        result = m.personalized_job(job_id=fourth['job_id'], device='guest-secret', authorization='', x_guest_token=guest)
        assert result['status'] == 'failed' and not result['sentences'] and '评审' in result['error']
    # Resuming a partial generation on its own ID preserves the original accepted row.
    with sqlite3.connect(m.PERSONAL_DB) as conn:
        conn.execute("UPDATE personal_jobs SET status='queued' WHERE id=?", (third['job_id'],))
    with patch.object(m, 'llm', return_value='She peeled a banana for lunch. || 她午餐时剥了一根香蕉。') as gen:
        m.run_personal_job(m.claim_personal_job())
        assert gen.call_count == 1
    resumed = m.personalized_job(job_id=third['job_id'], device='guest-secret', authorization='', x_guest_token=guest)
    assert resumed['status'] == 'complete' and len(resumed['sentences']) == 2
    assert partial['sentences'][0] in resumed['sentences']
    # Reopening the completion screen on either shipped client uses a fresh ID.
    def submit(req, owner=guest):
        return m.personalize(req, authorization='', x_guest_token=owner)
    def rows(req, owner=guest):
        return m.personalized_job(job_id=req.request_id, device='guest-secret', authorization='', x_guest_token=owner)['sentences']
    daily = body('reopen-batch-001')
    assert submit(daily)['status'] == 'queued' and not rows(daily)  # previous request was a manual swap
    with patch.object(m, 'validate_multi', side_effect=lambda s, word, *args: 'invalid' if word == 'banana' else None):
        m.run_personal_job(m.claim_personal_job())
    accepted = rows(daily)
    assert [r['target'] for r in accepted] == ['apple']
    retry = body('reopen-batch-002')
    assert submit(retry)['status'] == 'queued' and rows(retry) == accepted
    with patch.object(m, 'llm', wraps=m.llm) as gen:
        m.run_personal_job(m.claim_personal_job())
        assert gen.call_count == 1
    again = body('reopen-batch-003')
    assert submit(again)['status'] == 'complete' and rows(again) == rows(retry)
    assert m.claim_personal_job() is None
    # Content flagged for review by this owner must be generated again.
    with sqlite3.connect(m.PERSONAL_DB) as conn:
        owner = m.personal_owner('guest-secret', '', guest)
        conn.execute("""INSERT INTO content_reports(owner,request_id,fingerprint,word,kind,text,reason,comment,revision,created)
                     VALUES(?,?,?,'apple','personal',?,'grammar','','',?)""", (owner,'test-report','digest',accepted[0]['text'],time.time()))
    flagged = body('reopen-batch-004')
    assert submit(flagged)['status'] == 'queued' and [r['target'] for r in rows(flagged)] == ['banana']
    m.run_personal_job(m.claim_personal_job())
    for req, owner in [(body('other-owner-001'), other_guest), (body('other-day-00001'), guest),
                       (body('other-limit-001'), guest), (body('manual-swap-001', replace=False), guest)]:
        if req.request_id == 'other-day-00001': req.date = '2026-10-28'
        if req.request_id == 'other-limit-001': req.learned_max_pos = 100
        assert submit(req, owner)['status'] == 'queued' and rows(req, owner) == []
        m.run_personal_job(m.claim_personal_job())
    assert m.core_sense(m.WORD2ID['lurch']) == '突然的摇晃'
    print('PASS durable claims, lease recovery, stale worker fencing, idempotency and batch isolation')

    import nightly
    owner, day = 'legacy-test', '2026-10-20'
    with sqlite3.connect(m.PERSONAL_DB) as db:
        db.execute('INSERT INTO requests(device,date,payload,processed) VALUES(?,?,?,0)',
                   (owner,day,json.dumps({'weak_words':['apple','banana']})))
        db.executemany('INSERT INTO sentences(device,date,target,text,zh) VALUES(?,?,?,?,?)',
                       [(owner,day,word,'Original '+word,'旧例句') for word in ('apple','banana')])
        def old_rows():
            return dict(db.execute('SELECT target,text FROM sentences WHERE device=? AND date=?',(owner,day)))
        with patch.object(nightly, 'PERSONAL_DB', m.PERSONAL_DB), patch.object(m, 'quality_check', side_effect=m.ReviewUnavailable()):
            db.commit()
            nightly.main()
        assert old_rows() == {'apple':'Original apple','banana':'Original banana'}
        assert db.execute('SELECT processed FROM requests WHERE device=?',(owner,)).fetchone() == (0,)
        with patch.object(nightly, 'PERSONAL_DB', m.PERSONAL_DB), patch.object(m, 'validate_multi', side_effect=lambda s, w, *a: 'invalid' if w=='banana' else None):
            nightly.main()
        assert old_rows() == {'apple':'Apple and banana are on the table.','banana':'Original banana'}
        assert db.execute('SELECT processed FROM requests WHERE device=?',(owner,)).fetchone() == (1,)
    print('PASS nightly retry keeps previously reviewed sentences on outage and partial generation')
