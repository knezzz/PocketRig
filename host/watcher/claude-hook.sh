#!/bin/sh
# PocketRig: tells the watcher what a Claude Code session is doing, so agents
# started by hand (outside a rig) can notify you too. Installed into
# ~/.claude/settings.json by install.sh. Never blocks Claude: 2 s max, always
# exits 0.
TOKEN=$(cat "$HOME/.config/pocketrig/answer-token" 2>/dev/null) || exit 0
PORT=${POCKETRIG_ANSWER_PORT:-7434}
[ "$PORT" = 0 ] && exit 0
SESSION=""
if [ -n "${TMUX_PANE:-}" ]; then
  SESSION=$(tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null | tr -d '\r\n')
fi
# The token goes in a curl config on fd 3, not argv, where ps would show it.
curl -s -m 2 -K /dev/fd/3 -X POST "http://127.0.0.1:$PORT/hook" \
  -H 'Content-Type: application/json' \
  -H "X-Tmux-Pane: ${TMUX_PANE:-}" -H "X-Tmux-Session: $SESSION" \
  --data-binary @- >/dev/null 2>&1 3<<EOF
header = "Authorization: Bearer $TOKEN"
EOF
exit 0
