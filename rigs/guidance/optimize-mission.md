# Mission: make PocketRig fast

The person wants the app to feel instant. In priority order:

1. **Opening a chat lands on the latest message immediately.** Pull agent messages in the background while the app
   is open (reuse the drift chat cache in `lib/data/chat_cache.dart`), so opening a chat renders from cache at the
   bottom and then merges new messages without a jump.
2. **Images, files and artifacts open fast.** Cache what was already downloaded; don't refetch on every open.
3. **Rig details shows everything the rig made.** A section in the rig screen (`lib/ui/rig_screen.dart`) listing all
   images, files and artifacts from the rig's chats, using the same cache. Tapping one opens the existing viewer
   (`lib/ui/artifact_viewer.dart`).
4. General performance and caching wins the perf engineer measures along the way.

Routing: design comes first. The cache architect (`cache`) writes the cache design and the sync engineer (`sync`)
writes the background polling and connection design; they agree the contract with `perf` and `app` before code.
Then measurement, caching and background prefetch go to `perf`, and the rig-details media section goes to `app`.
After each build, `cache` and `sync` check the diff against their design before it goes to the reviewer. QA checks each item on a simulator against a one-line acceptance
check you write before work starts; the reviewer reads anything touching the cache schema, background work or SSH.

Done means: before and after numbers for items 1 and 2, the rig-details section working on a simulator, targeted tests
and `flutter analyze` clean, on local branches. Out of scope unless the person asks: OS-level background fetch when
the app is closed (iOS BGTask, Android WorkManager), new dependencies, redesigning screens.
