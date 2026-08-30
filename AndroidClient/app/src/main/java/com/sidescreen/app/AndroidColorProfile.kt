package com.sidescreen.app

/**
 * Receiver-side color profile for the Tab S8+ SDR display path.
 *
 * The stream is already rendered by macOS before it reaches Android. This
 * profile cannot make arbitrary macOS glyphs become Android glyphs. It is a
 * conservative receiver-side correction for the repeatable SDR tone behavior
 * measured on the 2800x1752 USB sRGB patch corpus and matched against the
 * same chart rendered natively by Android.
 *
 * It is anchored at black, white, and measured neutral gray points, so text
 * and smooth grayscale ramps remain neutral. It is an Android-side GPU
 * profile, not a claim that the source has become native Android content.
 */
object AndroidColorProfile {
    const val NAME = "Android sRGB / BT.709 Tone Balance"
    const val DEFAULT_ENABLED = true

    /**
     * The experimental USB bridge is a quality/power diagnostic path, not a
     * high-refresh gaming path. Keep its Android presentation at a stable
     * 60 FPS while leaving the normal USB and wireless policies independent.
     */
    const val USB_BRIDGE_FPS_CAP = 60

    /**
     * GLSL helper shared by the SurfaceTexture and decoder-fed YUV paths.
     * The uniform keeps A/B switching live without rebuilding the decoder.
     */
    val GLSL_FUNCTION =
        """
        // This helper is also injected ahead of the Qualcomm SGSR1 asset's
        // precision declarations. Keep the snippet self-contained so SGSR1
        // cannot fail compilation merely because the profile is enabled.
        precision mediump float;
        precision mediump int;

        uniform int uAndroidColorProfile;

        float androidSrgbTone(float value) {
            // USB chart calibration against the same 2800x1752 patch image
            // rendered natively by Samsung Gallery. The endpoints remain
            // exact; intermediate anchors undo the tablet decoder's measured
            // SDR S-curve without touching hue or saturation.
            const float p0 = 0.0;
            const float p1 = 55.0 / 255.0;
            const float p2 = 130.0 / 255.0;
            const float p3 = 204.0 / 255.0;
            const float p4 = 1.0;
            const float q0 = 0.0;
            const float q1 = 64.0 / 255.0;
            const float q2 = 128.0 / 255.0;
            const float q3 = 192.0 / 255.0;
            const float q4 = 1.0;

            if (value <= p1) return mix(q0, q1, (value - p0) / (p1 - p0));
            if (value <= p2) return mix(q1, q2, (value - p1) / (p2 - p1));
            if (value <= p3) return mix(q2, q3, (value - p2) / (p3 - p2));
            return mix(q3, q4, (value - p3) / (p4 - p3));
        }

        vec3 applyAndroidColorProfile(vec3 rgb) {
            if (uAndroidColorProfile == 0) return rgb;

            return clamp(
                vec3(
                    androidSrgbTone(rgb.r),
                    androidSrgbTone(rgb.g),
                    androidSrgbTone(rgb.b)
                ),
                0.0,
                1.0
            );
        }
        """.trimIndent()
}
