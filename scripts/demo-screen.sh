#!/bin/sh
# Opens a screen in a RUNNING demo app and captures only its window: scripts/demo-screen.sh <screen> <out.png> [pid]
# (pid: which demo, when several run; default the newest)
# screens: rig, rig-graph, rig-work, rig-code, rig-progress, rig-stopped, rig-failed, terminal, glyphs, chat, panels, drawer (phone width), settings, host-editor, seat, rig-menu, stop-rig, project-worktrees, new-worktree, worktree, delete-worktree, runtime-icons, inbox, new, new-path-ok, new-path-missing, new-path-file, new-path-nogit (see tool/demo/main_demo.dart)
set -e
screen=${1:?usage: demo-screen.sh <screen> <out.png>}
out=${2:?usage: demo-screen.sh <screen> <out.png>}
root=$(cd "$(dirname "$0")/.." && pwd)
pid=${3:-$(pgrep -f 'Pocket Rig Demo.app/Contents/MacOS/Pocket Rig Demo' | tail -1)}
[ -n "$pid" ] || { echo "no demo app running: scripts/demo-build.sh first" >&2; exit 1; }
# Same name twice in a row would not re-open: clear first.
f=/tmp/pocketrig-demo-screen-$pid
: > "$f"
sleep 1
echo "$screen" > "$f"
sleep 2
wid=$(swift "$root/scripts/window-id.swift" "$pid")
screencapture -l "$wid" -o -x "$out"
echo "$out (window $wid, screen $screen)"
