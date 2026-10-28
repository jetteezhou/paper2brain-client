"""Runs the server's agent work on this Mac (ops/runner.sh keeps it running): asks the server for runs of the libraries
whose agents this Mac runs, then either starts them at Cursor with your key (the agent works on this Mac's worker)
or runs `tcodex exec` here, and streams the answer back; its ./p2b goes back to the server through remote.py. It also
makes the server's quick search API calls, with the key and proxy here."""
import base64
import json
import os
import signal
import sys
import threading
import time
import urllib.error
import urllib.request

from . import CONFIG, api, config, cursor, server_and_token
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
        text, tools, status, duration, error, usage = cursor.follow(key, job["agent_id"], run["id"], lambda t, tl: report(text=t, tools=tl))
    except Exception as e:
        text, tools, status, duration, error, usage = "", [], "ERROR", None, str(e) if str(e).startswith("Cursor API") else f"本机调用 Cursor 失败：{e}", {}
    report(True, text=text, tools=tools, done=True, status=status, error=error, duration_ms=duration or int((time.time() - started) * 1000),
           usage=usage)


def run_codex(server, token, job):
    report, procs, started = _reporter(server, token, job), [], time.time()

    def progress(text, tools, session):
        if not report(bool(session), text=text, tools=tools, session=session) and procs:
            os.killpg(procs[0].pid, signal.SIGTERM)

    env = {"P2B_SERVER": server, "P2B_TOKEN": token, "P2B_AGENT_ID": job["agent_id"], "P2B_LIBRARY": job["library"]}
    images = [(base64.b64decode(i["data"]), i["mime"]) for i in job.get("images") or []]
    try:
        text, tools, error, usage = codex_turn(job.get("session"), job["prompt"], images, job.get("model"), progress, procs.append, env)
    except Exception as e:
        text, tools, error, usage = "", [], f"本机运行 tcodex 失败：{e}", {}
    report(True, text=text, tools=tools, done=True, error=error, duration_ms=int((time.time() - started) * 1000), usage=usage)


def run_api(server, token, job, search, proxy):
    """A quick search call or settings update the server waits for: answer it, or say what went wrong."""
    try:
        if job.get("op") == "configure":
            cfg, settings = config(), job.get("settings") or {}
            old = cfg.get("search_api") or {}
            if settings.get("base_url"):
                cfg["search_api"] = {**settings, "api_key": settings.get("api_key") or old.get("api_key", "")}
            else:
                cfg.pop("search_api", None)
            CONFIG.write_text(json.dumps(cfg, ensure_ascii=False, indent=2))
            os.chmod(CONFIG, 0o600)
            fields = {"result": {"ok": True, "search_api": api.public(cfg.get("search_api"))}}
        else:
            do = api.web if job.get("op") == "web" else api.chat
            fields = {"result": do(search, str(job.get("prompt") or ""), min(int(job.get("timeout") or 30), 60), proxy)}
    except Exception as e:
        fields = {"error": str(e)}
    try:
        _post(server, token, "/api/runner/update", {"call_id": job["call_id"], **fields})
    except (urllib.error.URLError, OSError, ValueError):
        pass  # the server gives up waiting by itself


def main():
    server, token = server_and_token()
    cfg = config()
    key, machine, search, proxy = cfg.get("cursor_api_key"), cfg.get("machine"), cfg.get("search_api"), cfg.get("proxy")
    if not server or not token:
        sys.exit("还没连上服务器：先运行 ./setup.sh")
    backends = (["cursor"] if key and machine else []) + (["tcodex"] if tcodex_bin() else []) + ["config"] + (["api"] if api.ready(search) else [])
    print(f"{time.strftime('%F %T')} 已连接 {server}，本机可用：{'、'.join(b for b in backends if b != 'config') or '无（缺 Cursor key、tcodex 和快速搜索接口）'}"
          + (f"，快速搜索走代理 {proxy}" if proxy and "api" in backends else ""), flush=True)
    busy, lock, models, models_at = [0], threading.Lock(), None, 0.0
    while True:
        search = config().get("search_api")  # the web settings take effect without restarting this runner
        backends = [b for b in backends if b != "api"] + (["api"] if api.ready(search) else [])
        if "cursor" in backends and time.time() - models_at > MODELS_EVERY:
            try:
                models, models_at = cursor.models(key), time.time()
            except Exception as e:
                print(f"{time.strftime('%F %T')} 读不到 Cursor 模型列表：{e}", flush=True)
                models_at = time.time() - MODELS_EVERY + 60
        with lock:
            full = busy[0] >= AT_ONCE
        # full of runs: keep asking, but only for search calls and settings, which are short and someone is waiting on
        take = [b for b in backends if b in ("api", "config")] if full else backends
        try:
            job = _post(server, token, "/api/runner/claim", {"backends": backends, "take": take, "machine": machine, "models": models,
                                                             "search_api": api.public(search)}, timeout=60)["job"] if take else time.sleep(1)
        except (urllib.error.URLError, OSError, ValueError, KeyError) as e:
            print(f"{time.strftime('%F %T')} 连不上服务器：{getattr(e, 'reason', e)}，15 秒后重试", flush=True)
            time.sleep(15)
            continue
        if not job:
            continue
        run = job["backend"] not in ("api", "config")

        def work(job=job, run=run, search=search):
            try:
                if not run:
                    run_api(server, token, job, search, proxy)
                elif job["backend"] == "cursor":
                    run_cursor(server, token, job, key, machine)
                else:
                    run_codex(server, token, job)
            finally:
                if run:
                    with lock:
                        busy[0] -= 1

        if run:
            with lock:
                busy[0] += 1
        threading.Thread(target=work, daemon=True).start()


if __name__ == "__main__":
    main()
