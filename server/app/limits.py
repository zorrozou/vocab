"""Per-process request limits. The proxy must pass a trusted client address to Uvicorn."""
from collections import deque
from threading import Lock
from time import monotonic
from fastapi import HTTPException

# Protect expensive paths while permitting a normal batch of audio prefetches.
RULES = {'auth': (20, 60), 'personalize': (6, 60), 'sentence': (180, 60), 'tts': (300, 60), 'report': (60, 60), 'snapshot': (15, 60), 'snapshot_read': (600, 60), 'state_changes': (600, 60), 'fsrs_resolve': (120, 60), 'state_delta_write': (120, 60)}
MAX_KEYS = 10000
_lock = Lock()
_windows = {}


def check_rate(request, bucket):
    # Direct function calls in isolated unit tests do not have an HTTP Request.
    if request is None:
        return
    limit, period = RULES[bucket]
    host = request.client.host if request.client else 'unknown'
    key = (bucket, host)
    now = monotonic()
    with _lock:
        if key not in _windows and len(_windows) >= MAX_KEYS:
            for existing, times in list(_windows.items()):
                if not times or now - times[-1] >= RULES[existing[0]][1]:
                    del _windows[existing]
            if len(_windows) >= MAX_KEYS:
                raise HTTPException(429, '请求过多，请稍后重试', headers={'Retry-After': '60'})
        times = _windows.setdefault(key, deque())
        while times and now - times[0] >= period:
            times.popleft()
        if len(times) >= limit:
            retry = max(1, int(period - (now - times[0])) + 1)
            raise HTTPException(429, '请求过多，请稍后重试', headers={'Retry-After': str(retry)})
        times.append(now)
