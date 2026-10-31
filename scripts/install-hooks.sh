#!/bin/bash
# Adds companion-hook.sh to ~/.claude/settings.json next to any existing hooks. Idempotent.
# Pass --remove to take it back out.
set -euo pipefail

settings="$HOME/.claude/settings.json"
hook="$(cd "$(dirname "$0")/.." && pwd)/hooks/companion-hook.sh"

cp "$settings" "$settings.bak-companion-$(date +%Y%m%d%H%M%S)"

if [[ "${1:-}" == "--remove" ]]; then
  jq --arg cmd "$hook" '
    .hooks |= with_entries(.value |= map(select(([.hooks[]?.command] | index($cmd)) | not)) | select(.value | length > 0))
  ' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
  echo "removed companion hook"
  exit 0
fi

jq --arg cmd "$hook" '
  def entry($matcher; $timeout):
    ({hooks: [{type: "command", command: $cmd, timeout: $timeout}]}
     + (if $matcher then {matcher: $matcher} else {} end));
  def add($event; $matcher; $timeout):
    .hooks[$event] = ((.hooks[$event] // [])
      | map(select(([.hooks[]?.command] | index($cmd)) | not))
      + [entry($matcher; $timeout)]);
  .hooks //= {}
  | add("UserPromptSubmit"; null; 5)
  | add("Stop"; null; 5)
  | add("Notification"; null; 5)
  | add("PreToolUse"; "AskUserQuestion"; 5)
  | add("PermissionRequest"; null; 600)
' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
echo "installed companion hook: $hook"
