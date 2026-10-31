#!/bin/bash
# Builds companiond (release), installs it under Application Support, and runs it as a LaunchAgent.
# Re-run after pulling changes. --remove unloads and deletes the agent.
set -euo pipefail

label=com.mmichon.claude-companion
root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$HOME/Library/Application Support/ClaudeCompanion/bin"
plist="$HOME/Library/LaunchAgents/$label.plist"
logfile="$HOME/Library/Logs/ClaudeCompanion.log"

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true

if [[ "${1:-}" == "--remove" ]]; then
  rm -f "$plist"
  echo "removed $label"
  exit 0
fi

(cd "$root" && swift build -c release --product companiond 2>&1 | tail -1)
mkdir -p "$dest"
cp "$root/.build/release/companiond" "$dest/companiond"
# Ad-hoc sign so TCC (Accessibility, for the Esc interrupt) keeps its grant across reinstalls of the same identifier.
codesign --force --sign - --identifier "$label" "$dest/companiond"

cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$dest/companiond</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$logfile</string>
  <key>StandardOutPath</key><string>$logfile</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$plist"
sleep 1
launchctl print "gui/$(id -u)/$label" | grep -E "state =|pid =" | head -2
echo "log: $logfile"
