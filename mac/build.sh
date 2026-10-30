#!/bin/sh
# Build p2b 随手记 (floating pet, ⌃⌥Space, to-dos in Reminders) into ~/Applications/p2b-jot.app and start it at login
# (LaunchAgent com.paper2brain.jot). It uses this Mac's server and agent token from ./setup.sh. Re-run after git pull.
# Needs the Xcode command line tools (swift); macOS 14 or later.
set -e
cd "$(dirname "$0")"
command -v swift >/dev/null || { echo "缺 swift：xcode-select --install"; exit 1; }
[ -f "$HOME/.paper2brain-client/config.json" ] || [ -n "$P2B_CLIENT_HOME" ] || { echo "先运行 ../setup.sh 连上服务器"; exit 1; }
swift build -c release --product P2BJot
APP="$HOME/Applications/p2b-jot.app"
launchctl bootout "gui/$(id -u)/com.paper2brain.jot" 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/P2BJot" "$APP/Contents/MacOS/P2BJot"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.paper2brain.jot</string>
  <key>CFBundleName</key><string>p2b 随手记</string>
  <key>CFBundleDisplayName</key><string>p2b 随手记</string>
  <key>CFBundleExecutable</key><string>P2BJot</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSRemindersFullAccessUsageDescription</key><string>把随手记里的待办同步到"提醒事项"的「p2b 随手记」列表，并读回你在那里勾选的完成。</string>
  <key>NSRemindersUsageDescription</key><string>把随手记里的待办同步到"提醒事项"。</string>
</dict>
</plist>
EOF
xattr -cr "$APP"
codesign --force --sign - "$APP"
cd .. && sh ops/install.sh jot
echo "✓ p2b 随手记 已装好：屏幕右下角的小宠物、菜单栏的叶子；任意位置按 ⌃⌥空格 记一句。要同步到提醒事项，在叶子菜单里打开。"
