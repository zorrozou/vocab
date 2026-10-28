"""A normal SIGTERM must remove the fixture's disposable databases."""
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

with tempfile.TemporaryDirectory(prefix='vocab-fixture-cleanup-test-') as directory:
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    env = {**os.environ, 'TMPDIR': directory, 'VOCAB_UI_PORT': str(port)}
    process = subprocess.Popen([sys.executable, 'tests/ui_stub_server.py'], env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(200):
            if process.poll() is not None:
                raise AssertionError(f'fixture exited before startup: {process.returncode}')
            try:
                with urllib.request.urlopen(f'http://127.0.0.1:{port}/api/v1/__ui_fixture', timeout=1) as response:
                    if response.read() == b'{"fixture":"vocab-ui-isolated-v1"}':
                        break
            except OSError:
                time.sleep(.1)
        else:
            raise AssertionError('fixture did not start')
        assert list(Path(directory).glob('vocab-ui-server-*'))
        process.send_signal(signal.SIGTERM)
        assert process.wait(timeout=20) == 0
        assert not list(Path(directory).glob('vocab-ui-server-*'))
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
print('PASS fixture SIGTERM removes its disposable data directory')
