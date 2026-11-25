# PocketRig startup team culture

PocketRig is a Flutter app that lets a person run and answer their OpenRig agents from their phone. Read `README.md`
for how it fits together. This file covers how the team works.

## How the person works

- They send a stream of small, user-visible requests, often a new one mid-turn. Take each as its own small change,
  commit it by itself, and keep going; don't batch them into one big branch.
- They post larger ideas in the `Idea-builder` chat room. The lead checks `rig chatroom history Idea-builder` after
  each task and keeps `rig chatroom wait Idea-builder --timeout 86400 --json` running while idle.
- Done means on their devices: after an approved push to main, the release macOS app on this Mac is rebuilt and
  relaunched, and the release build goes to your test phone (their iPhone). The native engineer runs that round.

## Ship small

- Build the smallest version that does the job, then stop. Name what you left out in one line instead of building it.
- Fix the shared cause once. No options, abstractions or "for later" code nobody asked for.
- Every claim of "done" says what you ran and what you did not check. Say "verified" only if you ran it.
- A clean result is a fine result. Don't create work for an idle seat.
- Verify against the live source when a bug is about what the app shows. Example: the daemon's `lastActivityAt` moves on
  any pane redraw; real work is the last reply (`modelObservation.observedAt`) or hook event (`agentActivity.eventAt`).

## The checkout

- Everyone works in the main checkout; no worktrees unless the lead says several seats are coding at once.
- Commit by explicit path (`git commit -- <paths>`); changes you didn't make belong to someone else. A path commit
  takes the whole file, so if another seat has unfinished hunks in it, ask them or make a joint commit.
- Don't switch branches, stash or reset.
- Don't run `dart format` on whole files. The repo isn't formatted that way, and it rewrites hundreds of unrelated
  lines. Match the surrounding style by hand.
- Release builds come from a clean copy of the commit (`git archive HEAD` into a scratch folder), never from the
  checkout, which carries other seats' uncommitted work.

## Tests

- `flutter test` runs on this Mac, goldens included. After a UI change, run `flutter test test/golden --update-goldens`
  and check that only the expected `goldens/ci/*.png` changed. The macOS variants exist only in the main checkout.
- `test/semantics_tap_test.dart` fails for any tappable `Semantics` without `onTap`. Give new tap targets one.
- Work scheduled in a post-frame callback needs one more `await tester.pump()` before you assert on it.

## This machine

- Run Gradle as `./gradlew --no-daemon` from `android/`. Without it, it can hang on another tool's daemon.
- Check `df -h` before simulator, emulator or release builds. When the disk is about 99% full, installs hang without an
  error.
- The person's own Android phone (adb device `YOUR_ANDROID_ID`) runs Pocket Rig. Never install to it or drive
  it. Use an emulator or simulator.
- Your test phone (an iPhone, devicectl `YOUR_IPHONE_ID`) takes release installs once tests pass.
  "Unable to locate device" or "connection could not be established" is usually temporary: wait and retry.

## Ask the person first

Pushing, opening or commenting on PRs, merging, tagging and store changes. Tell your lead, who asks the person. Never
put secrets, SSH keys or host credentials in messages or commits.

## After startup or compaction

Run `rig whoami --json`. It tells you who you are and how to reach your peers. If blocked on a peer, tell them with
`rig send`, then your lead. Don't stall silently.

## Commands that don't stop the person

Keep commands plain so they run without approval: run `rig` commands as they are, without pipes or `$VARIABLES`, write
files with your file tool rather than a heredoc, and run one plain command at a time.
