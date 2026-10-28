"""The quick search API (OpenAI-compatible chat, and Gemini grounded in Google Search), called from this Mac with the
key in this Mac's config, through this Mac's proxy: the server sends the prompt and waits for the answer. The same
calls as the server repo's single-user backend (paper2brain/cursor_api.py: _chat, _web)."""
import json
import re
import urllib.error
import urllib.parse
import urllib.request

WEB_MODEL = "gemini-3.5-flash-lite"


def ready(api):
    return bool(api and api.get("base_url") and api.get("api_key") and api.get("model"))


def public(api):
    """The settings the web form may show; never its key."""
    api = api or {}
    return {"base_url": api.get("base_url") or "", "model": api.get("model") or "", "web_model": api.get("web_model") or "",
            "has_key": bool(api.get("api_key"))}


def _open(req, timeout, proxy):
    """proxy (config "proxy", e.g. http://127.0.0.1:7890) or, without one, the system proxy macOS is set to."""
    handlers = [urllib.request.ProxyHandler({"http": proxy, "https": proxy})] if proxy else []
    return urllib.request.build_opener(*handlers).open(req, timeout=timeout)


def _google(api):
    return urllib.parse.urlparse(api["base_url"]).hostname == "generativelanguage.googleapis.com"


def chat(api, prompt, timeout=30, proxy=None):
    req = urllib.request.Request(api["base_url"].rstrip("/") + "/chat/completions", method="POST", headers={
        "Authorization": f"Bearer {api['api_key']}", "Content-Type": "application/json"}, data=json.dumps({
            "model": api["model"], "messages": [{"role": "user", "content": prompt}],
            **({} if _google(api) else {"thinking": {"type": "disabled"}})}).encode())  # Google rejects the unknown field
    try:
        with _open(req, timeout, proxy) as r:
            return {"text": json.loads(r.read())["choices"][0]["message"]["content"] or ""}
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"搜索接口 {e.code}：{e.read().decode(errors='replace')[:200]}") from None
    except (urllib.error.URLError, TimeoutError) as e:
        raise RuntimeError(f"连不上搜索接口：{e}") from None


def web(api, prompt, timeout=60, proxy=None):
    """One Gemini turn grounded in Google Search: {text, pages: [{title, url}] it used}."""
    # ponytail: Google itself, or zhizengzeng's <host>/google/v1beta; another provider needs its own path here.
    root = "https://generativelanguage.googleapis.com" if _google(api) else re.sub(r"/v1/?$", "", api["base_url"].rstrip("/")) + "/google"
    url = root + f"/v1beta/models/{api.get('web_model') or WEB_MODEL}:generateContent?" + urllib.parse.urlencode({"key": api["api_key"]})
    req = urllib.request.Request(url, method="POST", headers={"Content-Type": "application/json"}, data=json.dumps({
        "contents": [{"parts": [{"text": prompt}]}], "tools": [{"google_search": {}}]}).encode())
    try:
        with _open(req, timeout, proxy) as r:
            c = (json.loads(r.read()).get("candidates") or [{}])[0]
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"联网模型 {e.code}：{e.read().decode(errors='replace')[:200]}") from None
    except (urllib.error.URLError, TimeoutError) as e:
        raise RuntimeError(f"连不上联网模型：{e}") from None
    text = "".join(p.get("text", "") for p in (c.get("content") or {}).get("parts") or [])
    pages = [ch["web"] for ch in (c.get("groundingMetadata") or {}).get("groundingChunks") or [] if ch.get("web")]
    return {"text": text, "pages": [{"title": w.get("title") or "", "url": w.get("uri") or ""} for w in pages][:8]}


# ---------- the strong model (config "strong_api"), the same calls as the server repo's llm_call ----------

WIRES, EFFORTS = ("chat", "responses"), ("", "low", "medium", "high", "xhigh")


def strong(cfg):
    """The strong model's settings, an empty base_url / api_key borrowing the quick search API's; None without a model."""
    s, quick = cfg.get("strong_api") or {}, cfg.get("search_api") or {}
    got = {"base_url": s.get("base_url") or quick.get("base_url"), "api_key": s.get("api_key") or quick.get("api_key"),
           "model": s.get("model"), "wire": s.get("wire") if s.get("wire") in WIRES else "chat",
           "effort": s.get("effort") if s.get("effort") in EFFORTS else ""}
    return got if got["base_url"] and got["api_key"] and got["model"] else None


def strong_public(s):
    s = s or {}
    return {"base_url": s.get("base_url") or "", "model": s.get("model") or "", "wire": s.get("wire") or "chat",
            "effort": s.get("effort") or "", "has_key": bool(s.get("api_key"))}


def _args(raw):
    try:
        got = json.loads(raw) if isinstance(raw, str) else raw
    except ValueError:
        return {}
    return got if isinstance(got, dict) else {}


def _resp_item(m):
    if m.get("type") == "call":
        return {"type": "function_call", "call_id": m["id"], "name": m["name"], "arguments": json.dumps(m["args"], ensure_ascii=False)}
    if m.get("type") == "result":
        return {"type": "function_call_output", "call_id": m["id"], "output": m["output"]}
    return {"role": m["role"], "content": m["content"]}


def _chat_messages(messages):
    out = []
    for m in messages:
        if m.get("type") == "call":
            call = {"id": m["id"], "type": "function", "function": {"name": m["name"], "arguments": json.dumps(m["args"], ensure_ascii=False)}}
            if out and out[-1]["role"] == "assistant" and "tool_calls" in out[-1]:
                out[-1]["tool_calls"].append(call)
            elif out and out[-1]["role"] == "assistant" and not out[-1].get("content"):
                out[-1]["tool_calls"] = [call]
            else:
                out.append({"role": "assistant", "content": None, "tool_calls": [call]})
        elif m.get("type") == "result":
            out.append({"role": "tool", "tool_call_id": m["id"], "content": m["output"]})
        else:
            out.append({"role": m["role"], "content": m["content"]})
    return out


def llm(api, messages, tools=(), web=False, timeout=300, proxy=None):
    """One turn of the strong model: {text, calls: [{id, name, args}], items} (see the server's llm)."""
    # OpenAI's gpt-5+ refuse tools on the chat wire whatever the reasoning setting: with tools they go through responses
    responses = api.get("wire") == "responses" or bool((tools or web) and re.match(r"gpt-[5-9]", api["model"]))
    if responses:
        body = {"model": api["model"], "store": False, "input": [_resp_item(m) for m in messages],
                "tools": [{"type": "function", **t} for t in tools] + ([{"type": "web_search"}] if web else [])}
        if api.get("effort"):
            body["reasoning"] = {"effort": api["effort"]}
    else:
        body = {"model": api["model"], "messages": _chat_messages(messages),
                **({"tools": [{"type": "function", "function": t} for t in tools]} if tools else {})}
        if api.get("effort"):
            body["reasoning_effort"] = api["effort"]
    if not body.get("tools"):
        body.pop("tools", None)
    req = urllib.request.Request(api["base_url"].rstrip("/") + ("/responses" if responses else "/chat/completions"), method="POST", headers={
        "Authorization": f"Bearer {api['api_key']}", "Content-Type": "application/json"}, data=json.dumps(body).encode())
    try:
        with _open(req, timeout, proxy) as r:
            got = json.loads(r.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"强模型 {e.code}：{e.read().decode(errors='replace')[:300]}") from None
    except (urllib.error.URLError, TimeoutError) as e:
        raise RuntimeError(f"连不上强模型：{e}") from None
    if responses:
        out = got.get("output") or []
        text = "".join(c.get("text", "") for o in out if o.get("type") == "message" for c in o.get("content") or [])
        calls = [{"id": o["call_id"], "name": o["name"], "args": _args(o.get("arguments"))} for o in out if o.get("type") == "function_call"]
    else:
        msg = (got.get("choices") or [{}])[0].get("message") or {}
        text = msg.get("content") or ""
        calls = [{"id": c["id"], "name": c["function"]["name"], "args": _args(c["function"].get("arguments"))} for c in msg.get("tool_calls") or []]
    items = ([{"role": "assistant", "content": text}] if text or not calls else []) + [{"type": "call", **c} for c in calls]
    return {"text": text, "calls": calls, "items": items}
