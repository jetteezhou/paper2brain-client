"""One DeepSeek Harness (`dsh --profile headless --json`) turn on this Mac, in this checkout (so its ./p2b goes to the
server), and the models its desktop app offers. The same as the server repo's single-user dsh backend
(paper2brain/cursor_api.py: dsh_turn, dsh_models)."""
import json
import os
import re
import shutil
import subprocess
import tempfile

from . import REPO
from .codex import PATH, _short

DSH_APP = "/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh"  # the desktop app's own CLI


def dsh_bin():
    return shutil.which("dsh", path=PATH) or (DSH_APP if os.access(DSH_APP, os.X_OK) else None)


def _desktop_patch():
    """The desktop app's settings (custom providers and models, the model picked there): headless runs with them too."""
    path = os.path.join(os.environ.get("DSH_HOME") or os.path.expanduser("~/.dsh"), "profiles", "desktop", "cordis.patch.yml")
    return path if os.path.exists(path) else None


def models():
    """"默认" (the model picked in the desktop app) and each custom model its settings define, as provider/model."""
    items = [{"id": "default", "displayName": "DeepSeek Harness · 默认（桌面端选的模型）"}]
    path = _desktop_patch()
    for provider, model, efforts in _pi_ai_models(open(path, encoding="utf-8").read()) if path else []:
        items.append({"id": f"{provider}/{model}", "displayName": f"DeepSeek Harness · {model}",
                      **({"parameters": [{"id": "effort", "displayName": "思考强度", "values": [{"value": e} for e in efforts]}]} if efforts else {})})
    return items


def _pi_ai_models(text):
    """[(provider, model id, reasoning efforts)] of the llm-pi-ai entry in a dsh patch file.
    ponytail: reads block-style YAML as the desktop app writes it (`- id:` first in each model)."""
    out, entry, providers, provider, efforts = [], False, None, None, None
    for line in text.splitlines():
        s, indent = line.strip(), len(line) - len(line.lstrip())
        if not s or s.startswith("#"):
            continue
        if indent == 0:
            entry, providers, provider, efforts = s == "- id: llm-pi-ai", None, None, None
            continue
        if not entry:
            continue
        if efforts is not None and indent > efforts:
            out[-1][2].append(s.split(":")[0].strip("'\""))
            continue
        efforts = None
        if s == "providers:":
            providers = indent
        elif providers is not None and indent <= providers:
            providers = provider = None
        elif providers is not None and indent == providers + 2 and s.endswith(":"):
            provider = s[:-1].strip("'\"")
        elif provider and s.startswith("- id:"):
            out.append((provider, s[5:].strip().strip("'\""), []))
        elif provider and out and s == "reasoningEfforts:":
            efforts = indent
    return out


def _pick(model):
    """(provider, model, effort) to run: "default" is the model picked in the desktop app; with no effort chosen, medium
    when the model offers it, since dsh's own default sends "none", which OpenAI's gpt-5+ refuse."""
    provider, _, name = ((model or {}).get("id") or "").partition("/")
    effort = next((p["value"] for p in (model or {}).get("params") or [] if p["id"] == "effort"), None)
    path = _desktop_patch()
    try:
        text = open(path, encoding="utf-8").read() if path else ""
    except OSError:
        text = ""
    if not name:
        m = re.search(r"^- id: agent-default-model\n(?:  .*\n)*?    provider: (\S+)\n    model: (\S+)", text + "\n", re.M)
        provider, name = (m.group(1).strip("'\""), m.group(2).strip("'\"")) if m else ("", "")
    if name and not effort:
        offered = next((e for p, n, e in _pi_ai_models(text) if (p, n) == (provider, name)), [])
        effort = "medium" if "medium" in offered else None
    return provider, name, effort


def dsh_turn(session, text, images, model, progress, started=None, env=None):
    """Same contract as codex_turn: images [(bytes, mime)], progress(text, tools, new session id or None),
    started(process); returns (text, tools, error, usage). Unsandboxed like TCodex (DSH_PERMISSION_MODE), on the
    desktop app's settings with the stored sign-ins turned back on; model "provider/model" or "default"."""
    out, tools, error, usage = "", {}, None, {}
    with tempfile.TemporaryDirectory() as tmp:
        paths = []
        for i, (data, mime) in enumerate(images):
            paths.append(os.path.join(tmp, f"{i}.{mime.split('/')[-1]}"))
            with open(paths[-1], "wb") as f:
                f.write(data)
        # ponytail: headless takes no image flag, so the agent is pointed at the files; it needs an image-reading tool
        task = text + "".join(f"\n（附图：{p}）" for p in paths)
        overlay = [{"id": k, "disabled": False} for k in ("credentials", "authorization", "deepseek-account")]
        provider, name, effort = _pick(model)
        if name:
            overlay.append({"id": "agent-default-model", "name": "@deepseek-ai/dsh-agent-default-model",
                            "config": {"provider": provider, "model": name, **({"reasoningEffort": effort} if effort else {})}})
        patch = os.path.join(tmp, "p2b.patch.json")
        with open(patch, "w") as f:
            json.dump(overlay, f)  # JSON is YAML, so the loader takes it as a patch list
        desktop = _desktop_patch()
        args = [dsh_bin() or "dsh", "--profile", "headless", *(["--patch", desktop] if desktop else []), "--patch", patch,
                "--json"] + (["--session-id", session] if session else []) + ["-"]
        with open(os.path.join(tmp, "stderr"), "w+") as err, \
                subprocess.Popen(args, cwd=REPO, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, text=True,
                                 env={**os.environ, "PATH": PATH, "DSH_PERMISSION_MODE": "danger-full-access", **(env or {})},
                                 start_new_session=True) as p:
            if started:
                started(p)
            p.stdin.write(task)  # stdin, not argv: a task starting with "-" would read as a flag
            p.stdin.close()
            for line in p.stdout:
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                kind, new = ev.get("type"), None
                if kind == "session":
                    new = ev.get("sessionId")
                elif kind in ("text", "final"):
                    out = ev.get("text") or out
                elif kind == "status" and ev.get("phase") == "turn_end":
                    reason = ev.get("reason") or {}
                    if reason.get("kind") != "completed":
                        error = f"dsh 中止：{(reason.get('error') or {}).get('message') or reason.get('kind')}"[:500]
                    continue
                elif kind == "tool_call":
                    tools[ev.get("callId")] = {"name": ev.get("tool"), "status": "running", "args": _short(ev.get("input"))}
                elif kind == "tool_result" and ev.get("callId") in tools:
                    tools[ev["callId"]]["status"] = "done"
                elif kind == "status" and ev.get("phase") == "step_end":
                    u = ev.get("usage") or {}
                    # dsh's inputTokens leaves out the cache-read part; ours includes it, as TCodex's does
                    for mine, n in (("input_tokens", (u.get("inputTokens"), u.get("cacheReadTokens") or 0)), ("cached_tokens", (u.get("cacheReadTokens"),)),
                                    ("output_tokens", (u.get("outputTokens"),))):
                        if all(isinstance(x, int) for x in n):
                            usage[mine] = usage.get(mine, 0) + sum(n)
                    continue
                elif kind == "error":
                    error = ev.get("message") or "dsh 出错"
                else:
                    continue
                progress(out, list(tools.values()), new)
            p.wait()
            err.seek(0)
            if p.returncode and not error:
                error = err.read()[-300:].strip() or f"dsh 退出码 {p.returncode}"
    return out, list(tools.values()), error, usage
