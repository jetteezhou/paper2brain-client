"""p2bot on this Mac: a task sent from the web page runs here in its own folder (~/p2bot/<task>/), on TCodex or DeepSeek
Harness, apart from paper2brain: no ./p2b, no librarian/, none of this Mac's paper2brain token in the agent's
environment; only a short-lived token of this one turn, with which the agent's `p2bot put` hands its files back.
Off until ./setup.sh --bot turns it on ("p2bot": true in the config)."""
import json
import os
import re
import shlex
import socket
import subprocess
import sys
import tempfile
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


def machine():
    """This Mac's name on the p2bot page: the worker's name from setup.sh, else the host's."""
    return config().get("machine") or socket.gethostname().split(".")[0]


def engines():
    from . import dsh
    return (["tcodex"] if tcodex_bin() else []) + (["dsh"] if dsh.dsh_bin() else [])


def folder(task_id, server="", token=""):
    """The task's folder, with bin/p2bot carrying this turn's server and token: Codex strips variables named like
    *TOKEN* / *KEY* from the commands its agent runs, so they cannot go through the environment."""
    if not task_id.isalnum():
        raise ValueError(f"bad task id: {task_id!r}")
    path = ROOT / task_id
    (path / "inputs").mkdir(parents=True, exist_ok=True)
    (path / "bin").mkdir(exist_ok=True)
    tool = path / "bin" / "p2bot"
    tool.write_text(f'#!/bin/sh\nP2BOT_SERVER={shlex.quote(server)} P2BOT_TURN={shlex.quote(token)} '
                    f'PYTHONPATH={shlex.quote(str(REPO))} exec python3 -m p2b_client.bot "$@"\n')
    tool.chmod(0o700)
    return path


def _get(server, token, path, dst):
    req = urllib.request.Request(f"{server}{path}", headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=600) as r, open(dst, "wb") as f:
        while chunk := r.read(1 << 20):
            f.write(chunk)


def run(server, job, report):
    """One turn: fetch the attachments, run the engine in the task's folder, report as the other runs do. A tool turn
    (job["tool"]) has no engine: the runner runs the server's script itself."""
    if job.get("tool"):
        return run_tool(server, job, report)
    from . import dsh
    started, procs = time.time(), []
    here = folder(job["task_id"], server, job["token"])
    for f in job.get("inputs") or []:
        dst = here / "inputs" / Path(f["name"]).name
        if not dst.exists() or dst.stat().st_size != f["size"]:
            _get(server, job["token"], f"/api/bot/run/inputs/{f['id']}", dst)
    env = {**{k: None for k in HIDDEN}, "PATH": f"{here / 'bin'}{os.pathsep}{PATH}"}

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


TOOL_CMD = re.compile(r"[a-z]{2,20}")  # a subcommand of the script the server ships with the turn; new ones need no client update
TOOL_TIMEOUT = 900


def run_tool(server, job, report):
    """Scan, apply a confirmed plan, undo it, make previews…: `python3 inputs/p2b-tools.py <argv>` in a scratch folder,
    no model and no shell; the JSON it writes goes back as the turn's result."""
    started, spec = time.time(), job["tool"]
    argv, out = [str(a) for a in spec.get("argv") or []], Path(str(spec.get("out") or "")).name
    text, result, error = "", None, None
    try:
        if not argv or not TOOL_CMD.fullmatch(argv[0]) or not out:
            raise RuntimeError(f"不认识的工具任务：{argv[:1]}")
        with tempfile.TemporaryDirectory(prefix="p2bot-tool-") as tmp:
            (Path(tmp) / "inputs").mkdir()
            for f in job.get("inputs") or []:
                _get(server, job["token"], f"/api/bot/run/inputs/{f['id']}", Path(tmp) / "inputs" / Path(f["name"]).name)
            p = subprocess.run([sys.executable, "inputs/p2b-tools.py", *argv], cwd=tmp, capture_output=True, text=True,
                               timeout=TOOL_TIMEOUT, env={k: v for k, v in os.environ.items() if k not in HIDDEN})
            text = (p.stdout.strip() or p.stderr.strip())[-2000:]
            if p.returncode:
                raise RuntimeError(p.stderr.strip()[-500:] or f"退出码 {p.returncode}")
            result = json.loads((Path(tmp) / out).read_text())
    except subprocess.TimeoutExpired:
        error = f"脚本超过 {TOOL_TIMEOUT // 60} 分钟，停了"
    except Exception as e:
        error = f"本机运行 p2b-tools 失败：{e}"
    report(True, text=text, tools=[], done=True, error=error, result=result, duration_ms=int((time.time() - started) * 1000))


# ---------- `p2bot put <file> ...`, what the agent runs ----------

def put(paths):
    server, token = os.environ.get("P2BOT_SERVER", "").rstrip("/"), os.environ.get("P2BOT_TURN", "")
    if not server or not token:
        sys.exit("p2bot put 只能在 p2bot 的任务目录里用（用 PATH 里的 p2bot，即任务目录下的 bin/p2bot）")
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
