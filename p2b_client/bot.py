"""p2bot on this Mac: a task sent from the web page runs here in its own folder (~/p2bot/<task>/), on TCodex or DeepSeek
Harness, apart from paper2brain: no ./p2b, no librarian/, none of this Mac's paper2brain token in the agent's
environment; only a short-lived token of this one turn, with which the agent's `p2bot put` hands its files back.
Off until ./setup.sh --bot turns it on ("p2bot": true in the config)."""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from . import REPO, config
from .codex import PATH, codex_turn, tcodex_bin

ROOT = Path(os.environ.get("P2BOT_HOME") or Path.home() / "p2bot")
# what the runner has in its environment and the agent must not inherit
HIDDEN = ("P2B_TOKEN", "P2B_SERVER", "P2B_AGENT_ID", "P2B_LIBRARY", "CURSOR_API_KEY")


def enabled():
    return config().get("p2bot") is True


def engines():
    from . import dsh
    return (["tcodex"] if tcodex_bin() else []) + (["dsh"] if dsh.dsh_bin() else [])


def folder(task_id):
    if not task_id.isalnum():
        raise ValueError(f"bad task id: {task_id!r}")
    path = ROOT / task_id
    (path / "inputs").mkdir(parents=True, exist_ok=True)
    (path / "bin").mkdir(exist_ok=True)
    tool = path / "bin" / "p2bot"
    tool.write_text(f'#!/bin/sh\nPYTHONPATH="{REPO}" exec python3 -m p2b_client.bot "$@"\n')
    tool.chmod(0o755)
    return path


def _get(server, token, path, dst):
    req = urllib.request.Request(f"{server}{path}", headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=600) as r, open(dst, "wb") as f:
        while chunk := r.read(1 << 20):
            f.write(chunk)


def run(server, job, report):
    """One turn: fetch the attachments, run the engine in the task's folder, report as the other runs do."""
    from . import dsh
    started, procs = time.time(), []
    here = folder(job["task_id"])
    for f in job.get("inputs") or []:
        dst = here / "inputs" / Path(f["name"]).name
        if not dst.exists() or dst.stat().st_size != f["size"]:
            _get(server, job["token"], f"/api/bot/run/inputs/{f['id']}", dst)
    env = {**{k: None for k in HIDDEN}, "P2BOT_SERVER": server, "P2BOT_TOKEN": job["token"], "PATH": f"{here / 'bin'}{os.pathsep}{PATH}"}

    def progress(text, tools, session):
        if not report(bool(session), text=text, tools=tools, session=session) and procs:
            import signal
            os.killpg(procs[0].pid, signal.SIGTERM)

    turn = dsh.dsh_turn if job["engine"] == "dsh" else codex_turn
    try:
        text, tools, error, usage = turn(job.get("session"), job["prompt"], [], job.get("model"), progress, procs.append, env, here)
    except Exception as e:
        text, tools, error, usage = "", [], f"本机运行 p2bot 失败：{e}", {}
    report(True, text=text, tools=tools, done=True, error=error, duration_ms=int((time.time() - started) * 1000), usage=usage)


# ---------- `p2bot put <file> ...`, what the agent runs ----------

def put(paths):
    server, token = os.environ.get("P2BOT_SERVER", "").rstrip("/"), os.environ.get("P2BOT_TOKEN", "")
    if not server or not token:
        sys.exit("p2bot put 只能在 p2bot 的任务里用（缺 P2BOT_SERVER / P2BOT_TOKEN）")
    out, failed = [], False
    for p in paths:
        path = Path(p)
        if not path.is_file():
            print(json.dumps({"ok": False, "file": p, "error": "不是文件"}, ensure_ascii=False))
            failed = True
            continue
        with path.open("rb") as f:
            req = urllib.request.Request(f"{server}/api/bot/run/put?name={urllib.parse.quote(path.name)}", data=f, method="PUT",
                                         headers={"Authorization": f"Bearer {token}", "Content-Type": "application/octet-stream",
                                                  "Content-Length": str(path.stat().st_size)})
            try:
                with urllib.request.urlopen(req, timeout=1800) as r:
                    out.append(json.loads(r.read()))
            except urllib.error.HTTPError as e:
                try:
                    error = json.loads(e.read()).get("error")
                except (ValueError, OSError):
                    error = None
                print(json.dumps({"ok": False, "file": p, "error": error or f"服务器返回 {e.code}"}, ensure_ascii=False))
                failed = True
            except (urllib.error.URLError, OSError) as e:
                print(json.dumps({"ok": False, "file": p, "error": f"连不上服务器：{getattr(e, 'reason', e)}"}, ensure_ascii=False))
                failed = True
    if out:
        print(json.dumps({"ok": True, "delivered": [{"name": x["name"], "size": x["size"]} for x in out]}, ensure_ascii=False))
    sys.exit(1 if failed else 0)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] != ["put"] or len(argv) < 2:
        sys.exit("用法：p2bot put <文件> [<文件> ...]   把成品交回网页")
    put(argv[1:])


if __name__ == "__main__":
    main()
