# Cache design: chats, media, rig media index

Owner: experts-cache. One store: the drift `ChatCache` in `lib/data/chat_cache.dart`, file in the OS cache folder.
The host is always the source of truth. Everything here is a copy that can be thrown away.

## 1. Chat lines (existing tables `chats`, `chat_lines`)

- **Key**: `(hostId, chatKey)`, where `chatKey` is `rigId/logicalId` or `loose/<id>`. It stays unique as today.
  Two hosts never share rows.
- **Resume point**: `chats.logPath` + `chats.logOffset`, the byte after the last line stored. A different `logPath`,
  or a rewind of the log, calls `restart()`: the old lines go, and a new row starts at offset 0.
- **Seed rows**: sync creates a chat before anyone opens it with `restart(..., seed: true)`, which sets `openedAt = 0`.
  The LRU then evicts seeds before chats the person opened. `load()` sets `openedAt` to the time the person opens it.
  It also returns `CachedChat.seeded`, which is true when `openedAt` was 0 before it set the new time. On a seeded
  chat, the screen paints the seed and then does today's full read through `restart()`, the path used when a chat
  isn't resumed. That means the full history lands in the cache too.
- **Merge without duplicates or gaps**: `append` becomes compare-and-set. It writes only when the row still has the
  `logPath` and `logOffset` the writer read:
  `append(hostId, key, path, fromOffset, toOffset, truncated, lines) -> bool`.
  If it returns false, the batch is dropped. Background sync then reads the row again next cycle and continues from
  `row.logOffset`. An open chat screen keeps today's `_caching = false` instead: its lines are already on screen,
  and tailing again would show them twice. The offset and lines change in one transaction, so a crash never stores
  lines without their offset.
- **One writer per chat**: an open chat screen writes its own chat. Background sync skips any key in
  `openChatKeys`, a top-level `Set<String>` in `chat_cache.dart`. The screen adds its key before `load()` and removes
  it on dispose. Sync writes every other live chat. The
  compare-and-set catches a race where both writers append to the same chat.
- **Opening**: `load()` returns the lines oldest first. The screen decodes them on an isolate and lays out from the
  bottom. A per-chat budget keeps that decode small (see Budgets). If perf measures it as too slow at 4 MB, add
  `load(..., lastLines: n)`. Don't build it before that.
- **Budgets** (changed): per chat **4 MB** of slimmed lines, down from 25 MB. Today one chat can be bigger than the
  16 MB total, so the total trim evicts every other chat. Total **64 MB**, up from 16 MB, because sync now caches
  every live chat, not only the ones opened. Eviction stays the same: the oldest lines inside a chat (which sets
  `truncated`), then the least recently opened chats. A dropped chat takes its media rows with it (`_drop`).
- **Pruning** (changed): a chat goes when its rig or loose agent is gone from the host. It no longer goes when a seat
  or rig only stops, so rig details still lists what a stopped rig made. The LRU budget bounds the size. An
  incomplete daemon answer still deletes nothing, as today. This updates `goneChats` and its test.

## 2. Rig media index (new table `chat_media`)

`chat_media(chatId, kind, ref, name, toolId, touchedAt)`. `kind` is `image | video | file | artifact`. `ref` is the
host path, or for an artifact the claude.ai URL. The table is unique on `(chatId, kind, ref)`.

- **Filled in `append`, in the same transaction**, from the full log lines, before they are slimmed: `slimLogLines`
  also returns the media it finds, in the same isolate. That way the cache's clipping (300 characters) and line
  trimming never hide anything. One shared extractor reuses `writtenPath` (Write/Edit/MultiEdit/NotebookEdit,
  `kind=file`) and `mediaPathsIn(text, cwd)` (image/video) on tool input and results. An `Artifact` tool_use
  records `name` plus `toolId`, and its tool_result fills in the URL.
- **Errors**: an `is_error` tool_result deletes the rows that have that `toolId`. Inserts on `(chatId, kind, ref)` are
  ignored when the row exists, so a later error doesn't remove a path that an earlier call wrote. Known limit: two
  parallel edits of one path where the first one fails.
- **Each mention bumps `touchedAt`**: the line's timestamp. This is how media goes stale (section 3).
- **Read**: `Stream<List<RigMedia>> watchRigMedia(hostId, rigId)` on `ChatCache` returns
  `RigMedia{kind, ref, name, touchedAt}`, a plain class in `chat_cache.dart`. The rows are `chat_media` joined to
  `chats` where `chatKey LIKE 'rigId/%'`, newest `touchedAt` first and grouped by `ref`. The rig screen reads it with
  a `StreamBuilder` on the global `chatCache`, the way `hosts_screen` does. There is no new provider, and nothing has
  to be decoded. It shows only what is cached, so a chat that was never pulled, or was evicted, is missing from it.
- **Media check**: `_checkMedia` opens an SSH connection on every chat open, to find out which named paths exist
  (baseline item 3). The chat screen first fills `_mediaOk` from `media_files`: a path stored there was read
  successfully. Only paths not stored there still need the SSH check. The check runs after the first paint and
  doesn't block it.

## 3. Downloaded bytes (new table `media_files` + files)

`media_files(id, hostId, path, bytes, fetchedAt, openedAt)`, unique on `(hostId, path)`. The bytes are in
`<appCache>/media/<id>`. `mediaBytes()` in `media_view.dart` and the `readFile` in `ArtifactViewer` both go through
`mediaCache.get(host, path)`. The viewer constructors don't change: they still take only a path and get the host from
`AppScope.read(context).active`.

1. The row exists, the file exists and nothing is stale: return the file. **No SSH.**
2. Otherwise download over SSH (keeping today's 100 MB and 256 KB limits), write `media/<id>.part` and rename it into
   place, then upsert the row. A failed fetch stores nothing. The current in-memory map stays as the de-dupe for
   fetches already in flight.
- **Stale**: `fetchedAt` is older than any `chat_media.touchedAt` for that host and path, which means a newer chat
  line wrote or mentioned the file. Reload in the viewer also forces a fetch. Known limit: a file changed on the host
  with no chat line about it stays old until Reload.
- **Video**: plays straight from the cached file. This removes the copy to the temp folder.
- **Budget**: 256 MB in total. Least recently opened first, files over 50 MB are not stored (they are still shown
  from memory), and trimming runs after each insert.
- **Missing file**: the OS purged the cache folder, so the row points to nothing. Delete the row and treat it as a
  miss.
- **Full disk**: if a write fails, return the downloaded bytes, store nothing and log it. It never crashes, and it
  never leaves a `.part` file in place of a good one.

## 4. Schema change and lifecycle

- `schemaVersion` 1 → 2. In `onUpgrade` from 1: clear `chats`/`chat_lines`, then create `chat_media` and
  `media_files`. Old lines have no media index and can't be backfilled from clipped lines. Cost: after the update,
  each chat opens once the slow way, and not at all offline until it has been fetched.
- If drift throws on a downgrade (a dev build only), the cache catches it and falls back to the slow path, as today.
- **Host removed** (`forgetHost`): drop its chats and media rows, plus its `media_files` rows and files.
  **Clear cache** in Hosts clears all three. The Hosts cache row adds the media bytes to its count.
- **Rig deleted**: `prune` drops its chats and media rows. Its downloaded files age out through the LRU.

## Contract

- sync (agreed 10:43Z): writes only through compare-and-set `append`, skips `openChatKeys`, and passes full lines.
  The cache slims them and indexes the media. Seed rows use `seed: true`. A seed drops the partial first line, as
  `SessionLogTail` does with `_dropFirstLine`.
- **Condition (lead, 10:45Z)**: opening a seeded chat must still backfill older history, up to 25 MB, as the first
  open does today. The backfill runs after the latest messages from the cache are on screen.
- **Seed history (closed 10:45Z)**: a seed only paints the first frame. On first open the screen does today's full
  read, of up to 25 MB, and swaps it in when the read reaches the seed's offset. So the chat shows the same history
  as today. Rig details still lists only the media from the seed until the chat is opened once. Perf measured two
  logs at 10:46Z: 90 MB and 25 MB of raw log slim down to about 1 MB each, so the 4 MB limit holds. The last 1 MB of
  raw log is only 60 to 180 lines, so in a chat that was never opened, rig details shows only a short recent slice.
- perf (agreed 10:42Z): takes the baseline on the current build and records each test chat's `chat_lines` bytes. If
  no chat is near 4 MB, it says so instead of extrapolating. After v2, it opens each chat once before timing, because
  the upgrade clears the cache. It proves "no SSH on the second open" by logging `SshExec.connect` calls.
- app (agreed 10:42Z): the rig section reads `watchRigMedia`. Image and video open `MediaViewer(paths: [ref])`, a
  file opens `ArtifactViewer(path: ref)`, and an artifact opens `launchUrl(ref, externalApplication)`, as the chat
  does today. Acceptance check 3 says "opens artifact_viewer"; that fits files only, and the lead should reword it.
