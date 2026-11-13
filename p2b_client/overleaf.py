"""The 写作 page's Overleaf buttons for a project checked out on this Mac: the server asks, the runner does it here, in
the user's own working copy (the agent and any IDE edit the same files), and answers with what is there after. Same
steps as the server does with a checkout of its own (paper2brain/overleaf.py), with the user's git credentials."""
import base64
import os
import re
import subprocess
from pathlib import Path

WHO = ("-c", "user.name=paper2brain", "-c", "user.email=paper2brain@localhost")


def _git(path, *args, check=True):
    r = subprocess.run(["git", "-C", str(path), *args], capture_output=True, text=True, timeout=300,
                       env={**os.environ, "GIT_TERMINAL_PROMPT": "0", "GIT_SSH_COMMAND": "ssh -o BatchMode=yes"})
    if check and r.returncode:
        raise RuntimeError((r.stderr or r.stdout).strip()[-400:])
    return r.stdout if check else r


def status(path):
    """What is not on Overleaf yet: local commits and edits against the upstream branch, and new files."""
    base = "@{u}" if _git(path, "rev-parse", "--verify", "-q", "@{u}", check=False).returncode == 0 else "HEAD"
    files = [{"status": s, "file": f} for s, _, f in (line.partition("\t") for line in _git(path, "diff", base, "--name-status").splitlines()) if f]
    files += [{"status": "??", "file": f} for f in _git(path, "ls-files", "--others", "--exclude-standard").splitlines()]
    return {"head": _git(path, "rev-parse", "HEAD").strip(), "files": files, "diff": _git(path, "diff", base, "--no-color")[:200_000]}


def push(path, message):
    """Commit what is left (as the user, or as paper2brain where git has no name), rebase on Overleaf, push. On
    failure everything is back as it was before, uncommitted."""
    if not status(path)["files"]:
        raise RuntimeError("没有要推送的改动")
    who = () if _git(path, "config", "user.email", check=False).returncode == 0 else WHO
    _git(path, "add", "-A")
    committed = bool(_git(path, "diff", "--cached", "--name-only").strip())
    if committed:
        _git(path, *who, "commit", "--quiet", "-m", message or "paper2brain")
    try:
        _git(path, *who, "pull", "--rebase", "--quiet")
        _git(path, "push", "--quiet", "origin", "HEAD")
    except RuntimeError as e:
        if (path / ".git" / "rebase-merge").exists() or (path / ".git" / "rebase-apply").exists():
            _git(path, "rebase", "--abort")
        if committed:
            _git(path, "reset", "--soft", "HEAD~1")
        raise RuntimeError(f"推送失败，改动还留在本地（Overleaf 上可能改了同一处）：{e}") from None


def _main_tex(path):
    mains = [f for f in path.glob("*.tex") if re.search(r"\\documentclass", f.read_text(errors="replace"))]
    if not mains:
        raise RuntimeError("目录里没有含 \\documentclass 的 .tex 主文件")
    return next((f for f in mains if f.name == "main.tex"), sorted(mains)[0])


def compile(path):
    """latexmk into <folder>.build beside the checkout (aux files must not look like edits); the PDF goes back."""
    main = _main_tex(path)
    build = path.parent / (path.name + ".build")
    build.mkdir(parents=True, exist_ok=True)
    text = main.read_text(errors="replace")
    chinese = re.search(r"\\documentclass(?:\[[^\]]*\])?\{ctex(?:art|rep|book)\}", text) or any(
        p.strip() in {"ctex", "xeCJK", "fontspec"}
        for packages in re.findall(r"\\usepackage(?:\[[^\]]*\])?\{([^}]+)\}", text) for p in packages.split(","))
    cmd = ["latexmk", "-xelatex" if chinese else "-pdf", "-interaction=nonstopmode", "-halt-on-error", f"-outdir={build}", main.name]
    env = {**os.environ, "PATH": os.environ.get("PATH", "") + ":/Library/TeX/texbin"}  # MacTeX, missing from a launchd PATH
    try:
        r = subprocess.run(cmd, cwd=path, capture_output=True, text=True, timeout=600, env=env)
    except FileNotFoundError:
        raise RuntimeError("这台 Mac 没装 latexmk（MacTeX）：brew install --cask mactex") from None
    except subprocess.TimeoutExpired:
        raise RuntimeError("编译超过 10 分钟被中止") from None
    log, pdf = build / (main.stem + ".log"), build / (main.stem + ".pdf")
    tail = log.read_text(errors="replace")[-3000:] if log.is_file() else (r.stdout + r.stderr)[-3000:]
    if r.returncode or not pdf.is_file():
        excerpt = "\n".join(line for line in tail.splitlines() if line.startswith("!")) or tail[-1200:]
        raise RuntimeError(f"编译失败：\n{excerpt[:1500]}")
    return {"log": tail[-800:], "pdf": base64.b64encode(pdf.read_bytes()).decode()}


def handle(job):
    """A call from the server: {op: status | push | pull | discard | compile, path, message}."""
    path = Path(str(job.get("path") or "")).expanduser()
    if not (path / ".git").exists():
        raise RuntimeError(f"这台 Mac 上没有 {job.get('path')}：先把 Overleaf 项目 git clone 到那里，或在写作页改成正确的目录")
    op, out = job.get("op"), {}
    if op == "push":
        push(path, str(job.get("message") or ""))
    elif op == "pull":
        _git(path, "pull", "--ff-only", "--quiet")
    elif op == "discard":
        _git(path, "reset", "--hard", "--quiet")
        _git(path, "clean", "-fdq")
    elif op == "compile":
        out = compile(path)
    elif op != "status":
        raise RuntimeError(f"不认识的操作：{op}")
    return {**out, "status": status(path)}
