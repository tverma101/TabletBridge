# Security policy

## Scope

Report vulnerabilities in the Tablet Bridge source, macOS host, Android
client, pairing flow, transport, build scripts, or published project artifacts.
Third-party operating systems, Android firmware, GitHub, Gradle, and Google
libraries should also be reported to their respective maintainers when the
issue is outside this repository.

## Report privately

Do not open a public issue for an exploitable vulnerability, pairing token,
private log, or proof of unauthorized access. After this repository is
published, use GitHub's private vulnerability reporting at:

<https://github.com/tverma101/TabletBridge/security/advisories/new>

If that channel is unavailable, contact the maintainer through
<https://github.com/tverma101> and ask for a private reporting route. Please
include the affected commit or release, platform/device, reproduction steps,
impact, and any safe mitigation. Remove tokens and personal data from the
report.

## Security model

Wireless pairing is intended for a trusted local network. The pairing token is
an access credential for the streaming/control endpoints; do not publish QR
codes or expose the listener through router port forwarding. USB mode depends
on the device's ADB authorization. Screen capture and touch forwarding are
powerful permissions and should be granted only to builds you trust.

## Release guidance

This source tree is not a signed or notarized distribution channel by default.
Review source, dependency licenses, signing identity, release checksums, and
the exact artifact before installing. Debug-signed Android artifacts are for
development and testing, not production distribution.
