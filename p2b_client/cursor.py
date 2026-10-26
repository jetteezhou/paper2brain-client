"""Cursor Cloud Agents API, called from this Mac with your key: Cursor serves models by the caller's region, and
the key never leaves this Mac. The agent runs on this Mac's worker (ops/worker.sh). The same calls the server repo's
single-user backend makes (paper2brain/cursor_api.py: _send, _latest_run, _follow)."""
import json
import time
import urllib.error
import urllib.request

from .codex import _short

API = "https://api.cursor.com/v1"
TERMINAL = {"FINISHED", "ERROR", "CANCELLED", "EXPIRED"}


class CursorError(RuntimeError):
    pass


def _request(key, method, path, body=None, accept="application/json", timeout=None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json", "Accept": accept})
    try:
        return urllib.request.urlopen(req, timeout=timeout or (60 if accept == "application/json" else 900))
    except urllib.error.HTTPError as e:
        raise CursorError(f"Cursor API {e.code}：{e.read().decode(errors='replace')[:300]}") from None


def _json(key, method, path, body=None, timeout=None):
    with _request(key, method, path, body, timeout=timeout) as r:
        return json.loads(r.read() or b"{}")


def models(key):
    return _json(key, "GET", "/models")["items"]


def latest_run(key, agent_id):
    """After a create or follow-up whose response never arrived: the run it started, if it went through.
    ponytail: unlike the server, this Mac cannot tell that run from an earlier one it already reported."""
    info = _json(key, "GET", f"/agents/{agent_id}")
    if not info.get("latestRunId"):
        raise CursorError("Cursor 没有收到这次请求，请重试")
    return {"id": info["latestRunId"], "status": "RUNNING"}


def start(key, job, machine, images):
    """Create the agent on this Mac's worker (job["new"]) or continue it; returns Cursor's run."""
    prompt = {"text": job["prompt"], **({"images": [{"data": i["data"], "mimeType": i["mime"]} for i in images[:5]]} if images else {})}
    try:
        if not job.get("new"):
            return _json(key, "POST", f"/agents/{job['agent_id']}/runs", {"prompt": prompt}, timeout=180)["run"]
        body = {"agentId": job["agent_id"], "prompt": prompt, "env": {"type": "machine", "name": machine}, "repos": [{"url": job["repo"]}]}
        if job.get("name"):
            body["name"] = job["name"][:100]
        if job.get("model"):
            body["model"] = job["model"]
        return _json(key, "POST", "/agents", body, timeout=180)["run"]
    except (TimeoutError, urllib.error.URLError, ConnectionError):
        return latest_run(key, job["agent_id"])  # creating an agent can outlast the response timeout and still succeed
    except CursorError as e:
        if job.get("new") and "agent_id_conflict" in str(e):  # an earlier attempt went through
            return latest_run(key, job["agent_id"])
        raise


def cancel(key, agent_id, run_id):
    _json(key, "POST", f"/agents/{agent_id}/runs/{run_id}/cancel")


def events(lines):
    """(event, payload) from a server-sent event stream of byte lines."""
    event, data = None, []
    for raw in lines:
        line = raw.decode("utf-8", errors="replace").rstrip("\r\n")
        if line.startswith("event:"):
            event = line[6:].strip()
        elif line.startswith("data:"):
            data.append(line[5:].strip())
        elif not line and event:
            yield event, json.loads("\n".join(data) or "{}")
            event, data = None, []


def follow(key, agent_id, run_id, report):
    """Stream the run to its end. report(text, tools) after changes; when it returns False (stopped on the server)
    the run is cancelled. Returns (text, tools, status, duration_ms, error, usage); usage has the output tokens counted
    off the stream, and stays empty when the stream broke (Cursor reports no input tokens)."""
    text, tools, out_tokens = "", {}, 0

    def changed():
        if not report(text, list(tools.values())):
            try:
                cancel(key, agent_id, run_id)
            except Exception:
                pass
            return False
        return True

    try:
        with _request(key, "GET", f"/agents/{agent_id}/runs/{run_id}/stream", accept="text/event-stream") as r:
            for event, payload in events(r):
                if event == "assistant":
                    text += payload.get("text", "")
                elif event == "tool_call":
                    tools[payload["callId"]] = {"name": payload.get("name"), "status": payload.get("status"), "args": _short(payload.get("args"))}
                elif event == "result":
                    return (payload.get("text") or text, list(tools.values()), payload.get("status", "FINISHED"), payload.get("durationMs"), None,
                            {"output_tokens": out_tokens})
                elif event == "error":
                    raise CursorError(payload.get("message", "stream error"))
                elif event == "interaction_update" and payload.get("type") == "token-delta":
                    out_tokens += payload.get("tokens") or 0
                    continue
                elif event != "status":
                    continue
                if not changed():
                    return text, list(tools.values()), "CANCELLED", None, None, {}
    except Exception:
        pass  # stream dropped or expired: poll the run instead
    while True:
        try:
            run = _json(key, "GET", f"/agents/{agent_id}/runs/{run_id}")
        except Exception:
            time.sleep(10)
            continue
        if run.get("status") in TERMINAL:
            return run.get("result") or text, list(tools.values()), run["status"], run.get("durationMs"), None, {}
        if not changed():
            return text, list(tools.values()), "CANCELLED", None, None, {}
        time.sleep(3)
