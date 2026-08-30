import Foundation
import VideoToolbox
import CoreMedia
import os

class VideoEncoder {
    private struct EncoderState {
        var pendingForceKeyframe = false
        var nextFrameID: UInt64 = 0
    }

    private var compressionSession: VTCompressionSession?
    var onEncodedFrame: ((EncodedVideoFrame) -> Void)?
    private var width: Int
    private var height: Int
    let codec: StreamCodec
    private var bitrateMbps: Int = 20
    private var quality: String = "medium"
    private var gamingBoost: Bool = false
    private var frameRate: Int = 60
    private let maxBitrateMbps: Int?
    private let stateLock = OSAllocatedUnfairLock(initialState: EncoderState())
    init(width: Int, height: Int, codec: StreamCodec = .hevc, bitrateMbps: Int = 20, quality: String = "ultralow", gamingBoost: Bool = false, frameRate: Int = 60, maxBitrateMbps: Int? = nil) {
        self.width = width
        self.height = height
        self.codec = codec
        self.maxBitrateMbps = maxBitrateMbps
        // gamingBoost = the "ultralow" bitrate preset (6/9 Mbps bounded): the
        // bounded-frame-size profile that keeps encode time flat under motion
        // (the old gamingBoost overrides were no-ops once Quality took over
        // rate control — audit Entry S).
        self.bitrateMbps = bitrateMbps
        self.quality = gamingBoost ? "ultralow" : quality
        self.gamingBoost = gamingBoost
        self.frameRate = frameRate
        setupCompressionSession()
    }

    func updateSettings(bitrateMbps: Int, quality: String, gamingBoost: Bool) {
        self.bitrateMbps = bitrateMbps
        self.quality = gamingBoost ? "ultralow" : quality
        self.gamingBoost = gamingBoost

        // Drain pending frames before invalidation
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        setupCompressionSession()
    }

    private func setupCompressionSession() {
        var session: VTCompressionSession?

        let encoderSpecification: CFDictionary = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ] as CFDictionary

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: encodingOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            debugLog("Failed to create compression session: \(status)")
            return
        }

        compressionSession = session

        // Ultra-low latency config for real-time streaming
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        // VideoToolbox defaults H.264/HEVC hardware encoders toward quality.
        // This session is an interactive display path: prefer an earlier
        // encoded frame over marginal compression refinement.
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            value: kCFBooleanTrue
        )
        // H.264 Main profile: decodable by every AVC hardware decoder
        // (Baseline/Main/High all accept Main-constrained streams' feature
        // set we use). High adds 8x8 transform that some low-end vendor OMX
        // decoders reject — not worth the marginal gain for screen content.
        // EXP-FORK knobs (SideScreen_exp_*; absent = current production behavior):
        //   SideScreen_exp_profile  "main10" -> HEVC Main10 (10-bit) profile
        //   SideScreen_exp_bitrate  Int Mbps  -> override the preset bitrate target
        //   SideScreen_exp_gop      Int frames -> keyframe interval override
        //   SideScreen_exp_bframes  Bool       -> allow B-frames (default false)
        let expProfile = UserDefaults.standard.string(forKey: "SideScreen_exp_profile")
        // EXP-FORK: HDR mode forces Main10 (10-bit HEVC) — the tablet needs it
        // for the HDR path regardless of the profile knob.
        let hdrMode = UserDefaults.standard.bool(forKey: "SideScreen_exp_hdr")
        let profile: CFString = codec == .hevc
            ? (hdrMode || expProfile == "main10" ? kVTProfileLevel_HEVC_Main10_AutoLevel
                : (expProfile == "main42210" ? kVTProfileLevel_HEVC_Main42210_AutoLevel
                    : kVTProfileLevel_HEVC_Main_AutoLevel))
            : kVTProfileLevel_H264_Main_AutoLevel
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)

        // CUT (audit Entry S, 2026-08-16 follow-up): Quality-based rate control
        // is unbounded on this path — with kVTCompressionPropertyKey_Quality
        // set, VideoToolbox ignores AverageBitRate AND DataRateLimits
        // (receipts: byte-identical output at 10 vs 60 Mbps; 73.6 Mbps
        // measured against 30/45 limits). Motion bursts then overloaded the
        // transport/tablet decoder (the 34-39fps collapse + drop cascades).
        // Production now uses bitrate-based VBR: AverageBitRate as the soft
        // target, DataRateLimits as the 1-second hard cap at 1.5x. The
        // quality presets select the target; SideScreen_exp_bitrate (Mbps)
        // overrides the target directly; the UI bitrate acts as a floor.
        let presetMbps: Int
        switch quality {
        case "ultralow": presetMbps = 6
        case "low": presetMbps = 12
        case "medium": presetMbps = 20
        case "high": presetMbps = 30
        // EXP-FORK ultra ladder, now bitrate-bounded
        case "extrahigh": presetMbps = 40
        case "max": presetMbps = 50
        case "ultra": presetMbps = 60
        default: presetMbps = 20
        }
        let expBitrate = UserDefaults.standard.object(forKey: "SideScreen_exp_bitrate") as? Int
        // The UI bitrate (Mbps) can raise the preset target, but only within
        // the range the settings UI actually offers (100-2000 Mbps). Stored
        // values above that are legacy Kbps-scale junk (e.g. the paused
        // campaign's 8000) that must not turn the target into 8 Gbps.
        // gamingBoost pins the bounded ultralow profile — its 1000Mbps
        // effectiveBitrate is ignored (it predates bounded rate control).
        let uiFloor = (bitrateMbps >= 100 && bitrateMbps <= 2000) ? bitrateMbps : 0
        let requestedTargetMbps = expBitrate ?? (gamingBoost ? presetMbps : max(presetMbps, uiFloor))
        let targetMbps = max(1, min(requestedTargetMbps, maxBitrateMbps ?? Int.max))
        let avgBps = targetMbps * 1_000_000
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: avgBps as CFNumber)
        // Hard cap: bytes over a 1s window at 1.5x target — the guarantee
        // that keeps per-frame size (and thus decoder+transport load) bounded
        // during complex motion. This is the property pair VideoToolbox
        // documents for live streaming; it only works because Quality is
        // never set on this session.
        let capBytes = Int(Double(targetMbps) * 1.5 * 1_000_000.0 / 8.0)
        let dataRateLimits = [capBytes, 1] as CFArray
        let limitStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits)
        debugLog("Rate control: avg=\(targetMbps)Mbps cap=\(Int(Double(targetMbps) * 1.5))Mbps/1s" +
                 (maxBitrateMbps.map { " profileCap=\($0)Mbps" } ?? "") +
                 " (DataRateLimits status=\(limitStatus))")

        // Frame rate settings
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRate as CFNumber)

        // Keep a 1-second GOP as the fallback for encoders that do not honor
        // the low-latency encoder specification above. Low-latency rate
        // control may choose an effectively infinite P-frame GOP and owns the
        // final keyframe cadence; the deployed client still requests a fresh
        // keyframe when its 1.5-second stale-frame guard fires. The old
        // unbounded-IDR-burst concern is contained by the DataRateLimits hard
        // cap above. SideScreen_exp_gop overrides when supported.
        let expGop = UserDefaults.standard.object(forKey: "SideScreen_exp_gop") as? Int
        let gopFrames = expGop ?? frameRate
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: gopFrames as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: Double(gopFrames) / Double(frameRate) as CFNumber)

        // Critical for low latency - NO frame reordering (no B-frames)
        let expBFrames = UserDefaults.standard.object(forKey: "SideScreen_exp_bframes") as? Bool ?? false
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: (expBFrames ? kCFBooleanTrue : kCFBooleanFalse))

        // ALWAYS zero frame delay for real-time streaming (not just gaming boost)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)

        // Rate control note: kVTCompressionPropertyKey_Quality is deliberately
        // NEVER set here — it overrides bitrate-based control entirely (see
        // the rate-control block above for the receipts). Preset names map to
        // bitrate targets; gamingBoost pins quality="ultralow" in the
        // constructor, i.e. a fast 6/9 Mbps bounded profile.

        // EXP-FORK: HDR signaling (SideScreen_exp_hdr=1) — write HEVC VUI
        // colorimetry via SESSION properties (pixel-buffer attachments are
        // ignored by VT — verified 2026-08-15). Content must match: 10-bit
        // buffers, PQ-encoded, BT.2020. NOTE: HLG transfer breaks the HW
        // encoder (-12902 at encode); PQ is the working combination.
        if UserDefaults.standard.bool(forKey: "SideScreen_exp_hdr") {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries,
                                 value: kCMFormatDescriptionColorPrimaries_ITU_R_2020)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction,
                                 value: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix,
                                 value: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020)
            debugLog("HDR mode: BT.2020 primaries, PQ transfer, BT.2020 matrix (VUI)")
        }

        VTCompressionSessionPrepareToEncodeFrames(session)

        let mode = gamingBoost ? "🎮 GAMING BOOST" : quality.uppercased()
        let codecName = codec == .hevc ? "H.265" : "H.264"
        debugLog("VideoToolbox encoder configured (" + codecName + ", quality=" + mode + ", " + String(frameRate) + "fps)")
    }

    /// Force the next encoded frame to be an IDR (sync) frame.
    /// Used when a fresh client connects so its decoder can start immediately
    /// instead of waiting up to one full GOP for the next scheduled keyframe.
    func requestKeyframe() {
        stateLock.withLock { $0.pendingForceKeyframe = true }
    }

    func encode(
        pixelBuffer: CVPixelBuffer,
        presentationTimeStamp: CMTime,
        captureTimestampNs: UInt64? = nil,
        screenCaptureCallbackTimestampNs: UInt64? = nil
    ) {
        guard let session = compressionSession else { return }

        let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))

        // Use system uptime clock — MUST match DispatchTime.now().uptimeNanoseconds.
        // The capture timestamp is supplied by ScreenCaptureKit's callback;
        // encodeStart lets the runtime separate capture->encode admission from
        // VideoToolbox work.
        let encodeStartNs = DispatchTime.now().uptimeNanoseconds
        let captureNs = captureTimestampNs ?? encodeStartNs
        let callbackNs = screenCaptureCallbackTimestampNs ?? captureNs
        let frameID = stateLock.withLock { state -> UInt64 in
            state.nextFrameID &+= 1
            return state.nextFrameID
        }
        let context = FrameEncodeContext(
            frameID: frameID,
            captureTimestampNs: captureNs,
            screenCaptureCallbackTimestampNs: callbackNs,
            encodeStartTimestampNs: encodeStartNs
        )
        let refconValue = UnsafeMutablePointer<FrameEncodeContext>.allocate(capacity: 1)
        refconValue.initialize(to: context)

        let shouldForceKeyframe = stateLock.withLock { state -> Bool in
            guard state.pendingForceKeyframe else { return false }
            state.pendingForceKeyframe = false
            return true
        }
        let frameProperties: CFDictionary? = shouldForceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            frameProperties: frameProperties,
            sourceFrameRefcon: refconValue,
            infoFlagsOut: nil
        )
    }

    deinit {
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }
}

// Static start code to avoid repeated allocations
private let nalStartCode: [UInt8] = [0, 0, 0, 1]

private struct FrameEncodeContext {
    let frameID: UInt64
    let captureTimestampNs: UInt64
    let screenCaptureCallbackTimestampNs: UInt64
    let encodeStartTimestampNs: UInt64
}

private let encodingOutputCallback: VTCompressionOutputCallback = { (outputCallbackRefCon, sourceFrameRefCon, status, _, sampleBuffer) in
    guard let outputCallbackRefCon = outputCallbackRefCon else {
        return
    }

    let encoder = Unmanaged<VideoEncoder>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()

    // Always release the per-frame context, including failed VideoToolbox
    // callbacks. The old implementation leaked it on encode failure.
    let context: FrameEncodeContext
    if let refcon = sourceFrameRefCon {
        let pointer = refcon.assumingMemoryBound(to: FrameEncodeContext.self)
        context = pointer.pointee
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    } else {
        let now = DispatchTime.now().uptimeNanoseconds
        context = FrameEncodeContext(
            frameID: 0,
            captureTimestampNs: now,
            screenCaptureCallbackTimestampNs: now,
            encodeStartTimestampNs: now
        )
    }

    guard status == noErr, let sampleBuffer = sampleBuffer else { return }

    // Extract encoded data
    guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

    var lengthAtOffset: Int = 0
    var totalLength: Int = 0
    var dataPointer: UnsafeMutablePointer<Int8>?

    let statusCode = CMBlockBufferGetDataPointer(
        dataBuffer,
        atOffset: 0,
        lengthAtOffsetOut: &lengthAtOffset,
        totalLengthOut: &totalLength,
        dataPointerOut: &dataPointer
    )

    guard statusCode == kCMBlockBufferNoErr,
          let dataPointer = dataPointer else {
        return
    }

    // Check if this is a keyframe
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
    let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

    // Pre-allocate estimated size to reduce reallocations
    let estimatedSize = totalLength + (isKeyframe ? 256 : 0) + 32
    var frameData = Data(capacity: estimatedSize)

    if isKeyframe {
        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            // Prepend parameter sets: VPS/SPS/PPS for HEVC, SPS/PPS for H.264.
            var parameterSetCount: Int = 0
            let countStatus: OSStatus
            if encoder.codec == .hevc {
                countStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)
            } else {
                countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: nil)
            }
            if countStatus != noErr {
                debugLog("Parameter set count query failed: \(countStatus) — keyframe sent without SPS/PPS")
                parameterSetCount = 0
            }

            for i in 0..<parameterSetCount {
                var parameterSetPointer: UnsafePointer<UInt8>?
                var parameterSetSize: Int = 0
                if encoder.codec == .hevc {
                    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDescription, parameterSetIndex: i, parameterSetPointerOut: &parameterSetPointer, parameterSetSizeOut: &parameterSetSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                } else {
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: i, parameterSetPointerOut: &parameterSetPointer, parameterSetSizeOut: &parameterSetSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                }

                if let pointer = parameterSetPointer {
                    frameData.append(contentsOf: nalStartCode)
                    frameData.append(pointer, count: parameterSetSize)
                }
            }
        }
    }

    // Convert length-prefixed NAL units to Annex-B format (start codes)
    var offset = 0
    while offset < totalLength {
        // Read 4-byte length
        var nalLength: UInt32 = 0
        memcpy(&nalLength, dataPointer.advanced(by: offset), 4)
        nalLength = UInt32(bigEndian: nalLength)
        offset += 4

        // Add start code and NAL unit data
        frameData.append(contentsOf: nalStartCode)
        let nalPointer = UnsafeRawPointer(dataPointer.advanced(by: offset))
        frameData.append(nalPointer.assumingMemoryBound(to: UInt8.self), count: Int(nalLength))
        offset += Int(nalLength)
    }

    encoder.onEncodedFrame?(
        EncodedVideoFrame(
            frameID: context.frameID,
            captureTimestampNs: context.captureTimestampNs,
            screenCaptureCallbackTimestampNs: context.screenCaptureCallbackTimestampNs,
            encodeStartTimestampNs: context.encodeStartTimestampNs,
            encodeCompleteTimestampNs: DispatchTime.now().uptimeNanoseconds,
            data: frameData,
            isKeyframe: isKeyframe
        )
    )
}
