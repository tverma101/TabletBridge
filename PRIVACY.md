# Privacy Policy

Effective date: 2026-08-29

This policy describes the Tablet Bridge source release, the macOS host, the
Android client, and any project website deployed from this repository. It is a
plain-language project disclosure, not legal advice or a representation that
the project satisfies every privacy law in every jurisdiction.

## Who operates this project

The public project contact is the `tverma101` GitHub account:
<https://github.com/tverma101>. No separate company, mailing address, or
hosted Tablet Bridge account service is represented by this repository. If a
law requires a different controller or privacy contact for a particular
deployment, that deployment must provide it before collecting regulated data.

## Data processed by the apps

- The macOS host captures pixels from the selected virtual display and sends
  them over USB or a local network to the connected Android client.
- The Android client sends touch, connection, and optional brightness-control
  messages to the Mac host.
- Wireless pairing creates a token locally on the Mac. Paired host details,
  app settings, and diagnostic state are stored in local app storage.
- The Android manifest disables Android app backup so local pairing state is
  not intentionally included in device or cloud backup flows.
- The Android QR scanner uses the device camera while scanning. The app does
  not intentionally upload camera frames to a Tablet Bridge server.
- Local diagnostics and operating-system logs may contain device names, local
  addresses, timing data, error messages, and user-provided paths. Do not share
  them publicly without redaction.

The source tree contains no first-party analytics, advertising, crash
reporting, user account, or cloud synchronization service. Network access is
used for the Mac/Android transport and pairing; it is not a general-purpose
proxy or remote-control service.

## Third-party services and components

The Android build uses AndroidX, CameraX, Material Components, Kotlin, Google
ML Kit barcode scanning, and JUnit. Their own terms and privacy policies may
apply. A separately deployed project website may contact GitHub for release
metadata and may be hosted by a third party. Review
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and the policies of the
services you choose to deploy.

## Retention and deletion

Tablet Bridge does not operate a project-owned cloud database. Local tokens,
settings, and logs remain until the user resets pairing, clears app data,
deletes the relevant log, or uninstalls the app. GitHub, hosting providers,
operating systems, and network equipment may retain their own records under
their policies.

## Your responsibilities

Only capture screens and connect devices when you have permission to do so.
Use wireless mode only on a trusted network, protect the pairing QR/token, and
redact logs before posting them. Organizations should perform their own review
before using the software with confidential, regulated, or employee data.

## Requests and changes

For a privacy question or request, contact the project through the maintainer's
GitHub profile and do not post sensitive personal information in a public
issue. This policy may be updated with a new effective date; the repository
history records the change.
