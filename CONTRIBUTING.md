# Contributing to Tablet Bridge

Tablet Bridge is an independent fork of the upstream SideScreen project.
Please read [UPSTREAM.md](UPSTREAM.md), [NOTICE.md](NOTICE.md), and
[SECURITY.md](SECURITY.md) before contributing.

## Before opening an issue or pull request

- Search existing issues and pull requests first.
- Do not include pairing tokens, signing keys, private logs, personal data, or
  confidential screen captures.
- For a suspected vulnerability, use the private process in [SECURITY.md](SECURITY.md)
  instead of a public issue.
- Confirm that you have the right to submit your contribution under the
  project's MIT license and any component-specific notices.

## Development setup

The Mac host requires macOS 13 or newer, Xcode 15 or a compatible Swift 5.9+
toolchain, and an Apple Development signing identity for a full app build.
The Android client requires Android Studio or the repository Gradle wrapper,
JDK 21, and Android SDK 34.

```bash
git clone https://github.com/tverma101/TabletBridge.git
cd TabletBridge
./scripts/dev-test.sh
```

Build each side independently when working on platform-specific changes:

```bash
cd MacHost && swift test
cd ../AndroidClient && ./gradlew testDebugUnitTest
```

Real USB, Screen Recording, wireless, decoder, refresh-rate, and display
behavior requires the relevant hardware and permissions. State exactly what
you tested in the pull request; unit tests do not prove end-to-end behavior.

## Coding standards

- Follow Swift API Design Guidelines and Kotlin coding conventions.
- Prefer focused changes with tests for protocol, lifecycle, permission, and
  state-machine behavior.
- Keep user-facing text and legal/support links branded for Tablet Bridge.
- Preserve upstream and third-party copyright/license notices.
- Do not add telemetry, remote collection, or new network endpoints without a
  documented privacy review.

## Pull requests

Use a descriptive branch and commit message. Explain the user-visible change,
compatibility impact, privacy/security implications, and validation evidence.
Update the README, changelog, legal notices, or support policy when behavior
or distribution changes.

Maintainers may request a smaller change, additional tests, or a hardware
reproduction before merging.
