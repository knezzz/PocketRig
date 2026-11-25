# Sync design: foreground chat prefetch, one SSH connection, merge

Owner: experts-sync. Scope: while the app is open, keep every live agent chat in `ChatCache` current, so a chat
opens from the cache. Cache side: `cache-design.md`. Out of scope: OS background fetch, the rig chat room.

## Today (read in the code, not measured)

- Every `SshExec.connect` does a full TCP, key-exchange and auth handshake. Nothing reuses it. An open chat
  connects 3 times on open: locate (`session_log.dart:303`), the tail worker (`:236`) and git (`chat_screen.dart:454`).
  It connects again for git every 30 s, and for a loose agent every 3 s (`_pollLoose`, `chat_screen.dart:413`).
  `HostFeed._load` connects on every refresh: every 30 s, or every 5 s while SSE is down (`loose_agents.dart:84`).
  `_checkMedia` (`chat_screen.dart:1249`) and `ArtifactViewer` (`artifact_viewer.dart:49`) connect on every open
  (see `baseline.md`). The pool in section 2 removes all of these handshakes after the first.
- Chats are only cached after they are opened. `refreshMessages` (`fleet.dart:313`) reads 256 KB of every log every
  45 s just to show the newest line.
- Nothing pauses when the app goes to the background. The timers run until the OS suspends the app.

## 1. What is pulled, and how often

One `ChatSync` per `HostFeed`. It runs while the feed has listeners and the app is resumed.
- **Which chats**: `HostFeed.chatAgents` that are Claude, not stopped and not subagents, minus `openChatKeys`.
- **One batched exec per cycle** for all of those chats. For each chat, the script locates the log with
  `locateLogScript(exactOnly: true)` and prints `@@pr-log <i> <path> <size> <from> <len>` followed by exactly `len`
  raw bytes. It is split by length, not by lines. When nothing changed, the output is only the header lines.
- **Cursor** = the row's `(logPath, logOffset)`. A delta is `from = logOffset`, `len = min(size - from, 256 KB)`.
  A larger backlog catches up over the next cycles and is never skipped. Each cycle carries at most 1 MB.
- **Seed** (no row yet): the last 1 MB of the log, through `restart(..., seed: true)` (`openedAt = 0`), with
  `truncated`. The partial first line is dropped, as `SessionLogTail` does. `size < logOffset` or a different path
  means a restart, then a seed.
- **When**: every 10 s, and 2 s after any SSE event for the host (coalesced). Only one cycle runs at a time.
  An idle cycle is about 6 execs a minute per host and a few hundred bytes each.
- `refreshMessages` and its 256 KB-per-seat script go. `lastMessages` comes from what `ChatSync` just appended.

## 2. Connections

- **Sync worker**: one long-lived isolate per host that holds one `SSHClient`. dartssh2 decrypts at about 1 s per
  MB, and a 1 MB seed on the UI isolate drops frames (same reason as `_tailWorker`). The worker runs the cycle
  script and sends back the bytes. It reconnects on failure and closes after 2 minutes without a cycle.
- **Main-isolate pool** (item 4, `perf` measures): `SshExec.connect` leases a pooled `SSHClient` per host, and `close()`
  returns the lease. It stays open 2 minutes after the last lease. A client that `isClosed` or throws a socket or SSH
  error is evicted. `_SshTunnel` uses the same pool. At most 8 channels at once per connection (sshd `MaxSessions`
  defaults to 10); requests past that wait. The host-key check stays at connect.
- The open chat keeps its own `tail -F` worker. That is push, so it has the lowest latency.

## 3. Backoff and stopping

- When a cycle fails: wait 10, 20, 40, 80 s, and so on, up to 5 minutes. A success, a resume or a successful
  `HostFeed` refresh resets it. `HostKeyChangedException` stops sync for that host until the host is edited.
- **App goes to the background** (`AppLifecycleListener`, paused or hidden): stop `ChatSync` and the `HostFeed` and
  `Polling` timers, disconnect `LiveEvents`, and let the idle timers close the connections.
- **App is resumed** (also after an hour): one `HostFeed.refresh`, one sync cycle, and `LiveEvents` reconnects at
  once with the failure count reset (its backoff can wait 30 s today). The deltas catch up in 256 KB chunks.

## 4. Merge: no duplicates, no scroll jump

- **One writer per chat.** While a chat screen is open, it owns its key through `openChatKeys` and its tail writes
  the chat. `ChatSync` checks `openChatKeys` before it fetches and again before it writes. Both checks run on the
  main isolate, so they cannot race the screen. The screen registers its key before it calls `load()`.
- **Compare-and-set `append(path, from, to)`** is the safety net. When it returns false, `ChatSync` drops the batch,
  and the next cycle reads the row again. Only whole lines are passed (full, not slimmed). `to` is the byte after
  the last `\n`, so a half-written line is fetched again next cycle.
- SSE events carry no chat text, so the only way a message can arrive twice is two readers of one log. The byte
  cursor plus one writer per chat prevents that.
- **Open chat**: the screen renders the cache, then its tail resumes from `logOffset`, and new items are only
  appended at the end of the reversed list. A rewind is the only full replace.

## Contract points (to agree)

- cache: CAS `append` and `openChatKeys` as in `cache-design.md`. **Ask:** seed rows get `openedAt = 0`, so the LRU
  evicts them before chats the person opened.
- app (agreed): register in `openChatKeys` (from `chat_cache.dart`) before `load()`, and remove in `dispose`.
  When scrolled up and items are appended, `jumpTo(pixels + added extent)`; at the bottom, follow as today. On a
  CAS false the screen keeps today's `_caching = false` and does not re-tail (its lines are already on screen).
- **First open of a seed row** (`load()` reports it was a seed): the seed paints the first frame only. The screen
  then runs today's read (restart, then tail from `size - historyBytes`) into a fresh transcript and swaps it in when
  the tail's `committedOffset` reaches the seed's `logOffset`. Until the swap, the seed stays on screen. After that,
  the chat has today's history, and its media enters the index. The flag is `CachedChat.seeded`. The fresh read
  doesn't write until the swap, then calls `restart` and writes once, so quitting mid-read keeps the seed. The swap
  keeps the distance from the bottom and waits while the person is dragging.
- perf (agreed): before and after, SSH connects and stdout bytes per minute, over 5-minute windows, with the app idle
  on Projects and with one chat open. `SshLog` can't do this: it is per isolate, records no bytes and is empty in
  release builds. So a throwaway local counter at `sshConnect`, `SshExec._run` and the worker's stdout gets the
  worker isolates' counts over their ports. The same patch runs for before and after, in a debug or profile build.
- **Decided (lead): 1 MB seed.** Known gap: in rig details, older media from a chat that has never been opened
  shows up once that chat is opened. perf measured 1 MB of raw log at only 60 to 180 lines, so until the first open,
  rig details shows the media from those lines only. The seed stays capped by bytes, not lines: lines that carry a
  screenshot can be hundreds of KB each, so a line cap has no limit on bytes. The first-open swap above makes that true, so a seeded chat keeps today's
  history.
