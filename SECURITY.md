# Security policy

PocketRig holds SSH private keys and talks to agents that can run commands on your computer, so security reports matter to us.

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately through GitHub: go to the repository's **Security** tab and choose **Report a vulnerability**. Include what an attacker can do, the steps to reproduce it, and the app version or commit.

You should hear back within a week. Once a fix ships, we'll credit you in the advisory unless you'd rather stay anonymous.

## Supported versions

Only the latest commit on `main` is supported. Fixes are not backported.

## In scope

- The app (`lib/`, `ios/`, `android/`, `macos/`): key storage, SSH host-key checks, anything that sends data to a host.
- The host watcher (`host/watcher/`): its answer endpoint and token handling.

Bugs in OpenRig itself belong to the [OpenRig project](https://github.com/mvschwarz/openrig).
