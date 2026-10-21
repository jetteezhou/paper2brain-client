"""The client on its own: no server, no network."""
import base64
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

os.environ["P2B_CLIENT_HOME"] = tempfile.mkdtemp(prefix="p2b-client-")

from p2b_client import codex, remote  # noqa: E402


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
            'echo \'{"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"答案"}}\'\n')
        (bin_dir / "tcodex").chmod(0o755)
        seen = []
        with mock.patch.object(codex, "PATH", f"{bin_dir}:/usr/bin:/bin"):
            text, tools, error = codex.codex_turn("s-0", "接着说", [], {"id": "m"}, lambda *a: seen.append(a), env={"P2B_AGENT_ID": "codex-1"})
        self.assertEqual((text, error), ("答案", None))
        self.assertEqual(tools, [{"name": "command_execution", "status": "done", "args": "./p2b papers"}])
        self.assertEqual(seen[0][2], "s-1")
        self.assertTrue((bin_dir / "seen").read_text().strip().endswith("-m m resume s-0 接着说"))
        self.assertTrue((bin_dir / "seen").read_text().startswith("codex-1 "))


if __name__ == "__main__":
    unittest.main()
