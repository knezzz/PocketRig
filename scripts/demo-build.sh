#!/bin/sh
# The demo app: Pocket Rig on the golden fixtures (invented rigs, asks and hosts; no network, SSH or keychain), under its
# own name and bundle id ("Pocket Rig Demo", dev.pocketrig.demo), so it never touches the installed app or its data.
#
#   scripts/demo-build.sh [commit] [light|dark] [mac|ios] [empty|-] [screen]
#
# commit: what to build (default HEAD), from a clean `git archive` copy. mac: builds, launches at 1280x800 and prints
# the PID and the window id (capture only that window: screencapture -l <id> -o -x shot.png). ios: builds for the
# simulator, installs and launches it on the booted one (boots an iPhone if none is), and prints how to screenshot.
# `empty`: This Mac only with nothing on it; `stopped`: This Mac only with just a stopped rig (`-`: the normal one). screen: open a screen at launch (rig, rig-graph,
# rig-work, rig-code, rig-progress, rig-stopped, terminal, glyphs, inbox, project-worktrees, new-worktree, worktree, delete-worktree; scripts/demo-screen.sh lists them all)
# so a capture needs no clicking. Only the demo app of an earlier run is quit (by its own PID), never
# the real Pocket Rig. The copy stays where the running demo app lives; the next run deletes it.
set -e
commit=${1:-HEAD}
theme=${2:-light}
target=${3:-mac}
variant=${4:-}
[ "$variant" = - ] && variant=
screen=${5:-}
root=$(cd "$(dirname "$0")/.." && pwd)
key=$(git -C "$(cd "$(dirname "$0")/.." && pwd)" rev-parse --short "$commit")-$theme-$target-${variant:-normal}-${screen:-home}
# The real path: that is how a running app's command line shows it (TMPDIR is a symlink under /var).
tmp=$(cd "${TMPDIR:-/private/tmp}" && pwd -P)
copy=$tmp/pocketrig-demo-$key

df -h /System/Volumes/Data | tail -1
# Several demos can run at once (a designer's dark one beside a light one): each lives in its own copy, named by what it is.
# Only an earlier run of the SAME copy is quit; copies nobody runs from any more are deleted.
old=$(pgrep -f "$copy/build/macos/Build/Products/Release/Pocket Rig Demo.app/Contents/MacOS/" || true)
[ -n "$old" ] && kill $old && sleep 1
for d in "$tmp"/pocketrig-demo-*; do
  [ -d "$d" ] && ! pgrep -f "$d/build/" >/dev/null && rm -rf "$d"
done
rm -rf "$copy"
mkdir -p "$copy"
git -C "$root" archive "$commit" | tar -x -C "$copy"
cd "$copy"
defines="--dart-define=POCKETRIG_DEMO=true --dart-define=POCKETRIG_THEME=$theme"
[ -n "$variant" ] && defines="$defines --dart-define=POCKETRIG_DEMO_VARIANT=$variant"
[ -n "$screen" ] && defines="$defines --dart-define=POCKETRIG_DEMO_SCREEN=$screen"

case "$target" in
  mac)
    # The identity, in this copy only: another name and bundle id (the release build is signed ad hoc, so nothing to register).
    sed -i '' 's/^PRODUCT_NAME = .*/PRODUCT_NAME = Pocket Rig Demo/; s/^PRODUCT_BUNDLE_IDENTIFIER = .*/PRODUCT_BUNDLE_IDENTIFIER = dev.pocketrig.demo/' macos/Runner/Configs/AppInfo.xcconfig
    # shellcheck disable=SC2086
    flutter build macos --release -t tool/demo/main_demo.dart $defines
    app="$copy/build/macos/Build/Products/Release/Pocket Rig Demo.app"
    open -n "$app"
    sleep 4
    pid=$(pgrep -f "$copy/build/macos/Build/Products/Release/Pocket Rig Demo.app/Contents/MacOS/" | tail -1)
    wid=$(swift "$root/scripts/window-id.swift" "$pid")
    echo "demo app: pid $pid, window id $wid (theme $theme${variant:+, $variant})"
    echo "capture: screencapture -l $wid -o -x shot.png   |   another screen: scripts/demo-screen.sh <screen> out.png $pid"
    ;;
  ios)
    # shellcheck disable=SC2086
    sed -i '' 's/dev\.pocketrig\.pocketRig/dev.pocketrig.demo/g' ios/Runner.xcodeproj/project.pbxproj
    sed -i '' 's#<string>Pocket Rig</string>#<string>Pocket Rig Demo</string>#' ios/Runner/Info.plist
    flutter build ios --simulator --debug -t tool/demo/main_demo.dart $defines
    xcrun simctl list devices booted | grep -q Booted || xcrun simctl boot "$(xcrun simctl list devices available | grep -m1 'iPhone' | sed 's/.*(\([0-9A-F-]\{36\}\)).*/\1/')"
    xcrun simctl install booted build/ios/iphonesimulator/Runner.app
    xcrun simctl launch booted dev.pocketrig.demo
    echo "capture: xcrun simctl io booted screenshot shot.png   (the simulator screen only)"
    ;;
  *) echo "target: mac or ios" >&2; exit 2 ;;
esac
