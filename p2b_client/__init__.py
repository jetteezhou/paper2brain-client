"""paper2brain-client: what runs on a member's Mac for the shared paper2brain server. Standard library only."""
import json
import os
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
HOME = Path(os.environ.get("P2B_CLIENT_HOME") or Path.home() / ".paper2brain-client")
CONFIG = HOME / "config.json"


def config():
    return json.loads(CONFIG.read_text()) if CONFIG.exists() else {}


def server_and_token():
    """The environment (set by ops/worker.sh and ops/tcodex.sh) first, else this Mac's config from setup.sh."""
    cfg = config()
    return (os.environ.get("P2B_SERVER") or cfg.get("server") or "").rstrip("/"), os.environ.get("P2B_TOKEN") or cfg.get("server_token") or ""
