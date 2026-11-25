#!/bin/sh
# Installs the PocketRig watcher as a launchd agent next to the OpenRig daemon.
#
#   ./install.sh <ntfy-topic> [ntfy-server] [host-name]
#
# The topic is shown in the app under Hosts → (host) → Notifications.
# Logs: ~/Library/Logs/pocketrig-watcher.log. Remove with ./install.sh --uninstall
set -eu

LABEL=dev.pocketrig.watcher
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Removed $LABEL (the Claude Code hook in ~/.claude/settings.json stays; it does nothing without the watcher)"
  exit 0
fi

TOPIC=${1:?usage: install.sh <ntfy-topic> [ntfy-server] [host-name]}
SERVER=${2:-https://ntfy.sh}
HOSTNAME_FOR_APP=${3:-$(scutil --get LocalHostName 2>/dev/null || hostname -s)}

case "$TOPIC" in
  *[!A-Za-z0-9_-]*|'') echo "Topic may only contain letters, digits, - and _" >&2; exit 1 ;;
esac
case "$SERVER" in
  http://*|https://*) ;;
  *) echo "Server must start with http:// or https://" >&2; exit 1 ;;
esac
case "$SERVER$HOSTNAME_FOR_APP" in
  *[\<\>\&\"\']*) echo "Server and host name may not contain < > & \" '" >&2; exit 1 ;;
esac

command -v launchctl >/dev/null 2>&1 || { echo "This installer is for macOS (it uses launchd)" >&2; exit 1; }
NODE=$(command -v node || true)
[ -n "$NODE" ] || { echo "node not found on PATH (OpenRig needs it too)" >&2; exit 1; }
"$NODE" -e 'process.exit(parseInt(process.versions.node) >= 22 ? 0 : 1)' || { echo "The watcher needs Node 22 or newer" >&2; exit 1; }
# Checked before touching anything: a watcher already running keeps running.
launchctl print "$DOMAIN" >/dev/null 2>&1 || { echo "launchd has no desktop session for this user. Log in at the Mac, then try again." >&2; exit 1; }
DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$DIR/pocketrig-watcher.mjs"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$NODE</string><string>$SCRIPT</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>POCKETRIG_NTFY_TOPIC</key><string>$TOPIC</string>
    <key>POCKETRIG_NTFY_SERVER</key><string>$SERVER</string>
    <key>POCKETRIG_HOST</key><string>$HOSTNAME_FOR_APP</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/pocketrig-watcher.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/pocketrig-watcher.log</string>
</dict>
</plist>
PLIST

launchctl bootout "$DOMAIN" "$PLIST" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST" || {
  echo "launchd wouldn't start the watcher. At the Mac, run: sh \"$DIR/install.sh\" $TOPIC $SERVER" >&2
  exit 1
}
echo "Installed $LABEL → $SERVER/$TOPIC (host \"$HOSTNAME_FOR_APP\")"
echo "Logs: tail -f ~/Library/Logs/pocketrig-watcher.log"
# Claude Code hooks, so agents started by hand (outside a rig) notify too.
if [ "${POCKETRIG_NO_CLAUDE_HOOKS:-}" != 1 ]; then
  chmod +x "$DIR/claude-hook.sh"
  "$NODE" "$SCRIPT" install-hooks "$DIR/claude-hook.sh"
fi
echo "Action buttons call this Mac on port ${POCKETRIG_ANSWER_PORT:-7434} over Tailscale (token in ~/.config/pocketrig/answer-token)."
