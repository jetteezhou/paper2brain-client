"""One `tcodex exec` turn on this Mac, in this checkout (so its ./p2b goes to the server). The same reading of
TCodex's JSON events as the server repo's single-user TCodex backend (paper2brain/cursor_api.py, codex_turn)."""
import json
import os
import shutil
import subprocess
import tempfile

from . import REPO

# launchd starts us with only the system PATH; tcodex (and the node an npm install needs) usually live here
PATH = os.pathsep.join([os.environ.get("PATH", ""), os.path.expanduser("~/.local/bin"), "/opt/homebrew/bin", "/usr/local/bin"])


def tcodex_bin():
    return shutil.which("tcodex", path=PATH)


def _short(args):
    """Tool arguments for display only: the command or path, not file contents."""
    if not isinstance(args, dict):
        return None
    for key in ("command", "path", "target_file", "query", "pattern"):
        if args.get(key):
            return str(args[key])[:300]
    return None


def _args(session, text, images, model):
    # unsandboxed like a Cursor worker: the librarian needs the network and runs ./p2b
    args = [tcodex_bin() or "tcodex", "exec", "--json", "--skip-git-repo-check", "--dangerously-bypass-approvals-and-sandbox", "-C", str(REPO)]
    if model:
        args += ["-m", model["id"]]
        args += [a for p in model.get("params") or [] if p["id"] == "effort" for a in ("-c", f"model_reasoning_effort={p['value']}")]
    args += [f"--image={path}" for path in images]
    return args + (["resume", session, text] if session else [text])


def codex_turn(session, text, images, model, progress, started=None, env=None):
    """images: [(bytes, mime)]. progress(text, tools, new session id or None) after each event; started(process) lets
    the caller stop it. Returns (text, tools, error, usage): tokens summed over its turn.completed events."""
    out, tools, error, notice, usage = "", {}, None, None, {}
    with tempfile.TemporaryDirectory() as tmp:
        paths = []
        for i, (data, mime) in enumerate(images):
            paths.append(os.path.join(tmp, f"{i}.{mime.split('/')[-1]}"))
            with open(paths[-1], "wb") as f:
                f.write(data)
        with open(os.path.join(tmp, "stderr"), "w+") as err, \
                subprocess.Popen(_args(session, text, paths, model), cwd=REPO, stdin=subprocess.DEVNULL,
                                 env={**os.environ, "PATH": PATH, **(env or {})}, stdout=subprocess.PIPE, stderr=err, text=True,
                                 start_new_session=True) as p:
            if started:
                started(p)
            for line in p.stdout:
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                kind, item, new = ev.get("type"), ev.get("item") or {}, None
                if kind == "thread.started":
                    new = ev["thread_id"]
                elif kind == "turn.completed":  # input includes its cached part, output its reasoning
                    u = ev.get("usage") or {}
                    for mine, theirs in (("input_tokens", "input_tokens"), ("cached_tokens", "cached_input_tokens"), ("output_tokens", "output_tokens")):
                        if isinstance(u.get(theirs), int):
                            usage[mine] = usage.get(mine, 0) + u[theirs]
                    continue
                elif kind == "turn.failed":
                    error = (ev.get("error") or {}).get("message")
                elif kind == "error":  # also "Reconnecting... 2/5" mid-turn: fatal only if the turn fails or the process exits non-zero
                    notice = ev.get("message")
                elif item.get("type") == "agent_message":
                    out = item.get("text") or out
                elif item.get("type") in ("command_execution", "file_change", "mcp_tool_call", "web_search"):
                    tools[item["id"]] = {"name": item.get("tool") or item["type"], "status": "done" if kind == "item.completed" else "running",
                                         "args": _short(item) or _short({"path": ", ".join(c.get("path", "") for c in item.get("changes") or [])})}
                else:
                    continue
                progress(out, list(tools.values()), new)
            p.wait()
            err.seek(0)
            if p.returncode and not error:
                error = notice or err.read()[-300:].strip() or f"tcodex 退出码 {p.returncode}"
    return out, list(tools.values()), error, usage
