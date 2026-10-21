#!/bin/sh
# TCodex for the server, kept running (launchd; setup.sh installs it when tcodex is on this Mac): takes this user's
# TCodex runs from the server and runs them here (p2b_client/tcodex_runner.py).
cd "$(dirname "$0")/.." || exit 1
CONFIG="${P2B_CLIENT_HOME:-$HOME/.paper2brain-client}/config.json"
read_cfg() { python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]) or '')" "$CONFIG" "$1" 2>/dev/null; }
while [ -z "$(read_cfg server_token)" ]; do
  echo "$(date '+%F %T') 等待 $CONFIG（先运行 ./setup.sh）…"
  sleep 30
done
PYTHONPATH="$PWD" exec python3 -m p2b_client.tcodex_runner
