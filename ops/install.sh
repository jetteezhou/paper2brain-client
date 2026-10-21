#!/bin/sh
# Install (or reinstall) the Cursor worker and, when asked, TCodex as login-time LaunchAgents that restart when they exit.
# Usage: ops/install.sh worker [tcodex]
set -e
REPO="$(cd "$(dirname "$0")/.." && pwd)"
case "$REPO" in *"/Mobile Documents/"*)
  echo "仓库在 iCloud 云盘里：macOS 不允许 launchd 后台任务读取 iCloud 文件。把它移到 iCloud 之外（例如 ~/paper2brain-client）再运行。"
  exit 1 ;;
esac
AGENTS="$HOME/Library/LaunchAgents"
mkdir -p "$AGENTS"
for name in ${*:-worker}; do
  label="com.paper2brain.$name"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  # bootout returns before the job is gone; bootstrapping too early fails with "5: Input/output error"
  for _ in 1 2 3 4 5 6 7 8 9 10; do launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 || break; sleep 1; done
  sed -e "s#REPO#$REPO#g" -e "s#HOMEDIR#$HOME#g" "$REPO/ops/$label.plist" > "$AGENTS/$label.plist"
  launchctl bootstrap "gui/$(id -u)" "$AGENTS/$label.plist"
done
echo "已安装：${*:-worker}（日志 /tmp/paper2brain-worker.log、/tmp/paper2brain-tcodex.log）"
