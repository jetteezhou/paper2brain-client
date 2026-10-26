"""The client on its own: no server, no network."""
import base64
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

os.environ["P2B_CLIENT_HOME"] = tempfile.mkdtemp(prefix="p2b-client-")

import contextlib  # noqa: E402
import io  # noqa: E402
import json  # noqa: E402

from p2b_client import api, codex, cursor, remote  # noqa: E402


def sse(*pairs):
    """A Cursor run stream as the lines urlopen yields."""
    out = []
    for event, data in pairs:
        out += [f"event: {event}\n".encode(), f"data: {data}\n".encode(), b"\n"]
    return out


class Client(unittest.TestCase):
    def test_files_go_along_and_flags_are_normalized(self):
        f = Path(tempfile.mkdtemp()) / "card.json"
        f.write_text("{}")
        argv, files = remote.files_of(["card", "put", "arxiv:1", f"--file={f}"])
        self.assertEqual(argv, ["card", "put", "arxiv:1", "--file", str(f)])
        self.assertEqual(base64.b64decode(files[str(f)]), b"{}")

    def test_server_paths_point_at_local_copies(self):
        out = remote.localize({"figures": [{"image": "/srv/a.png"}, {"image": "/srv/b.png"}]}, {"/srv/a.png": "/here/a.png"})
        self.assertEqual([x["image"] for x in out["figures"]], ["/here/a.png", "/srv/b.png"])

    def test_guide_replaces_the_specs_and_ignores_odd_names(self):
        folder = Path(tempfile.mkdtemp())
        (folder / "old.md").write_text("gone")
        remote.write_guide({"README.md": "r", "../evil.md": "x"}, folder)
        self.assertEqual(sorted(p.name for p in folder.iterdir()), ["README.md"])

    def test_codex_turn_reads_tcodex_events(self):
        bin_dir = Path(tempfile.mkdtemp())
        (bin_dir / "tcodex").write_text(
            '#!/bin/sh\necho "$P2B_AGENT_ID $*" > "$(dirname "$0")/seen"\n'
            'echo \'{"type":"thread.started","thread_id":"s-1"}\'\necho "not json"\n'
            'echo \'{"type":"item.completed","item":{"id":"i1","type":"command_execution","command":"./p2b papers"}}\'\n'
            'echo \'{"type":"error","message":"Reconnecting... 2/5"}\'\n'
            'echo \'{"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"答案"}}\'\n'
            'echo \'{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":7}}\'\n'
            'echo \'{"type":"turn.completed","usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":3}}\'\n')
        (bin_dir / "tcodex").chmod(0o755)
        seen = []
        with mock.patch.object(codex, "PATH", f"{bin_dir}:/usr/bin:/bin"):
            text, tools, error, usage = codex.codex_turn("s-0", "接着说", [], {"id": "m"}, lambda *a: seen.append(a), env={"P2B_AGENT_ID": "codex-1"})
        self.assertEqual((text, error), ("答案", None))
        self.assertEqual(usage, {"input_tokens": 150, "cached_tokens": 80, "output_tokens": 10})
        self.assertEqual(tools, [{"name": "command_execution", "status": "done", "args": "./p2b papers"}])
        self.assertEqual(seen[0][2], "s-1")
        self.assertTrue((bin_dir / "seen").read_text().strip().endswith("-m m resume s-0 接着说"))
        self.assertTrue((bin_dir / "seen").read_text().startswith("codex-1 "))


    def test_cursor_stream_to_its_result(self):
        stream = sse(("status", '{"status":"RUNNING"}'), ("assistant", '{"text":"答"}'),
                     ("interaction_update", '{"type":"token-delta","tokens":3}'),
                     ("tool_call", '{"callId":"c1","name":"shell","status":"done","args":{"command":"./p2b papers"}}'),
                     ("assistant", '{"text":"案"}'), ("interaction_update", '{"type":"token-delta","tokens":2}'),
                     ("result", '{"status":"FINISHED","text":"答案","durationMs":7}'))
        seen = []
        with mock.patch.object(cursor, "_request", return_value=contextlib.nullcontext(stream)):
            out = cursor.follow("k", "bc-1", "run-1", lambda text, tools: seen.append(text) or True)
        self.assertEqual(out, ("答案", [{"name": "shell", "status": "done", "args": "./p2b papers"}], "FINISHED", 7, None, {"output_tokens": 5}))
        self.assertEqual(seen[-1], "答案"[:2])

    def test_a_run_stopped_on_the_server_is_cancelled_at_cursor(self):
        stream = sse(("assistant", '{"text":"一"}'), ("assistant", '{"text":"二"}'), ("result", '{"status":"FINISHED","text":"x"}'))
        with mock.patch.object(cursor, "_request", return_value=contextlib.nullcontext(stream)), \
                mock.patch.object(cursor, "cancel") as cancel:
            out = cursor.follow("k", "bc-1", "run-1", lambda text, tools: False)
        self.assertEqual(out[2], "CANCELLED")
        cancel.assert_called_once_with("k", "bc-1", "run-1")

    def test_a_new_agent_is_created_on_this_macs_worker(self):
        with mock.patch.object(cursor, "_json", return_value={"run": {"id": "run-1"}}) as call:
            cursor.start("k", {"new": True, "agent_id": "bc-1", "prompt": "你好", "repo": "https://github.com/x/client",
                               "model": {"id": "claude-x"}, "name": "讨论"}, "p2b-mac", [{"data": "aGk=", "mime": "image/png"}])
        method, path, body = call.call_args[0][1:4]
        self.assertEqual((method, path, body["env"], body["agentId"], body["model"]), ("POST", "/agents", {"type": "machine", "name": "p2b-mac"}, "bc-1", {"id": "claude-x"}))
        self.assertEqual(body["prompt"]["images"], [{"data": "aGk=", "mimeType": "image/png"}])


    def test_quick_search_goes_through_the_configured_proxy(self):
        seen = {}

        class Opener:
            def open(self, req, timeout):
                seen.update(url=req.full_url, body=json.loads(req.data), timeout=timeout)
                return contextlib.nullcontext(io.BytesIO(json.dumps({"choices": [{"message": {"content": "好标题"}}]}).encode()))

        def build(*handlers):
            seen["proxies"] = [h.proxies for h in handlers]
            return Opener()
        g = {"base_url": "https://generativelanguage.googleapis.com/v1beta/openai", "model": "gemini-x", "api_key": "k"}
        with mock.patch.object(api.urllib.request, "build_opener", build):
            self.assertEqual(api.chat(g, "起个标题", 30, "http://127.0.0.1:7890"), {"text": "好标题"})
        self.assertEqual(seen["proxies"], [{"http": "http://127.0.0.1:7890", "https": "http://127.0.0.1:7890"}])
        self.assertEqual((seen["url"], seen["body"]["model"], "thinking" in seen["body"]),
                         ("https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", "gemini-x", False))
        self.assertFalse(api.ready({"base_url": "https://x", "model": "m"}))  # no key: not offered to the server


if __name__ == "__main__":
    unittest.main()
