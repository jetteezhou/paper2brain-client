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
