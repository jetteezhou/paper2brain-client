#!/bin/sh
# Connect this Mac to a paper2brain server, safe to re-run. Keeps the Cursor worker and the runner running here: the
# runner calls Cursor with your key, runs tcodex when installed and makes the quick search API calls, through this
# Mac's proxy; the key and the API settings stay on this Mac (~/.paper2brain-client/config.json).
# Usage: ./setup.sh <服务器地址> <本机 agent 口令>   (the token comes from the web page's Agent settings)
#        ./setup.sh --search                       (set the quick search API and its proxy again)
set -e
cd "$(dirname "$0")"
RESET_SEARCH=
[ "$1" = "--search" ] && { RESET_SEARCH=1; shift; }
command -v python3 >/dev/null || { echo "缺 python3：xcode-select --install"; exit 1; }
HOMEDIR="${P2B_CLIENT_HOME:-$HOME/.paper2brain-client}"
mkdir -p "$HOMEDIR"
chmod 700 "$HOMEDIR"
# earlier settings: this client's own config, else a single-user paper2brain on this Mac
OLD="$HOME/paper2brain-data/config.json"
get() { python3 -c "import json,sys
for p in sys.argv[2:]:
    try: v = json.load(open(p)).get(sys.argv[1])
    except (OSError, ValueError): continue
    if v: print(json.dumps(v) if isinstance(v, dict) else v); break" "$1" "$HOMEDIR/config.json" "$OLD"; }
mine() { python3 -c "import json,sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2]) or '')
except (OSError, ValueError): print('')" "$HOMEDIR/config.json" "$1"; }
ask() { printf "%s" "$1" >&2; if [ "$2" = secret ]; then stty -echo; read -r v; stty echo; echo >&2; else read -r v; fi; printf "%s" "$v"; }

SERVER="${1%/}"
TOKEN="$2"
[ -n "$SERVER" ] || SERVER="$(mine server)"
[ -n "$TOKEN" ] || TOKEN="$(mine server_token)"
[ -n "$SERVER" ] && [ -n "$TOKEN" ] || { echo "用法：./setup.sh <服务器地址> <本机 agent 口令>（口令在网页左下角的 Agent 设置里生成）"; exit 1; }
KEY="$(get cursor_api_key)"
[ -n "$KEY" ] || KEY="$(ask "Cursor API key（在 https://cursor.com/dashboard/integrations 创建）：" secret)"
MACHINE="$(mine machine)"
[ -n "$MACHINE" ] || MACHINE="$(printf 'p2b-%s-%s' "$(whoami)" "$(hostname -s)" | tr -c 'A-Za-z0-9.\n-' '-')"
SEARCH="$( [ -n "$RESET_SEARCH" ] || get search_api)"
PROXY="$( [ -n "$RESET_SEARCH" ] || mine proxy)"
if [ -z "$SEARCH" ]; then
  URL="$(ask "快速搜索接口地址（OpenAI 兼容，例如 https://generativelanguage.googleapis.com/v1beta/openai；回车跳过）：")"
  if [ -n "$URL" ]; then
    SEARCH="$(P_URL="$URL" P_MODEL="$(ask "快速模型（例如 gemini-3.5-flash-lite）：")" P_WEB="$(ask "联网模型（回车用默认）：")" \
      P_KEY="$(ask "它的 API key：" secret)" python3 -c "import json,os
print(json.dumps({'base_url': os.environ['P_URL'].rstrip('/'), 'model': os.environ['P_MODEL'], 'api_key': os.environ['P_KEY'],
                  **({'web_model': os.environ['P_WEB']} if os.environ['P_WEB'] else {})}))")"
    PROXY="$(ask "调用它走的代理（例如 http://127.0.0.1:7890；回车用系统代理）：")"
  fi
fi

# secrets go through the environment, not the command line other users can see in ps
P2B_KEY="$KEY" P2B_TOKEN="$TOKEN" P2B_SEARCH="$SEARCH" P2B_PROXY="$PROXY" python3 - "$HOMEDIR/config.json" "$SERVER" "$MACHINE" <<'EOF'
import json, os, sys, urllib.error, urllib.request
path, server, machine = sys.argv[1:]
req = urllib.request.Request(f"{server}/api/agent/connect", method="POST", data=b"{}",
                             headers={"Content-Type": "application/json", "Authorization": f"Bearer {os.environ['P2B_TOKEN']}"})
try:
    urllib.request.urlopen(req, timeout=30).read()
except urllib.error.HTTPError as e:
    sys.exit(f"服务器拒绝了这个口令（{e.code}）：{e.read().decode(errors='replace')[:300]}")
except urllib.error.URLError as e:
    sys.exit(f"连不上 {server}：{e.reason}")
search = json.loads(os.environ["P2B_SEARCH"]) if os.environ["P2B_SEARCH"] else None
cfg = {"server": server, "server_token": os.environ["P2B_TOKEN"], "cursor_api_key": os.environ["P2B_KEY"], "machine": machine,
       **({"search_api": search} if search else {}), **({"proxy": os.environ["P2B_PROXY"]} if os.environ["P2B_PROXY"] else {})}
with open(path, "w") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
os.chmod(path, 0o600)
print(f"✓ 已连上 {server}（本机 worker：{machine}）" + (f"，快速搜索接口在本机调用{'，走代理 ' + cfg['proxy'] if cfg.get('proxy') else '，走系统代理'}" if search else ""))
EOF

./p2b guide >/dev/null && echo "✓ 已从服务器取来 librarian/ 工作规范"
PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
command -v agent >/dev/null || command -v cursor-agent >/dev/null || curl https://cursor.com/install -fsS | bash
launchctl bootout "gui/$(id -u)/com.paper2brain.tcodex" 2>/dev/null && rm -f "$HOME/Library/LaunchAgents/com.paper2brain.tcodex.plist" || true  # replaced by the runner
# sign in now, in this terminal; otherwise the first TCodex run in the background is what asks for it
if command -v tcodex >/dev/null; then
  tcodex login && echo "✓ 也找到了 tcodex 并已登录：网页的模型列表里会出现 TCodex 的模型" \
    || echo "（tcodex 登录没完成：之后运行 tcodex login 即可）"
else
  echo "（没找到 tcodex：要用 TCodex 的模型，装好并 tcodex login 后重启 runner：launchctl kickstart -k gui/$(id -u)/com.paper2brain.runner）"
fi
sh ops/install.sh worker runner
echo "✓ 好了：网页上的 agent 和快速搜索都在这台 Mac 上运行（Mac 关机时它们不可用，其他功能照常）。"
