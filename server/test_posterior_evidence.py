"""Posterior causal replay and safe failure regression tests."""
import copy
import sys
sys.path.insert(0, 'server')
from fastapi import HTTPException
from app.posterior_evidence import anchor, canonicalize, merge, replay, validate
from app.auth import merge_learning_states

base, _ = anchor({'posterior': [1 / 49] * 49, 'probeCount': 1})
def branch(event_id, rank, resp, day='2026-10-27'):
    state = copy.deepcopy(base)
    history = state['posteriorHistory']
    history['events'][event_id] = {'kind': 'update', 'device': event_id, 'at': '2026-10-27T00:00:00Z', 'day': day, 'parents': [], 'rank': rank, 'resp': resp, 'weight': 1, 'guess': .25}
    state['posterior'], state['probeCount'] = replay(history)
    validate(state)
    return state

a, b = branch('a', 1000, 1), branch('b', 2000, 0)
merged = merge_learning_states(a, b)
assert merged['probeCount'] == 3 and len(merged['posteriorHistory']['events']) == 2
assert merge_learning_states(b, a)['posterior'] == merged['posterior']
assert merge_learning_states(merged, a)['posterior'] == merged['posterior']

# Concurrent daily diffusion is applied once while both causal events survive.
x = copy.deepcopy(a)
y = copy.deepcopy(a)
for state, event_id in ((x, 'd1'), (y, 'd2')):
    state['posteriorHistory']['events'][event_id] = {'kind': 'diffuse', 'device': event_id, 'at': '2026-10-27T00:00:00Z', 'day': '2026-10-28', 'parents': ['a']}
    state['posterior'], state['probeCount'] = replay(state['posteriorHistory'])
joined = merge_learning_states(x, y)
assert joined['posterior'] == x['posterior'] and len(joined['posteriorHistory']['events']) == 3

def rejected(fn, status):
    try: fn()
    except HTTPException as e: assert e.status_code == status
    else: raise AssertionError('expected rejection')

other, _ = anchor({'posterior': [1 / 49] * 49, 'probeCount': 1})
rejected(lambda: merge(a, other), 409)
bad = copy.deepcopy(a); bad['posterior'][0] += .1
rejected(lambda: validate(bad), 409)
bad = copy.deepcopy(a); bad['posteriorHistory']['events']['a']['parents'] = ['missing']
rejected(lambda: validate(bad), 422)
bad = copy.deepcopy(a); bad['posteriorHistory']['events']['a']['parents'] = ['a']
rejected(lambda: validate(bad), 422)
bad = copy.deepcopy(a); bad['posteriorHistory']['events']['a']['rank'] = 2
bad['posterior'], bad['probeCount'] = replay(bad['posteriorHistory'])
rejected(lambda: merge(a, bad), 409)

# An iOS/JavaScript wrong answer can differ from the legacy server's
# division order in the very small failure probabilities, despite identical evidence.
fractional = {'algorithm':'bayes-grid-1', 'baseId':'empty', 'baseCount':0, 'base':None, 'events':{
    'failure': {'kind':'update', 'device':'client', 'at':'2026-10-27T08:34:11Z', 'day':'2026-10-27',
                'parents':[], 'rank':2389, 'resp':0, 'weight':0.2, 'guess':0.25}}}
client_post, count = replay(fractional, client_arithmetic=True)
legacy_post, _ = replay(fractional)
assert max(abs(x-y) for x,y in zip(client_post, legacy_post)) > 1e-11
valid_client = {'posteriorHistory':fractional, 'posterior':client_post, 'probeCount':count}
validate(valid_client)
validate({'posteriorHistory':fractional, 'posterior':legacy_post, 'probeCount':count})
tampered = copy.deepcopy(valid_client)
tampered['posterior'][0] += 1e-3; tampered['posterior'][1] -= 1e-3
rejected(lambda: validate(tampered), 409)
negative = copy.deepcopy(valid_client); negative['posterior'][-1] = -1e-12
rejected(lambda: validate(negative), 409)

# A device can pull a server-rounded history and append a client-rounded event.
mixed_history = {'algorithm':'bayes-grid-1', 'baseId':'empty', 'baseCount':0, 'base':None, 'events':{}}
specs = [(2331,0,.15,.25), (2009,1,1,.25), (2449,0,.15,.25)]
for i, (rank, resp, weight, guess) in enumerate(specs):
    mixed_history['events'][f'e{i}'] = {'kind':'update', 'device':'client', 'at':'2026-10-27T00:00:00Z',
        'day':'2026-10-27', 'parents':[f'e{i-1}'] if i else [], 'rank':rank, 'resp':resp, 'weight':weight, 'guess':guess}
prefix = copy.deepcopy(mixed_history); prefix['events'].pop('e2')
server_prefix, _ = replay(prefix)
suffix = {'algorithm':'bayes-grid-1', 'baseId':'prefix', 'baseCount':2, 'base':server_prefix,
          'events':{'e2':{**mixed_history['events']['e2'], 'parents':[]}}}
mixed_post, count = replay(suffix, client_arithmetic=True)
mixed_state = {'posteriorHistory':mixed_history, 'posterior':mixed_post, 'probeCount':count}
validate(mixed_state)
assert canonicalize(mixed_state)['posterior'] == replay(mixed_history)[0]
assert mixed_state['posterior'] == mixed_post  # Canonicalization does not mutate the input.

reset = {'posterior': None, 'probeCount': 0, 'placementVersion': {'counter': 1, 'device': 'device', 'id': '00000000-0000-4000-8000-000000000001'}}
assert merge_learning_states(a, reset)['posterior'] is None
assert merge_learning_states(reset, a)['posterior'] is None
print('PASS causal posterior merge, daily diffusion, reset and invalid evidence')
