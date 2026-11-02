#!/bin/bash
# Builds claude-companiond (release), installs it under Application Support, and runs it as a LaunchAgent.
# Re-run after pulling changes. --remove unloads and deletes the agent.
set -euo pipefail

label=com.mmichon.claude-companion
root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$HOME/Library/Application Support/ClaudeCompanion/bin"
plist="$HOME/Library/LaunchAgents/$label.plist"
keys_label=$label.keys
keys_plist="$HOME/Library/LaunchAgents/$keys_label.plist"
logfile="$HOME/Library/Logs/ClaudeCompanion.log"

if [[ "${1:-}" == "--remove" ]]; then
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootout "gui/$(id -u)/$keys_label" 2>/dev/null || true
  rm -f "$plist" "$keys_plist"
  echo "removed $label"
  exit 0
fi

(cd "$root" && swift build -c release --product claude-companiond 2>&1 | tail -1)
(cd "$root" && swift build -c release --product claude-companion-keys 2>&1 | tail -1)
# Stop the daemon only once both built, so a failed build leaves it running.
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
mkdir -p "$dest"
cp "$root/.build/release/claude-companiond" "$dest/claude-companiond"
rm -f "$dest/companiond"  # pre-rename binary
codesign --force --sign - --identifier "$label" "$dest/claude-companiond"

# The keystroke helper holds the Accessibility grant (Esc, phone replies). TCC pins that grant to the binary's
# cdhash (even with an Apple Development certificate), so only replace the helper when its build changed:
# daemon updates then keep the grant.
keys_sum=$(shasum -a 256 "$root/.build/release/claude-companion-keys" | cut -d' ' -f1)
if [[ ! -x "$dest/claude-companion-keys" || "$(cat "$dest/claude-companion-keys.sha256" 2>/dev/null)" != "$keys_sum" ]]; then
  launchctl bootout "gui/$(id -u)/$keys_label" 2>/dev/null || true
  cp "$root/.build/release/claude-companion-keys" "$dest/claude-companion-keys"
  codesign --force --sign - --identifier "$keys_label" "$dest/claude-companion-keys"
  echo "$keys_sum" > "$dest/claude-companion-keys.sha256"
  echo "claude-companion-keys changed: allow it under Privacy & Security → Device Control and Data Access (Accessibility on older macOS)"
fi

cat > "$keys_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$keys_label</string>
  <key>ProgramArguments</key><array><string>$dest/claude-companion-keys</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$logfile</string>
  <key>StandardOutPath</key><string>$logfile</string>
</dict>
</plist>
EOF
launchctl print "gui/$(id -u)/$keys_label" >/dev/null 2>&1 || launchctl bootstrap "gui/$(id -u)" "$keys_plist"

cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$dest/claude-companiond</string></array>
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
