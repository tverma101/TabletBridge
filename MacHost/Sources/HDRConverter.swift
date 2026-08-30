import Accelerate
import CoreVideo
import Foundation

/// EXP-FORK: live 8-bit SDR capture -> 10-bit PQ/BT.2020 HDR-converted frames.
///
/// Why: the S8+ panel is 10-bit HDR10+; an 8-bit SDR stream caps gradients at
/// 256 levels and composites at 8-bit. Encoding 10-bit PQ-flagged BT.2020
/// (VUI via kVTCompressionPropertyKey_* in VideoEncoder, SideScreen_exp_hdr)
/// makes the tablet's HDR path engage, giving ~4x the luma levels on the
/// panel — the real fix for AMOLED gradient banding.
///
/// Conversion (v1, documented approximations):
///   Y: 8-bit full-range BT.709-gamma -> linear -> PQ -> 10-bit video range,
///      via a 256-entry UInt16 LUT (vImageLookupTable_Planar8toPlanar16).
///   Cb/Cr: 8-bit full-range -> 10-bit video range (x4), same LUT mechanism.
///   BT.709->BT.2020 matrix is approximated (small delta for SDR content).
///
/// Enabled by `SideScreen_exp_hdr=1` (must pair with VideoEncoder's HDR VUI
/// block and Main10 profile).
enum HDRConverter {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "SideScreen_exp_hdr") }

    private static var yLUT: [UInt16] = []
    private static var cLUT: [UInt16] = []
    private static var pool: [CVPixelBuffer] = []
    private static var poolIdx = 0

    /// BT.2020 PQ OETF: linear (0..1 = 0..10000 nits) -> PQ signal (0..1).
    static func pqSignal(_ lin: Double) -> Double {
        let m1 = 2610.0 / 16384.0, m2 = 2523.0 / 32.0
        let c1 = 3424.0 / 4096.0, c2 = 2413.0 / 128.0, c3 = 2392.0 / 128.0
        let y = pow(lin, m1)
        return pow((c1 + c2 * y) / (1.0 + c3 * y), m2)
    }

    static func ensureSetup(width: Int, height: Int) {
        guard yLUT.isEmpty else { return }
        // Y LUT: full-range 8-bit (BT.709 gamma approx) -> linear -> PQ -> 10-bit
        // video range 64..940, stored HIGH-bits (<<6) like the harness fill.
        var y = [UInt16](repeating: 0, count: 256)
        for i in 0..<256 {
            let e = Double(i) / 255.0
            let lin = pow(e, 2.4)  // SDR reference: 1.0 == 100 nits
            let sig = pqSignal(lin)
            let v10 = 64 + sig * 876
            y[i] = UInt16(min(1023, max(0, Int(v10.rounded()))) << 6)
        }
        yLUT = y
        // Chroma LUT: full-range 8-bit -> 10-bit video range (128 -> 512), high bits.
        var c = [UInt16](repeating: 0, count: 256)
        for i in 0..<256 {
            let v = 512.0 + (Double(i) - 128.0) * 4.0
            c[i] = UInt16(min(1023, max(0, Int(v.rounded()))) << 6)
        }
        cLUT = c
        // Pool of 10-bit buffers (4:2:0 video range) — IOSurface-backed like the
        // capture buffers so the HW encoder stays on its preferred path.
        guard pool.isEmpty else { return }
        let fmt = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        for _ in 0..<4 {
            var buf: CVPixelBuffer?
            let attrs: [CFString: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey: [:],
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
            ]
            let st = CVPixelBufferCreate(kCFAllocatorDefault, width, height, fmt, attrs as CFDictionary, &buf)
            if st == kCVReturnSuccess, let buf { pool.append(buf) }
        }
        debugLog("HDRConverter: \(pool.count) 10-bit buffers, LUTs ready")
    }

    /// Convert an 8-bit 420f capture buffer into a pooled 10-bit buffer.
    /// Returns nil when HDR is disabled or the pool is unavailable.
    static func convert(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        guard enabled, !pool.isEmpty else { return nil }
        let dst = pool[poolIdx % pool.count]
        poolIdx += 1
        let w = CVPixelBufferGetWidth(src)
        let h = CVPixelBufferGetHeight(src)
        CVPixelBufferLockBaseAddress(src, [])
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, [])
        }
        let srcY = CVPixelBufferGetBaseAddressOfPlane(src, 0)!
        let srcC = CVPixelBufferGetBaseAddressOfPlane(src, 1)!
        let dstY = CVPixelBufferGetBaseAddressOfPlane(dst, 0)!
        let dstC = CVPixelBufferGetBaseAddressOfPlane(dst, 1)!
        let sYRow = CVPixelBufferGetBytesPerRowOfPlane(src, 0)
        let sCRow = CVPixelBufferGetBytesPerRowOfPlane(src, 1)
        let dYRow = CVPixelBufferGetBytesPerRowOfPlane(dst, 0)
        let dCRow = CVPixelBufferGetBytesPerRowOfPlane(dst, 1)
        let cH = CVPixelBufferGetHeightOfPlane(src, 1)

        var srcYBuf = vImage_Buffer(data: srcY, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: sYRow)
        var dstYBuf = vImage_Buffer(data: dstY, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: dYRow)
        var srcCBuf = vImage_Buffer(data: srcC, height: vImagePixelCount(cH), width: vImagePixelCount(w / 2), rowBytes: sCRow)
        var dstCBuf = vImage_Buffer(data: dstC, height: vImagePixelCount(cH), width: vImagePixelCount(w / 2), rowBytes: dCRow)

        yLUT.withUnsafeBufferPointer { yt in
            vImageLookupTable_Planar8toPlanar16(&srcYBuf, &dstYBuf, yt.baseAddress!, vImage_Flags(kvImageNoFlags))
        }
        cLUT.withUnsafeBufferPointer { ct in
            vImageLookupTable_Planar8toPlanar16(&srcCBuf, &dstCBuf, ct.baseAddress!, vImage_Flags(kvImageNoFlags))
        }
        return dst
    }
}
