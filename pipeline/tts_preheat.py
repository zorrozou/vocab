# -*- coding: utf-8 -*-
"""全量音频预生成：词库全部单词 + 全部 LLM 例句 → edge-tts → tts_cache
缓存命名与 API 一致：sha1(f"{voice}|{text}")[:16].mp3，磁盘持久化，重启不丢
用法: python tts_preheat.py（可重复跑，已存在的自动跳过）
"""
import asyncio, hashlib, os, sqlite3, threading, time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import edge_tts

ROOT = Path(__file__).resolve().parent
DB = ROOT / "data" / "lexicon_v0.1.sqlite"
TTS_DIR = ROOT / "data" / "tts_cache"
TTS_DIR.mkdir(exist_ok=True)
VOICE = os.environ.get("TTS_VOICE", "en-US-AriaNeural")
WORKERS = 8


def key_of(text):
    return hashlib.sha1(f"{VOICE}|{text}".encode()).hexdigest()[:16] + ".mp3"


def main():
    conn = sqlite3.connect(DB, timeout=30)
    words = [r[0] for r in conn.execute("SELECT word FROM lexicon_entry")]
    sents = [r[0] for r in conn.execute("SELECT text FROM sentence WHERE genMethod LIKE 'llm-%'")]
    conn.close()
    todo = [t for t in words + sents if not (TTS_DIR / key_of(t)).exists()]
    print(f"单词 {len(words)} + 例句 {len(sents)}，待生成 {len(todo)} 条音频（嗓音 {VOICE}）", flush=True)

    lock = threading.Lock()
    done = [0]
    fail = [0]

    def gen(text):
        f = TTS_DIR / key_of(text)
        if f.exists():
            return
        try:
            asyncio.run(edge_tts.Communicate(text, VOICE).save(str(f)))
        except Exception as e:
            with lock:
                fail[0] += 1
                if fail[0] % 50 == 1:
                    print(f"✗ {text[:30]}: {e}", flush=True)
            return
        with lock:
            done[0] += 1
            if done[0] % 300 == 0:
                print(f"[{done[0]}/{len(todo)}]", flush=True)

    t0 = time.time()
    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        list(ex.map(gen, todo))
    print(f"完成 {done[0]}/{len(todo)}，失败 {fail[0]}，耗时 {(time.time() - t0) / 60:.1f} 分钟", flush=True)


if __name__ == "__main__":
    main()
