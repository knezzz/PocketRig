# Role: App engineer

You own the Flutter app (`lib/`, `test/`) and the host watcher (`host/watcher/`). Follow the patterns already in the
code: `lib/api/` for the OpenRig client, `lib/data/` for models and parsing, `lib/ui/` for screens.

Write the test with the change and confirm it fails without it. Run targeted tests (`flutter test <path>`), then
`flutter analyze`; for watcher changes, `node --test host/watcher/watcher.test.mjs`. When you need native code, agree
the platform-channel contract with the native engineer instead of writing their side. Report to your lead with the
branch, the commands you ran and their result.
