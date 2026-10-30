import json, sys
from copy import deepcopy
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parent))
from app.study_policy import is_mastered, merge_evidence, validate_evidence
from fastapi import HTTPException

cases=json.loads((Path(__file__).parents[1]/'tests/study_policy_fixtures.json').read_text())
for case in cases:
    assert is_mastered(case['card']) == case['mastered'],case['name']
    if case['card'].get('studyEvidence'): validate_evidence(case['card']['studyEvidence'])
old=deepcopy(cases[4]['card']);legacy=deepcopy(old);legacy.pop('studyEvidence')
merged=merge_evidence(old,legacy,legacy)
assert merged == old['studyEvidence']
later=deepcopy(old);later['studyEvidence']['events']['again']={'at':'2026-03-17T08:00:00Z','day':'2026-03-17','rating':1,'kind':'review','verified':False}
assert merge_evidence(old,later,later)==merge_evidence(later,old,later)
later['studyEvidence']=merge_evidence(old,later,later);assert not is_mastered(later)
bad=deepcopy(old);bad['studyEvidence']['events']['1']['rating']=4
try: merge_evidence(old,bad,bad)
except HTTPException as e: assert e.status_code==409
else: raise AssertionError('conflicting evidence silently accepted')
# An old client may retain the FSRS grade while dropping its new context.
unknown=deepcopy(old);unknown['fsrsHistory']={'events':[{'id':'again','at':'2026-03-17T08:00:00Z','rating':1}]}
unknown['studyEvidence']=merge_evidence(old,legacy,unknown)
assert not is_mastered(unknown)
print(f'PASS {len(cases)} server mastery fixtures and evidence merge preservation')
