# Public fork preparation record

Date: 2026-08-29

## Goal

Prepare a public, independently branded release of the private SideScreen
checkout without exposing private development history, evaluation receipts,
local device details, or upstream fundraising and support links.

## Inspected scope

- Canonical private checkout: the operator's existing private SideScreen checkout
- Upstream project: `tranvuongquocdat/SideScreen`
- Public staging checkout: the separate Tablet Bridge staging checkout
- macOS host, Android client, build/install scripts, website/resources,
  dependency declarations, licenses, and repository metadata

## Changes in this staging snapshot

- Added Tablet Bridge branding, fork provenance, privacy, terms, security,
  support, trademark, conduct, contribution, and third-party notice files.
- Changed public repository links, macOS bundle identity, Android application
  ID, app labels, custom debug actions, generated app/DMG names, and local log
  names.
- Removed the legacy hardcoded private E3 video endpoint from the public
  Android connection path.
- Excluded private backups/evaluation receipts and inherited upstream
  marketing/donation assets from the public snapshot.
- Kept protocol and internal source identifiers that are required for practical
  compatibility; these are called out in the public README and upstream notice.

## Validation

- `swift test` in `MacHost`: 62 tests passed.
- Android `testDebugUnitTest`: passed with the machine-local SDK supplied via
  environment variables; `assembleDebug`: passed.
- Shell/Python syntax, plist/XML validity, staged private-fingerprint scan, and
  the macOS universal app/DMG packaging script: passed.
- Generated app metadata reports `Tablet Bridge`, executable `TabletBridge`,
  bundle ID `dev.tabletbridge.host`, and Android package
  `dev.tabletbridge.app`.

## Evidence state

Implementation: committed locally in the one-commit public staging checkout;
canonical private checkout unchanged.
Testing: source, package, metadata, and packaging checks passed. Existing
compiler deprecation/unused-value warnings remain; no new warning triage was
performed.
Installed/live: not claimed; no Tablet Bridge public artifact has been
installed on a user device or exercised through a real Mac-to-Android session.
User-confirmed: pending exact public name and legal contact confirmation.

## Blocker and next action

Do not create, rename, push, or make a GitHub repository public until the
operator confirms the public repository name and the legal/contact identity to
publish in project policies. Then create the clean public repository, push
only this snapshot, verify the remote contents, and make that exact repository
public. A real USB/wireless hardware session remains a separate post-
publication validation boundary.
