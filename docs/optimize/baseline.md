# Baseline (before any optimize change)

Status: static findings done; timings NOT yet taken (blocked on disk space, `/System/Volumes/Data` 99% full; lead
will say when freed). Never the Pixel 6a.

## Static findings (read from code, not yet timed)

Chat open, `lib/ui/chat_screen.dart` `_open()`:
1. `_showCached` loads the drift cache and decodes it before anything else, so a cached chat can paint before SSH.
2. Then `locateSessionLog` (SSH) and `SessionLogTail.start()` (SSH) run; history streams in through `_drain`
   (decode on an isolate above 150 lines, repaint at most every 120 ms).
3. `_checkMedia` opens a new SSH connection per chat open just to test which media paths are readable.
4. No code in this path scrolls to the bottom explicitly; the "latest at bottom" moment needs to be confirmed on screen.

Media:
- Images/videos, `lib/ui/chat/media_view.dart` `mediaBytes`: in-memory `Map<String, Future<Uint8List>>`. A second open
  in the same app run does not re-fetch; it is lost on app restart, so the first open after every launch is a full
  SSH connect + download.
- Files/artifacts, `lib/ui/artifact_viewer.dart`: no cache. Every open does `SshExec.connect` + `readFile`
  (max 256 KB). The second open re-fetches over SSH by construction.

## Method (the after-run repeats exactly this)

Setup: iPhone 17 Pro simulator, `flutter run --profile`, host = this Mac over SSH, chat = a long seat chat of
`pocketrig-optimize` (50+ messages; record the exact seat and message count). Wi-Fi/local only, same chat both runs.

Instrumentation: a throwaway local patch (not committed) with `Stopwatch` + `debugPrint('PERF ...')`:
- A. chat open: start at the tap (`initState` of the chat screen); stop at the first frame where the last transcript
  item is laid out at the bottom. Also log when the cache paint happens and when `tail.start()` returns.
- B. media: start at tap on the tile/viewer `initState`; stop when bytes are decoded and shown. Log whether
  `SshExec.connect` ran (that is the "re-fetch" answer).

Runs: 5 each, report median and range. Cold = app freshly launched; warm = chat re-opened in the same run. Media:
1st open, 2nd open (same run), 1st open after app restart. Cover one image, one file/artifact.

## Numbers

TBD.
