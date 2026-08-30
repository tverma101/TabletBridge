import CoreVideo
import Foundation

/// In-sender test-pattern injection (fork experiment harness) — RIG VALIDATION
/// ONLY. The offline harness (probes/offline_enc/) is the primary measurement
/// path; this exists so the one rig validation run shows known pixels.
///
/// Enabled by `SideScreen_exp_pattern` = "gradient" | "lowramp" | "stepped" |
/// "text" | "color". ONE static pattern per sender run (NOT a wall-clock
/// cycle): SCStream freezes when the display is idle and the keepalive
/// re-encodes the last frame, so the tablet shows a stable pattern the whole
/// run. Pattern math MUST stay in lockstep with harness fillY8/renderPatternSource
/// in probes/offline_enc/main.swift (they produce the reference source PNGs).
///
/// Supports 8-bit full/video-range biplanar input and the 10-bit video-range
/// biplanar format used by the USB Main10 experiment. The 10-bit path
/// currently supports the static color chart, which is enough to calibrate
/// the receiver against the native Android screenshot baseline.
enum PatternInjector {
    private static let motionFPSKey = "SideScreen_lab_motion_fps"

    static func isActive() -> Bool {
        UserDefaults.standard.string(forKey: "SideScreen_exp_pattern") != nil
    }

    /// Opt-in source motion for the #27 cadence lab. The timer that requests
    /// these frames lives in ScreenCapture; keeping the pixel generator here
    /// makes the source deterministic and shared with the static corpus math.
    static var motionLabFPS: Int {
        let requested = UserDefaults.standard.integer(forKey: motionFPSKey)
        return min(max(requested, 0), 120)
    }

    static var isMotionLabActive: Bool { motionLabFPS > 0 }

    static func makeMotionBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let configuredFormat = AdaptiveRefreshController.configuredPixelFormat()
        let motionFormat = configuredFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            : configuredFormat
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            motionFormat,
            attributes as CFDictionary,
            &buffer
        )
        return status == kCVReturnSuccess ? buffer : nil
    }

    static func fill(_ buffer: CVPixelBuffer) {
        let kind = UserDefaults.standard.string(forKey: "SideScreen_exp_pattern") ?? ""
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
        let fmt = CVPixelBufferGetPixelFormatType(buffer)
        if fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange {
            if kind == "color" {
                fill10BitColorPattern(buffer)
            } else {
                debugLog("PatternInjector: 10-bit path only supports the color chart")
            }
            return
        }
        let fullRange: Bool
        switch fmt {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            fullRange = true
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            fullRange = false
        default:
            debugLog("PatternInjector: format 0x\(String(fmt, radix: 16)) unsupported — skipping")
            return
        }

        // "file" mode: load a PNG (SideScreen_exp_patternFile) and blit it 1:1.
        // Used for the native-vs-stream chart A/B (2026-08-15).
        if kind == "file" {
            let path = UserDefaults.standard.string(forKey: "SideScreen_exp_patternFile") ?? ""
            guard !path.isEmpty, let rgb = loadPNG(path) else {
                debugLog("PatternInjector: file mode but no loadable PNG at '\(path)'")
                return
            }
            fillFromRGB(rgb, into: buffer, fullRange: fullRange)
            debugLog("PatternInjector: injected file \(path) (\(rgb.width)x\(rgb.height))")
            return
        }
        fillPattern(kind, buffer: buffer, base: base, fullRange: fullRange)
    }

    /// Fill one deterministic motion frame into the configured 8-bit 4:2:0
    /// buffer used by the direct lab profile. The visible frame counter is a
    /// source marker; the transport trace's encoder frame ID remains the
    /// authoritative admission/drop sequence.
    static func fillMotionLab(_ buffer: CVPixelBuffer, frameID: UInt64) {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let fullRange: Bool
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            fullRange = true
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            fullRange = false
        default:
            debugLog("PatternInjector: motion lab requires 8-bit 420, got 0x\(String(format, radix: 16))")
            return
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let cRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let cHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let redX = Int((frameID &* 4) % UInt64(max(width, 1)))
        let blueX = Int((frameID &* 7 &+ UInt64(width / 2)) % UInt64(max(width, 1)))
        for y in 0..<height {
            let row = yBase + y * yRow
            for x in 0..<width {
                let inRed = x >= redX && x < redX + 24
                let inBlue = x >= blueX && x < blueX + 18
                let grid = x % 64 == 0 || y % 64 == 0
                let value: UInt8 = inRed || inBlue ? 235 : (grid ? 104 : 24)
                row.advanced(by: x).storeBytes(
                    of: encodeLuma(value, fullRange: fullRange),
                    as: UInt8.self
                )
            }
        }

        // Neutral chroma except for the two moving bars. Chroma is sampled at
        // 2x2, so the marker deliberately crosses several chroma cells.
        for y in 0..<cHeight {
            let row = cBase + y * cRow
            for x in 0..<(width / 2) {
                let lumaX = x * 2
                let inRed = lumaX >= redX && lumaX < redX + 24
                let inBlue = lumaX >= blueX && lumaX < blueX + 18
                let offset = x * 2
                let cb: UInt8 = inRed ? 90 : (inBlue ? 240 : 128)
                let cr: UInt8 = inRed ? 240 : (inBlue ? 110 : 128)
                row.advanced(by: offset).storeBytes(
                    of: encodeChroma(Double(cb), fullRange: fullRange),
                    as: UInt8.self
                )
                row.advanced(by: offset + 1).storeBytes(
                    of: encodeChroma(Double(cr), fullRange: fullRange),
                    as: UInt8.self
                )
            }
        }
        drawFrameMarker(
            yBase: yBase,
            rowBytes: yRow,
            width: width,
            height: height,
            frameID: frameID,
            fullRange: fullRange
        )
    }

    private static func drawFrameMarker(
        yBase: UnsafeMutableRawPointer,
        rowBytes: Int,
        width: Int,
        height: Int,
        frameID: UInt64,
        fullRange: Bool = true
    ) {
        let boxWidth = min(width, 420)
        let boxHeight = min(height, 56)
        for y in 0..<boxHeight {
            memset(yBase + y * rowBytes, Int32(encodeLuma(UInt8(235), fullRange: fullRange)), boxWidth)
        }
        let digits = String(frameID % 1_000_000).compactMap { $0.wholeNumberValue }
        let scale = 3
        var cursorX = 16
        for digit in digits {
            let pattern = digitPatterns[digit]
            for row in 0..<7 {
                for col in 0..<5 where ((pattern[row] >> (4 - col)) & 1) == 1 {
                    for dy in 0..<scale {
                        for dx in 0..<scale {
                            let px = cursorX + col * scale + dx
                            let py = 8 + row * scale + dy
                            guard px < width, py < height else { continue }
                            yBase
                                .advanced(by: py * rowBytes + px)
                                .storeBytes(
                                    of: encodeLuma(UInt8(16), fullRange: fullRange),
                                    as: UInt8.self
                                )
                        }
                    }
                }
            }
            cursorX += 6 * scale
            if cursorX >= boxWidth - 20 { break }
        }
    }

    private static let digitPatterns: [[UInt8]] = [
        [0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110],
        [0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],
        [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111],
        [0b01110, 0b10001, 0b00001, 0b00110, 0b00001, 0b10001, 0b01110],
        [0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010],
        [0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110],
        [0b01110, 0b10000, 0b11110, 0b10001, 0b10001, 0b10001, 0b01110],
        [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000],
        [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110],
        [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b01110],
    ]

    struct RGBImage { let width: Int; let height: Int; let pixels: [UInt8] } // RGBA

    static func loadPNG(_ path: String) -> RGBImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = img.width, h = img.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return RGBImage(width: w, height: h, pixels: pixels)
    }

    /// Blit an RGBA image into an 8-bit 420 buffer (Y + interleaved CbCr), 1:1
    /// at the buffer's top-left; un-covered area stays as-is. Encode either
    /// full-range or video-range samples to match the destination buffer.
    static func fillFromRGB(
        _ rgb: RGBImage,
        into buffer: CVPixelBuffer,
        fullRange: Bool = true
    ) {
        let bw = CVPixelBufferGetWidth(buffer)
        let bh = CVPixelBufferGetHeight(buffer)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let cbCr = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }
        let cRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let cw = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let w = min(rgb.width, bw), h = min(rgb.height, bh)
        for y in 0..<h {
            let yp = yBase + y * yRow
            let cp = cbCr + (y / 2) * cRow
            for x in 0..<w {
                let o = (y * rgb.width + x) * 4
                let r = rgb.pixels[o], g = rgb.pixels[o + 1], b = rgb.pixels[o + 2]
                let (yv, cb, cr) = ycbcr(r, g, b, fullRange: fullRange)
                yp.advanced(by: x).storeBytes(of: yv, as: UInt8.self)
                let cx = x / 2
                cp.advanced(by: cx * 2).storeBytes(of: cb, as: UInt8.self)
                cp.advanced(by: cx * 2 + 1).storeBytes(of: cr, as: UInt8.self)
            }
        }
    }

    static func fillPattern(
        _ kind: String,
        buffer: CVPixelBuffer,
        base: UnsafeMutableRawPointer,
        fullRange: Bool = true
    ) {
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        guard let cbCr = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }
        let cRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let cH = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let cw = CVPixelBufferGetWidthOfPlane(buffer, 1)

        // ---- Y plane (identical math to harness fillY8) ----
        switch kind {
        case "gradient":
            for y in 0..<h {
                let v = UInt8(min(255, y * 255 / max(h - 1, 1)))
                memset(base + y * yRow, Int32(encodeLuma(v, fullRange: fullRange)), w)
            }
        case "lowramp":
            for y in 0..<h {
                let v = UInt8(min(64, y * 64 / max(h - 1, 1)))
                memset(base + y * yRow, Int32(encodeLuma(v, fullRange: fullRange)), w)
            }
        case "stepped":
            let patches = 17, ph = h / patches
            for i in 0..<patches {
                let v = encodeLuma(UInt8(i * 8), fullRange: fullRange)
                for y in (i * ph)..<min((i + 1) * ph, h) {
                    memset(base + y * yRow, Int32(v), w)
                }
            }
        case "text":
            for y in 0..<h {
                let row = base + y * yRow
                let band = (y / 90) % 4
                for x in 0..<w {
                    let xb = x % 48
                    var v: UInt8 = 255
                    switch band {
                    case 0: if xb < 1 { v = 0 }
                    case 1: if xb < 2 { v = 0 }
                    case 2: if xb < 4 { v = 0 }
                    default: if xb < 8 { v = 0 }
                    }
                    if x % 7 == 0 && y % 7 == 0 { v = 0 }
                    row.advanced(by: x).storeBytes(
                        of: encodeLuma(v, fullRange: fullRange),
                        as: UInt8.self
                    )
                }
            }
        case "color":
            let cols = 6, rows = 4
            let pw = w / cols, ph = h / rows
            for i in 0..<colorPatches.count {
                let (y, _, _) = ycbcr(
                    colorPatches[i].0,
                    colorPatches[i].1,
                    colorPatches[i].2,
                    fullRange: fullRange
                )
                let cx = i % cols, cy = i / cols
                for yy in (cy * ph)..<min((cy + 1) * ph, h) {
                    memset(base + yy * yRow + cx * pw, Int32(y), pw)
                }
            }
        default:
            debugLog("PatternInjector: unknown pattern '\(kind)' — no-op")
            return
        }

        // ---- CbCr plane (interleaved, 4:2:0: 1 pair per 2x2 luma) ----
        if kind == "color" {
            let cols = 6, rows = 4
            let ph = h / rows
            let cpw = cw / cols, cph = cH / rows
            for i in 0..<colorPatches.count {
                let (_, cb, cr) = ycbcr(
                    colorPatches[i].0,
                    colorPatches[i].1,
                    colorPatches[i].2,
                    fullRange: fullRange
                )
                let cx = i % cols, cy = i / cols
                for yy in (cy * cph)..<min((cy + 1) * cph, cH) {
                    let row = cbCr + yy * cRow
                    for xx in 0..<cpw {
                        let off = (cx * cpw + xx) * 2
                        row.advanced(by: off).storeBytes(of: cb, as: UInt8.self)
                        row.advanced(by: off + 1).storeBytes(of: cr, as: UInt8.self)
                    }
                }
            }
        } else {
            memset(cbCr, 128, cRow * cH)
        }
        debugLog("PatternInjector: injected '\(kind)' \(w)x\(h)")
    }

    /// Fill the same chart into a 10-bit video-range buffer (P010-style,
    /// high 10 bits in each UInt16 sample). The Y/Cb/Cr equations are BT.709
    /// limited-range equivalents of ycbcr(_:_:_:), so the encoded chart has
    /// the same intended sRGB patch values as the 8-bit harness.
    static func fill10BitColorPattern(_ buffer: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let cRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let cH = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let cw = CVPixelBufferGetWidthOfPlane(buffer, 1)
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let cbCr = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }

        let cols = 6, rows = 4
        let pw = w / cols, ph = h / rows
        let cpw = cw / cols, cph = cH / rows
        for i in 0..<colorPatches.count {
            let (y, cb, cr) = ycbcr10(colorPatches[i].0, colorPatches[i].1, colorPatches[i].2)
            let cx = i % cols, cy = i / cols
            for yy in (cy * ph)..<min((cy + 1) * ph, h) {
                let row = yBase + yy * yRow
                for xx in (cx * pw)..<min((cx + 1) * pw, w) {
                    row.advanced(by: xx * 2).storeBytes(of: y, as: UInt16.self)
                }
            }
            for yy in (cy * cph)..<min((cy + 1) * cph, cH) {
                let row = cbCr + yy * cRow
                for xx in 0..<cpw {
                    let off = (cx * cpw + xx) * 4
                    row.advanced(by: off).storeBytes(of: cb, as: UInt16.self)
                    row.advanced(by: off + 2).storeBytes(of: cr, as: UInt16.self)
                }
            }
        }
        debugLog("PatternInjector: injected 10-bit 'color' \(w)x\(h)")
    }

    static let colorPatches: [(UInt8, UInt8, UInt8)] = [
        (255,255,255),(0,0,0),(255,0,0),(0,255,0),(0,0,255),(255,255,0),
        (0,255,255),(255,0,255),(245,222,179),(255,140,105),(135,206,250),(255,215,0),
        (64,64,64),(128,128,128),(192,192,192),(255,99,71),(60,179,113),(70,130,180),
        (255,182,193),(255,228,196),(176,224,230),(238,130,238),(255,160,122),(128,0,128),
    ]

    /// sRGB -> BT.709 YCbCr. Full-range values match the harness; video-range
    /// values map luma to 16..235 and chroma to 16..240.
    static func ycbcr(
        _ r: UInt8,
        _ g: UInt8,
        _ b: UInt8,
        fullRange: Bool = true
    ) -> (UInt8, UInt8, UInt8) {
        let rf = Double(r), gf = Double(g), bf = Double(b)
        let y = 0.2126 * rf + 0.7152 * gf + 0.0722 * bf
        let cb = -0.1146 * rf - 0.3854 * gf + 0.5 * bf + 128.0
        let cr = 0.5 * rf - 0.4542 * gf - 0.0458 * bf + 128.0
        if fullRange {
            return (
                UInt8(min(max(y, 0), 255)),
                UInt8(min(max(cb, 0), 255)),
                UInt8(min(max(cr, 0), 255))
            )
        }
        return (
            encodeLuma(y, fullRange: false),
            encodeChroma(cb, fullRange: false),
            encodeChroma(cr, fullRange: false)
        )
    }

    private static func encodeLuma(_ value: UInt8, fullRange: Bool) -> UInt8 {
        encodeLuma(Double(value), fullRange: fullRange)
    }

    private static func encodeLuma(_ value: Double, fullRange: Bool) -> UInt8 {
        let encoded = fullRange ? value : 16.0 + value * 219.0 / 255.0
        return UInt8(min(max(encoded.rounded(), 0), 255))
    }

    private static func encodeChroma(_ value: Double, fullRange: Bool) -> UInt8 {
        let encoded = fullRange ? value : 16.0 + value * 224.0 / 255.0
        return UInt8(min(max(encoded.rounded(), 0), 255))
    }

    /// sRGB -> BT.709 limited-range 10-bit YCbCr, high-bit aligned for P010.
    static func ycbcr10(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (UInt16, UInt16, UInt16) {
        let rf = Double(r) / 255.0, gf = Double(g) / 255.0, bf = Double(b) / 255.0
        let y = 64.0 + (0.2126 * rf + 0.7152 * gf + 0.0722 * bf) * 876.0
        let cb = 512.0 + (-0.1146 * rf - 0.3854 * gf + 0.5 * bf) * 896.0
        let cr = 512.0 + (0.5 * rf - 0.4542 * gf - 0.0458 * bf) * 896.0
        func pack(_ value: Double) -> UInt16 {
            UInt16(min(max(Int(value.rounded()), 0), 1023) << 6)
        }
        return (pack(y), pack(cb), pack(cr))
    }
}
