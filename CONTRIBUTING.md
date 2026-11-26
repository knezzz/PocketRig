# Contributing to PocketRig

Thanks for helping. Bug reports, fixes and small focused features are all welcome.

## Before you start

- **Bugs:** open an issue with what you did, what you expected and what you saw. Include your platform, the app commit and `rig --version` on the host.
- **Features:** open an issue first, so we can agree on the shape before you write code.
- **Security issues:** don't open an issue. See [SECURITY.md](SECURITY.md).

## Setup

Flutter 3.47.9 (Dart 3.13), the same version CI uses.

```sh
flutter pub get
flutter analyze
flutter test
```

The host watcher has its own tests: `node --test host/watcher/*.test.mjs`.

To build for iOS or macOS, set your own `DEVELOPMENT_TEAM` in Xcode, and change the bundle ids if you ship your own build (see the README's Building section).

## Making a change

- Keep a pull request to one change, and keep it as small as it can be while still doing the job.
- `flutter analyze` must report no issues, and `flutter test` must pass. CI runs both.
- **UI changes:** run `flutter test test/golden --update-goldens`, then check that only the `goldens/ci/*.png` images you meant to change have changed. Commit those.
- New tap targets need a `Semantics` label with `onTap` (`test/semantics_tap_test.dart` checks this).
- Match the style of the surrounding code. Don't run `dart format` on whole files: the repo isn't formatted that way, and it rewrites hundreds of unrelated lines.
- The OpenRig daemon API is internal and changes between releases. Keep daemon calls in `lib/api/openrig_client.dart`.
- Never commit secrets, SSH keys, host names or personal paths, test fixtures included.

## License

By contributing, you agree that your contributions are licensed under the [Apache License 2.0](LICENSE), the project's license.

## Code of Conduct

Please follow the [Code of Conduct](CODE_OF_CONDUCT.md).
