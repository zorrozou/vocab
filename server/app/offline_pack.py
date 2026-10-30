"""Versioned public text/question packs. No account state or audio in this format."""
import hashlib
import json
import os
from pathlib import Path
import threading

_lock = threading.Lock()
FORMAT = 1
PAGE_WORDS = 128


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False).encode()


def build_pack(root, revision, words, detail, quiz, alternatives):
    directory = Path(root) / f'v{FORMAT}-{revision}'
    with _lock:
        manifest_file = directory / 'manifest.json'
        if manifest_file.is_file():
            return json.loads(manifest_file.read_bytes())
        directory.mkdir(parents=True, exist_ok=True)
        index, pages = {}, []
        for offset in range(0, len(words), PAGE_WORDS):
            page, entries = len(pages), {}
            for word in words[offset:offset + PAGE_WORDS]:
                value = detail(word)
                forward = quiz(word, value['pos'], 'forward')
                reverse = quiz(word, value['pos'], 'reverse')
                for question in (forward, reverse):
                    options = question.get('options', [])
                    if len(options) != 4 or sum(bool(o.get('ok')) for o in options) != 1 or len({o['text'] for o in options}) != 4:
                        raise ValueError('Invalid offline question: ' + word)
                entries[word] = {'detail': value, 'forward': forward, 'reverse': reverse,
                                 'alternatives': alternatives(word)}
                index[word] = page
            raw = encoded({'format': FORMAT, 'revision': revision, 'page': page, 'entries': entries})
            target = directory / f'{page}.json'
            temporary = target.with_suffix('.tmp')
            temporary.write_bytes(raw)
            os.replace(temporary, target)
            pages.append({'page': page, 'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(), 'words': len(entries)})
        manifest = {'format': FORMAT, 'revision': revision, 'words': len(index), 'index': index,
                    'pages': pages, 'bytes': sum(p['bytes'] for p in pages)}
        temporary = manifest_file.with_suffix('.tmp')
        temporary.write_bytes(encoded(manifest))
        os.replace(temporary, manifest_file)
        return manifest
