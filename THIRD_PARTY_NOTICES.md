# Third-party notices

This inventory covers direct dependencies and material inherited components
identified during the public-snapshot review. Transitive dependencies and
platform SDK terms still apply; regenerate and review a complete dependency
notice set before shipping a binary.

## Direct Android dependencies

The Android build declares the following direct libraries in
`AndroidClient/app/build.gradle.kts`:

- AndroidX Core KTX, AppCompat, ConstraintLayout, and Lifecycle Runtime KTX —
  Apache License 2.0.
- AndroidX CameraX — Apache License 2.0.
- Google Material Components for Android — Apache License 2.0.
- Kotlin Android plugin/runtime — Apache License 2.0.
- Google ML Kit barcode scanning — review the artifact's bundled license and
  Google's current terms before redistribution.
- JUnit 4 — Eclipse Public License 1.0.
- Gradle Wrapper — Apache License 2.0; see the wrapper distribution and
  `AndroidClient/gradle/wrapper/gradle-wrapper.properties`.

Authoritative license texts and notices are supplied by each dependency. Start
with the official project pages:

- <https://www.apache.org/licenses/LICENSE-2.0>
- <https://www.eclipse.org/legal/epl-1.0/>
- <https://developer.android.com/jetpack>
- <https://github.com/material-components/material-components-android>
- <https://developers.google.com/ml-kit/terms>

## Inherited and embedded components

- The upstream Side Screen source and inherited artwork are covered by the
  upstream notices and [LICENSE](LICENSE), subject to verifying any asset
  provenance before redistribution.
- `AndroidClient/app/src/main/assets/sgsr1_shader_mobile_edge_direction.frag`
  includes Qualcomm Innovation Center's BSD-3-Clause copyright and SPDX
  notice. Preserve that header in copies and derivatives.
- The FidelityFX CAS reference mentioned in the source is MIT licensed; this
  repository should not remove its source attribution when modifying that
  implementation.
- macOS system frameworks and SDKs are supplied by Apple under Apple's terms;
  they are not relicensed by this repository.

## Review obligation

License compatibility, notices, patents, export restrictions, trademark use,
and distribution rights depend on the exact source and binary being shipped.
This file is an inventory, not legal advice. Update it when dependencies,
assets, or release packaging change.
