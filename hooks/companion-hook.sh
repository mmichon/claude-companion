#!/bin/bash
# Forwards a Claude Code hook event to claude-companiond on 127.0.0.1.
# PermissionRequest may be held while the phone decides; every other event returns at once.
# Fails open: if claude-companiond isn't running, the hook prints nothing and exits 0.

input=$(cat)
max=3
case "$input" in
  *'"hook_event_name":"PermissionRequest"'*|*'"hook_event_name": "PermissionRequest"'*) max=590 ;;
esac

curl -s --connect-timeout 1 --max-time "$max" \
  -H 'Content-Type: application/json' \
  --data-binary "$input" \
  http://127.0.0.1:47821/hook 2>/dev/null || true
exit 0
