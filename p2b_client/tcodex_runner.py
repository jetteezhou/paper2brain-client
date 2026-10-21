"""TCodex for the paper2brain server, on this Mac (ops/tcodex.sh keeps it running): asks the server for TCodex runs
of the libraries whose agents this Mac runs, runs `tcodex exec` here (its ./p2b goes back to the server through
remote.py) and streams the answer back. Standard library only, like remote.py."""
import base64
import json
import os
import signal
import sys
import threading
import time
import urllib.error
import urllib.request

from . import server_and_token
from .codex import codex_turn

AT_ONCE = 3  # runs on this Mac at the same time; more wait on the server


def _post(server, token, path, body, timeout=60):
    req = urllib.request.Request(f"{server}{path}", data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def run_job(server, token, job):
    """One run, start to finish; the server can stop it at any progress report."""
    procs, last = [], [0.0]

    def report(**fields):
        try:
            return _post(server, token, "/api/tcodex/update", {"library": job["library"], "run_id": job["run_id"], **fields})["live"]
        except (urllib.error.URLError, OSError, ValueError, KeyError):
            return True  # the network hiccuped: keep going, the next report or the result catches up

    def progress(text, tools, session):
        if session or time.time() - last[0] > 1:
            last[0] = time.time()
            if not report(text=text, tools=tools, session=session) and procs:
                os.killpg(procs[0].pid, signal.SIGTERM)

    started = time.time()
    env = {"P2B_SERVER": server, "P2B_TOKEN": token, "P2B_AGENT_ID": job["agent_id"], "P2B_LIBRARY": job["library"]}
    images = [(base64.b64decode(i["data"]), i["mime"]) for i in job.get("images") or []]
    try:
        text, tools, error = codex_turn(job.get("session"), job["prompt"], images, job.get("model"), progress, procs.append, env)
    except Exception as e:
        text, tools, error = "", [], f"本机运行 tcodex 失败：{e}"
    report(text=text, tools=tools, done=True, error=error, duration_ms=int((time.time() - started) * 1000))


def main():
    server, token = server_and_token()
    if not server or not token:
        sys.exit("还没连上服务器：先运行 ./setup.sh")
    slots = threading.Semaphore(AT_ONCE)
    print(f"{time.strftime('%F %T')} 本机 TCodex 已连接 {server}", flush=True)
    while True:
        slots.acquire()
        try:
            job = _post(server, token, "/api/tcodex/claim", {}, timeout=60)["job"]
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
                run_job(server, token, job)
            finally:
                slots.release()

        threading.Thread(target=work, daemon=True).start()


if __name__ == "__main__":
    main()
