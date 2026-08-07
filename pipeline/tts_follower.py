# -*- coding: utf-8 -*-
"""音频跟随器：跟踪例句生成，新句一入库立刻生成对应音频
- 每 10 秒轮询 sentence 表，找出还没有音频的 llm-% 例句
- 进程池并发生成（默认 8 工人），临时文件+原子改名防并发写冲突
- 量产进程结束且没有新句子时自动退出；可重复启动
用法: python tts_follower.py [--workers 8] [--interval 10]
"""
import argparse, asyncio, hashlib, os, sqlite3, subprocess, threading, time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import edge_tts

ROOT = Path(__file__).resolve().parent
DB = ROOT / "data" / "lexicon_v0.1.sqlite"
TTS_DIR = ROOT / "data" / "tts_cache"
TTS_DIR.mkdir(exist_ok=True)
VOICE = os.environ.get("TTS_VOICE", "en-US-AriaNeural")


def key_of(text):
    return hashlib.sha1(f"{VOICE}|{text}".encode()).hexdigest()[:16]


def pool_alive():
    r = subprocess.run(["pgrep", "-f", "gen_tiers_pool.py"], capture_output=True)
    return r.returncode == 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--interval", type=int, default=10)
    args = ap.parse_args()
    print(f"音频跟随器启动（嗓音 {VOICE}，{args.workers} 并发，{args.interval}s 轮询）", flush=True)

    done_total = 0
    idle_rounds = 0

    def gen(text):
        f = TTS_DIR / (key_of(text) + ".mp3")
        if f.exists():
            return True
        tmp = TTS_DIR / (key_of(text) + f".{os.getpid()}{threading.get_ident()}.tmp")
        try:
            asyncio.run(edge_tts.Communicate(text, VOICE).save(str(tmp)))
            os.replace(tmp, f)   # 原子改名，避免与预热脚本写冲突
            return True
        except Exception:
            try:
                tmp.unlink(missing_ok=True)
            except Exception:
                pass
            return False

    while True:
        conn = sqlite3.connect(DB, timeout=30)
        rows = [r[0] for r in conn.execute(
            "SELECT text FROM sentence WHERE genMethod LIKE 'llm-%' ORDER BY id DESC LIMIT 4000")]
        conn.close()
        todo = [t for t in rows if not (TTS_DIR / (key_of(t) + ".mp3")).exists()]

        if todo:
            idle_rounds = 0
            made = [0]
            lock = threading.Lock()

            def run(t):
                if gen(t):
                    with lock:
                        made[0] += 1

            with ThreadPoolExecutor(max_workers=args.workers) as ex:
                list(ex.map(run, todo))
            done_total += made[0]
            print(f"[{time.strftime('%H:%M:%S')}] 新增音频 {made[0]} 条（累计 {done_total}）", flush=True)
        else:
            idle_rounds += 1
            if not pool_alive() and idle_rounds >= 3:
                print(f"量产已结束且音频补齐，跟随器退出（共生成 {done_total} 条）", flush=True)
                break
            print(f"[{time.strftime('%H:%M:%S')}] 无新句，等待中…", flush=True)

        time.sleep(args.interval)


if __name__ == "__main__":
    main()
