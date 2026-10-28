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
    print('PASS durable claims, lease recovery, stale worker fencing, idempotency and batch isolation')
