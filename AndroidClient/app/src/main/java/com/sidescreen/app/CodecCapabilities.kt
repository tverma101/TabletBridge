package com.sidescreen.app

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build

data class DecoderCapability(
    val name: String,
    val mime: String,
    val isHardware: Boolean,
    val isVendor: Boolean,
    val supportsSize: Boolean,
    val supportsRate: Boolean,
    val supportsLowLatency: Boolean,
    val profileLevels: String,
)

/**
 * One-shot decoder capability probe. AVC-only devices drive the H.264
 * wire-protocol negotiation (the Mac encodes H.264 instead of HEVC).
 *
 * "Has HEVC" means the device has a *usable hardware* HEVC decoder — not merely
 * any decoder that advertises the type. Two classes of device are deliberately
 * routed to H.264 instead:
 *
 *  - **Software-only HEVC** (e.g. Onyx Boox Nova Air C, whose vendor
 *    media_codecs.xml disables HW HEVC): the Google software decoder
 *    (c2.android.hevc / OMX.google.hevc) is far too slow for real-time mirroring.
 *
 *  - **Broken vendor HW HEVC**: Spreadtrum/Unisoc (OMX.sprd.hevc, c2.sprd.*)
 *    advertise a HW HEVC decoder that configures and starts successfully but
 *    never renders decoded frames to the output Surface — the SurfaceView stays
 *    empty and the user sees a black screen (e.g. Yuho Tab 10, SC9863A + PowerVR).
 *
 * Both classes have a working hardware H.264 decoder, so H.264 is the reliable
 * path for them.
 */
object CodecCapabilities {
    /** Decoder-name prefixes whose HEVC implementation is unusable for surface output. */
    private val BROKEN_HEVC_HW_PREFIXES = listOf("omx.sprd.", "c2.sprd.")

    /**
     * Usable *hardware* decoder for [mime]: not an encoder, not the (too slow
     * for real-time mirroring) Google software implementation, and for HEVC
     * not one of the vendor implementations that never render to a Surface.
     * Shared by [hasHevcDecoder] and [maxDecodeSize] so the classification
     * cannot drift between them. Same hardware/software split
     * VideoDecoder.findBestDecoder uses.
     */
    private fun isUsableHardwareDecoder(
        info: MediaCodecInfo,
        mime: String,
    ): Boolean {
        if (info.isEncoder) return false
        if (info.supportedTypes.none { it.equals(mime, ignoreCase = true) }) return false
        val name = info.name.lowercase()
        val isSoftware = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            info.isSoftwareOnly
        } else {
            name.startsWith("c2.android.") || name.startsWith("omx.google.")
        }
        val isBrokenHevc =
            mime.equals(MediaFormat.MIMETYPE_VIDEO_HEVC, ignoreCase = true) &&
                BROKEN_HEVC_HW_PREFIXES.any { name.startsWith(it) }
        return !isSoftware && !isBrokenHevc
    }

    /**
     * Full capability evidence used by decoder selection and diagnostics.
     * The list is intentionally public so the selected path can be persisted
     * in the runtime trace instead of disappearing behind MediaCodec fallback.
     */
    fun decoderCandidates(
        mime: String,
        width: Int,
        height: Int,
        targetRate: Double,
    ): List<DecoderCapability> = try {
        MediaCodecList(MediaCodecList.ALL_CODECS)
            .codecInfos
            .asSequence()
            .filter { !it.isEncoder && it.supportedTypes.any { type -> type.equals(mime, ignoreCase = true) } }
            .mapNotNull { info ->
                val caps = runCatching { info.getCapabilitiesForType(mime) }.getOrNull() ?: return@mapNotNull null
                val videoCaps = caps.videoCapabilities ?: return@mapNotNull null
                val supportsSize = runCatching { videoCaps.isSizeSupported(width, height) }.getOrDefault(false)
                val supportsRate = supportsSize && runCatching {
                    videoCaps.areSizeAndRateSupported(width, height, targetRate)
                }.getOrDefault(false)
                val isHardware = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    info.isHardwareAccelerated && !info.isSoftwareOnly
                } else {
                    !info.name.startsWith("c2.android.") && !info.name.startsWith("OMX.google.")
                }
                val isVendor = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && info.isVendor
                val lowLatency = Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                    runCatching {
                        caps.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency)
                    }.getOrDefault(false)
                val profiles = caps.profileLevels.joinToString(",") { level ->
                    "${level.profile}/${level.level}"
                }
                DecoderCapability(
                    name = info.name,
                    mime = mime,
                    isHardware = isHardware,
                    isVendor = isVendor,
                    supportsSize = supportsSize,
                    supportsRate = supportsRate,
                    supportsLowLatency = lowLatency,
                    profileLevels = profiles,
                )
            }
            .toList()
    } catch (_: Exception) {
        emptyList()
    }

    val hasHevcDecoder: Boolean by lazy {
        try {
            MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.any {
                isUsableHardwareDecoder(it, MediaFormat.MIMETYPE_VIDEO_HEVC)
            }
        } catch (_: Exception) {
            true // fail open: assume HEVC, preserving legacy behavior
        }
    }

    /** Mime the client will ask the Mac to stream: HEVC when usable, else AVC. */
    val streamMime: String
        get() = if (hasHevcDecoder) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC

    private val maxDecodeSizeCache = HashMap<String, Pair<Int, Int>?>()

    /**
     * Upper decode bounds (width × height) of the largest usable *hardware*
     * decoder for [mime] — the software fallback is too slow for real-time
     * mirroring to count as a ceiling. Null when nothing usable exists or the
     * probe fails (legacy behavior: no limit advertised to the Mac).
     * Cached per mime: enumerating MediaCodecList is not cheap and the answer
     * never changes at runtime (same reason hasHevcDecoder is lazy).
     */
    fun maxDecodeSize(mime: String): Pair<Int, Int>? =
        synchronized(maxDecodeSizeCache) {
            maxDecodeSizeCache.getOrPut(mime.lowercase()) { probeMaxDecodeSize(mime) }
        }

    private fun probeMaxDecodeSize(mime: String): Pair<Int, Int>? =
        try {
            MediaCodecList(MediaCodecList.ALL_CODECS)
                .codecInfos
                .asSequence()
                .filter { isUsableHardwareDecoder(it, mime) }
                .mapNotNull { info ->
                    val videoCaps =
                        try {
                            info.getCapabilitiesForType(mime).videoCapabilities
                        } catch (_: Exception) {
                            null
                        }
                    videoCaps?.let { it.supportedWidths.upper to it.supportedHeights.upper }
                }
                .maxByOrNull { (w, h) -> w.toLong() * h.toLong() }
        } catch (_: Exception) {
            null
        }
}
