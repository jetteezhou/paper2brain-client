"""Runs the server's agent work on this Mac (ops/runner.sh keeps it running): asks the server for runs of the libraries
whose agents this Mac runs, then either starts them at Cursor with your key (the agent works on this Mac's worker)
or runs `tcodex exec` here, and streams the answer back. Its ./p2b goes back to the server through remote.py."""
import base64
import json
import os
import signal
import sys
import threading
import time
import urllib.error
import urllib.request

from . import config, cursor, server_and_token
from .codex import codex_turn, tcodex_bin

AT_ONCE = 5  # runs on this Mac at the same time; more wait on the server
MODELS_EVERY = 600


def _post(server, token, path, body, timeout=60):
    req = urllib.request.Request(f"{server}{path}", data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def _reporter(server, token, job):
    last = [0.0]

    def report(force=False, **fields):
        """Sends progress (at most once a second unless forced); False when the run was stopped on the server."""
        if not force and time.time() - last[0] < 1:
            return True
        last[0] = time.time()
        try:
            return _post(server, token, "/api/runner/update", {"library": job["library"], "run_id": job["run_id"], **fields})["live"]
        except (urllib.error.URLError, OSError, ValueError, KeyError):
            return True  # the network hiccuped: keep going, the next report or the result catches up
    return report


def run_cursor(server, token, job, key, machine):
    report, started = _reporter(server, token, job), time.time()
    try:
        run = cursor.start(key, job, machine, job.get("images") or [])
        text, tools, status, duration, error = cursor.follow(key, job["agent_id"], run["id"], lambda t, tl: report(text=t, tools=tl))
    except Exception as e:
        text, tools, status, duration, error = "", [], "ERROR", None, str(e) if str(e).startswith("Cursor API") else f"本机调用 Cursor 失败：{e}"
    report(True, text=text, tools=tools, done=True, status=status, error=error, duration_ms=duration or int((time.time() - started) * 1000))


def run_codex(server, token, job):
    report, procs, started = _reporter(server, token, job), [], time.time()

    def progress(text, tools, session):
        if not report(bool(session), text=text, tools=tools, session=session) and procs:
            os.killpg(procs[0].pid, signal.SIGTERM)

    env = {"P2B_SERVER": server, "P2B_TOKEN": token, "P2B_AGENT_ID": job["agent_id"], "P2B_LIBRARY": job["library"]}
    images = [(base64.b64decode(i["data"]), i["mime"]) for i in job.get("images") or []]
    try:
        text, tools, error = codex_turn(job.get("session"), job["prompt"], images, job.get("model"), progress, procs.append, env)
    except Exception as e:
        text, tools, error = "", [], f"本机运行 tcodex 失败：{e}"
    report(True, text=text, tools=tools, done=True, error=error, duration_ms=int((time.time() - started) * 1000))


def main():
    server, token = server_and_token()
    cfg = config()
    key, machine = cfg.get("cursor_api_key"), cfg.get("machine")
    if not server or not token:
        sys.exit("还没连上服务器：先运行 ./setup.sh")
    backends = (["cursor"] if key and machine else []) + (["tcodex"] if tcodex_bin() else [])
    print(f"{time.strftime('%F %T')} 已连接 {server}，本机可用：{'、'.join(backends) or '无（缺 Cursor key 或 tcodex）'}", flush=True)
    slots, models, models_at = threading.Semaphore(AT_ONCE), None, 0.0
    while True:
        if "cursor" in backends and time.time() - models_at > MODELS_EVERY:
            try:
                models, models_at = cursor.models(key), time.time()
            except Exception as e:
                print(f"{time.strftime('%F %T')} 读不到 Cursor 模型列表：{e}", flush=True)
                models_at = time.time() - MODELS_EVERY + 60
        slots.acquire()
        try:
            job = _post(server, token, "/api/runner/claim", {"backends": backends, "machine": machine, "models": models}, timeout=60)["job"]
        except (urllib.error.URLError, OSError, ValueError, KeyError) as e:
            slots.release()
            print(f"{time.strftime('%F %T')} 连不上服务器：{getattr(e, 'reason', e)}，15 秒后重试", flush=True)
            time.sleep(15)
            continue
        if not job:
            slots.release()
            continue

        def work(job=job):
            try:
                run_cursor(server, token, job, key, machine) if job["backend"] == "cursor" else run_codex(server, token, job)
            finally:
                slots.release()

        threading.Thread(target=work, daemon=True).start()


if __name__ == "__main__":
    main()
