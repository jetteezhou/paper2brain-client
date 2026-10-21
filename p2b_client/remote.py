"""./p2b: the command runs on the paper2brain server, as this user, in the library whose agent is asking (the server
finds it from the agent id). Files named by --file / --image go along; figures and diagrams the server returns are
written here; a code repo is checked out here at the server's commit; ./p2b guide writes the librarian specs here."""
import base64
import hashlib
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

from . import HOME, REPO, server_and_token

CACHE = HOME / "cache"


def _fail(error, code=2):
    print(json.dumps({"ok": False, "error": error}, ensure_ascii=False, indent=1))
    sys.exit(code)


def files_of(argv):
    """--file=x becomes --file x; each --file / --image value goes along with its content ("-": standard input)."""
    out, files = [], {}
    for a in argv:
        flag, eq, value = a.partition("=")
        out += [flag, value] if eq and flag in ("--file", "--image") else [a]
    for i in range(1, len(out)):
        if out[i - 1] in ("--file", "--image"):
            try:
                data = sys.stdin.buffer.read() if out[i] == "-" else Path(out[i]).expanduser().read_bytes()
            except OSError as e:
                _fail(f"读不到 {out[i]}：{e.strerror}")
            files[out[i]] = base64.b64encode(data).decode()
    return out, files


def localize(value, local):
    if isinstance(value, str):
        return local.get(value, value)
    if isinstance(value, list):
        return [localize(v, local) for v in value]
    if isinstance(value, dict):
        return {k: localize(v, local) for k, v in value.items()}
    return value


def _checkout(repo):
    """The server's checkout is not reachable from here: read the same commit from a clone on this Mac."""
    if not str(repo.get("url", "")).startswith("https://") or not repo.get("head"):
        return repo
    path = CACHE / "repos" / repo["id"]
    git = lambda *a: subprocess.run(["git", "-C", str(path), *a], capture_output=True, text=True)  # noqa: E731
    if not path.is_dir():
        path.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "clone", "--quiet", repo["url"], str(path)], capture_output=True)
    if git("cat-file", "-e", repo["head"]).returncode:
        git("fetch", "--quiet", "origin")
    if git("checkout", "--quiet", "--detach", repo["head"]).returncode:
        return {**repo, "note": f"没能在本机检出 {repo['url']} 的 {repo['head']}，path 是服务器上的路径，读不到"}
    return {**repo, "path": str(path)}


def write_guide(docs, folder=REPO / "librarian"):
    folder.mkdir(exist_ok=True)
    for old in folder.glob("*.md"):
        if old.name not in docs:
            old.unlink()
    for name, text in docs.items():
        if "/" not in name and name.endswith(".md"):
            (folder / name).write_text(text)
    return {"updated": sorted(docs), "folder": str(folder)}


def main(argv=None):
    server, token = server_and_token()
    if not server or not token:
        _fail("还没连上服务器：在网页的 Agent 设置里生成本机 agent 的口令，再运行 ./setup.sh")
    argv, files = files_of(sys.argv[1:] if argv is None else argv)
    # a Cursor agent's shell has its id; a TCodex run gets ours from tcodex_runner.py
    agent_id = os.environ.get("P2B_AGENT_ID") or os.environ.get("CURSOR_CONVERSATION_ID")
    body = {"argv": argv, "files": files, "agent_id": agent_id, "library": os.environ.get("P2B_LIBRARY")}
    req = urllib.request.Request(f"{server}/api/cli", data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=900) as r:
            got = json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:
            error = json.loads(e.read()).get("error")
        except ValueError:
            error = None
        _fail(error or f"服务器返回 {e.code}", 2 if e.code == 400 else 1)
    except (urllib.error.URLError, OSError) as e:
        _fail(f"连不上 {server}：{getattr(e, 'reason', e)}", 1)
    out = got.get("out")
    if isinstance(out, dict) and set(out) == {"help"}:
        print(out["help"])
        return
    local = {}
    for path, data in (got.get("files") or {}).items():
        mine = CACHE / "files" / hashlib.sha1(path.encode()).hexdigest()[:16] / Path(path).name
        mine.parent.mkdir(parents=True, exist_ok=True)
        mine.write_bytes(base64.b64decode(data))
        local[path] = str(mine)
    out = localize(out, local)
    if argv[:1] == ["repo"] and isinstance(out, dict):
        out = _checkout(out)
    if argv[:1] == ["guide"] and isinstance(out, dict):
        out = write_guide(out.get("docs") or {})
    if out is not None:
        print(json.dumps(out, ensure_ascii=False, indent=1, default=str))
