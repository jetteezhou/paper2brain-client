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

from p2b_client import api, bot, codex, cursor, remote, runner  # noqa: E402


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

    def test_p2bot_runs_in_its_own_folder_without_the_macs_token(self):
        bin_dir, root = Path(tempfile.mkdtemp()), Path(tempfile.mkdtemp())
        # as Codex runs its agent's commands: with nothing named like a token or key left in the environment
        (bin_dir / "tcodex").write_text(
            '#!/bin/sh\necho "pwd=$(pwd) tok=${P2B_TOKEN:-none} put=$(command -v p2bot)" > "$(dirname "$0")/seen"\n'
            'echo hi > out.txt && env -i PATH="$PATH" p2bot put out.txt >> "$(dirname "$0")/seen" 2>&1\n'
            'echo \'{"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"做好了"}}\'\n')
        (bin_dir / "tcodex").chmod(0o755)
        reports, puts = [], []

        def urlopen(req, timeout):
            puts.append((req.full_url, req.headers["Authorization"]))
            return io.BytesIO(json.dumps({"name": "out.txt", "size": 3}).encode())

        job = {"task_id": "abc123", "engine": "tcodex", "prompt": "做个 PPT", "token": "lib.bt-1.s", "inputs": []}
        with mock.patch.object(codex, "PATH", f"{bin_dir}:/usr/bin:/bin"), mock.patch.object(bot, "PATH", f"{bin_dir}:/usr/bin:/bin"), \
                mock.patch.object(bot, "ROOT", root), mock.patch.dict(os.environ, {"P2B_TOKEN": "secret"}):
            bot.run("http://srv", job, lambda force=False, **f: reports.append(f) or True)
        seen = (bin_dir / "seen").read_text()
        self.assertRegex(seen, rf"pwd=(/private)?{root / 'abc123'} ")
        self.assertIn("tok=none", seen)
        self.assertIn(f"put={root / 'abc123' / 'bin' / 'p2bot'}", seen)
        self.assertNotIn("只能在 p2bot", seen)
        self.assertEqual((reports[-1]["text"], reports[-1]["done"]), ("做好了", True))
        # what bin/p2bot hands to `p2bot put`, without any environment of its own
        env = dict(line.split("=", 1) for line in (root / "abc123" / "bin" / "p2bot").read_text().split("\n")[1].split(" ")[:2])
        with mock.patch.dict(os.environ, {k: v.strip("'") for k, v in env.items()}), mock.patch.object(bot.urllib.request, "urlopen", urlopen), \
                contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as done:
            bot.put([str(root / "abc123" / "out.txt")])
        self.assertEqual(done.exception.code, 0)
        self.assertEqual(puts, [("http://srv/api/bot/run/put?name=out.txt", "Bearer lib.bt-1.s")])
        with self.assertRaises(ValueError):
            bot.folder("../x")


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

    def test_web_settings_replace_the_quick_api_on_this_mac(self):
        path = Path(tempfile.mkdtemp()) / "config.json"
        path.write_text(json.dumps({"server": "https://x", "search_api": {"base_url": "https://old", "model": "old", "api_key": "old-key"}}))
        read = lambda: json.loads(path.read_text())  # noqa: E731
        with mock.patch.object(runner, "CONFIG", path), mock.patch.object(runner, "config", side_effect=read), \
                mock.patch.object(runner, "_post") as post:
            runner.run_api("s", "t", {"call_id": "1", "op": "configure", "settings": {"base_url": "https://new", "model": "m", "api_key": "new-key"}}, None, None)
            self.assertEqual(read()["search_api"]["api_key"], "new-key")
            runner.run_api("s", "t", {"call_id": "2", "op": "configure", "settings": {"base_url": "https://new", "model": "other", "api_key": ""}}, None, None)
            self.assertEqual(read()["search_api"], {"base_url": "https://new", "model": "other", "api_key": "new-key"})
            self.assertEqual(post.call_args[0][3]["result"]["search_api"], {"base_url": "https://new", "model": "other", "web_model": "", "has_key": True})
            runner.run_api("s", "t", {"call_id": "3", "op": "configure", "settings": {}}, None, None)
            self.assertNotIn("search_api", read())
            self.assertEqual(read()["server"], "https://x")


class DeepSeekHarness(unittest.TestCase):
    PATCH = ("- id: llm-pi-ai\n  config:\n    providers:\n      venus-responses:\n        models:\n          - id: gpt-6.1-sol\n"
             "            reasoningEfforts:\n              off: null\n              medium: medium\n          - id: plain\n"
             "- id: agent-default-model\n  name: \"@deepseek-ai/dsh-agent-default-model\"\n  config:\n"
             "    provider: venus-responses\n    model: gpt-6.1-sol\n")

    def test_models_and_the_effort_sent_by_default(self):
        from p2b_client import dsh
        with tempfile.TemporaryDirectory() as home:
            prof = Path(home) / "profiles" / "desktop"
            prof.mkdir(parents=True)
            (prof / "cordis.patch.yml").write_text(self.PATCH)
            with mock.patch.dict(os.environ, {"DSH_HOME": home}):
                self.assertEqual([m["id"] for m in dsh.models()], ["default", "venus-responses/gpt-6.1-sol", "venus-responses/plain"])
                # dsh's own default sends effort "none", which gpt-5+ refuse: medium when offered, else left out
                self.assertEqual(dsh._pick({"id": "default"}), ("venus-responses", "gpt-6.1-sol", "medium"))
                self.assertEqual(dsh._pick({"id": "venus-responses/plain"}), ("venus-responses", "plain", None))
                self.assertEqual(dsh._pick({"id": "venus-responses/gpt-6.1-sol", "params": [{"id": "effort", "value": "off"}]}),
                                 ("venus-responses", "gpt-6.1-sol", "off"))

    def test_venus_routes_get_sticky_routing_and_claude_prompt_cache(self):
        from p2b_client import dsh
        text = ("- id: llm-pi-ai\n  config:\n    providers:\n      venus:\n        api: openai-completions\n        baseURL: http://v2.open.venus.oa.com/llmproxy\n"
                "        models:\n          - id: claude-opus-5-5\n          - id: kimi\n"
                "      venus-responses:\n        api: openai-responses\n        baseURL: http://v2.open.venus.oa.com/llmproxy/v1\n"
                "      openai:\n        api: openai-responses\n        baseURL: https://api.openai.com/v1\n")
        got = dsh._venus_patch(text, "dsh-1")
        self.assertEqual(got, text
                         .replace("      venus:\n", '      venus:\n        headers:\n          Venus-Session-Id: "dsh-1"\n')
                         .replace("          - id: claude-opus-5-5\n", "          - id: claude-opus-5-5\n            compat:\n              cacheControlFormat: anthropic\n")
                         .replace("      venus-responses:\n", '      venus-responses:\n        headers:\n          Venus-Session-Id: "dsh-1"\n          Venus-Codex-Routing: "true"\n'))
        self.assertIs(dsh._venus_patch(got, "dsh-1"), got)  # already there: the file is used as is
        self.assertIs(dsh._venus_patch("- id: ui-chat\n", "dsh-1"), "- id: ui-chat\n")


if __name__ == "__main__":
    unittest.main()
