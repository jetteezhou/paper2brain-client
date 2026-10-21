#!/bin/sh
# The server's agent work on this Mac, kept running (launchd; installed by setup.sh): takes this user's runs from the
# server and starts them at Cursor with the key here, or runs tcodex here (p2b_client/runner.py).
cd "$(dirname "$0")/.." || exit 1
CONFIG="${P2B_CLIENT_HOME:-$HOME/.paper2brain-client}/config.json"
read_cfg() { python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]) or '')" "$CONFIG" "$1" 2>/dev/null; }
while [ -z "$(read_cfg server_token)" ]; do
  echo "$(date '+%F %T') 等待 $CONFIG（先运行 ./setup.sh）…"
  sleep 30
done
PYTHONPATH="$PWD" exec python3 -m p2b_client.runner
