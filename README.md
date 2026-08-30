# Tablet Bridge

Tablet Bridge turns an Android tablet into an extended display for macOS over
USB-C or a local Wi-Fi network. It includes a Swift macOS host and a Kotlin
Android client, with hardware-accelerated video, touch input, wireless QR
pairing, a virtual display, and tablet brightness control.

> This is an independent fork maintained by `tverma101`. It was derived from
> [tranvuongquocdat/SideScreen](https://github.com/tranvuongquocdat/SideScreen)
> and is not affiliated with, endorsed by, or operated by the upstream
> maintainer. See [UPSTREAM.md](UPSTREAM.md) and [NOTICE.md](NOTICE.md).

## Project status

This repository is a source release and development fork. Builds are not
notarized or distributed through an app store by default. Hardware support,
latency, color, and refresh behavior vary by Mac, Android tablet, cable, and
network. Read the warnings in the installation section before using it with
important work.

## Features

- USB-C transport through ADB reverse forwarding.
- Wireless LAN transport with one-time QR pairing and a locally generated
  authorization token.
- A true macOS virtual display rather than a mirrored screenshot.
- H.265 with H.264 fallback where the Android device has no usable HEVC
  decoder.
- Touch forwarding, rotation/flip controls, HiDPI options, adaptive capture
  cadence, and tablet brightness control.
- Local diagnostics and test tools; no project analytics, ads, or account
  service are included in this source tree.

The `sidescreen://` pairing scheme and several internal compatibility keys are
retained so that the fork can interoperate with compatible existing peers. The
display name, app bundle identity, Android application ID, repository links,
and public support surface are distinct from upstream. Internal Swift module
names and source package paths remain unchanged where changing them would
break compatibility or unnecessarily enlarge the fork's first release.

## Requirements

| | macOS host | Android client |
|---|---|---|
| OS | macOS 13 Ventura or newer | Android 8 / API 26 or newer |
| Hardware | Apple Silicon or Intel Mac | Hardware H.265 decoder recommended |
| USB | USB-C port and `adb` | USB-C cable and USB debugging enabled |
| Wireless | Same local network as the tablet | Camera permission for QR pairing |

The Mac host needs Screen & System Audio Recording permission to capture the
virtual display. Wireless mode needs Local Network access. The Android client
requests camera access only for QR scanning and uses network access to connect
to the Mac host.

## Build from source

Clone the repository after it is published:

```bash
git clone https://github.com/tverma101/TabletBridge.git
cd TabletBridge
```

Build the macOS host:

```bash
security find-identity -v -p codesigning
./scripts/build_mac.sh
```

The build requires an Apple Development signing identity. It creates
`TabletBridge.app` and a versioned DMG in the repository root; those generated
artifacts are ignored by Git. Install the exact bundle with:

```bash
./scripts/install_mac.sh --launch
```

Build the Android client:

```bash
cd AndroidClient
./gradlew assembleDebug
```

Or use the repository wrapper:

```bash
./scripts/build_android.sh
```

The release script uses a debug signing configuration for local artifacts.
Replace it with your own release key and distribution process before shipping
an Android build to other people.

## First run

1. Start `TabletBridge.app` on the Mac and grant Screen Recording when macOS
   asks.
2. For USB, enable Android USB debugging, connect the cable, and tap Connect.
3. For wireless, select the Wireless tab, scan the QR code displayed by the
   Mac host, and connect while both devices are on the same trusted LAN.
4. Reset the pairing token before giving away or retiring a Mac that was
   paired with a tablet.

Do not expose the wireless listener to an untrusted network. The pairing token
is an access credential for the local streaming and control endpoints.

## Validation

Run the local unit tests with:

```bash
./scripts/dev-test.sh
```

The repository also contains focused transport, capture, lifecycle, and
quality-lab tools. A passing unit test does not prove that a particular Mac,
Android decoder, cable, display, or Wi-Fi network will work.

## Privacy and safety

The host captures the selected macOS display and sends frames to the paired
Android client. It can also receive touch and brightness commands. Pairing
tokens, settings, and diagnostics are stored locally by the respective app.
The source tree contains no first-party analytics, advertising SDK, crash
reporter, or hosted account backend. Camera frames are used for QR scanning;
they are not intentionally uploaded to a Tablet Bridge server.

See [PRIVACY.md](PRIVACY.md), [TERMS.md](TERMS.md), and [SECURITY.md](SECURITY.md)
for the project policies and their limitations.

## Contributing and support

- Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.
- Use [GitHub Issues](https://github.com/tverma101/TabletBridge/issues) for
  reproducible bugs and feature requests.
- Do not put credentials, pairing tokens, private logs, or personal data in a
  public issue. Follow [SECURITY.md](SECURITY.md) for vulnerabilities.

## License and attribution

The source is distributed under the [MIT License](LICENSE), subject to the
copyright and license notices that accompany inherited and third-party
components. The upstream project is credited in [UPSTREAM.md](UPSTREAM.md);
the Qualcomm shader includes its own BSD-3-Clause notice. See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the direct dependency
inventory and review obligations.

This project is not affiliated with Apple, Google, Android, Samsung, Qualcomm,
GitHub, or the upstream SideScreen project. Their names and marks belong to
their respective owners; see [TRADEMARKS.md](TRADEMARKS.md).
