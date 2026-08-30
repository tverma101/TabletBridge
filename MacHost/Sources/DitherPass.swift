import Foundation
import CoreVideo

/// DitherPass — slope-adaptive blue-noise (Bayer 8x8) dithering for the
/// 8-bit Y plane of the 4:2:0 capture buffer. EXPERIMENT-FORK ONLY.
///
/// Goal: break the step structure the tablet's video path re-quantizes into
/// visible banding (R1: 256 source levels collapse to ~98 with 2.8-step
/// jumps). Adding sub-visible blue noise before encode decorrelates the
/// tablet's per-pixel rounding: hard steps become mixed-level noise the eye
/// integrates as smooth.
///
/// Amplitude gating (the "engineered, not vibecoded" part):
///   A(x,y) = min(ampMax, localRange * k)   — localRange over an 8px window
///   - flat areas (range 0)  -> NO noise (grain-free surfaces)
///   - ramps (range ~0.7/8px)-> up to ampMax LSB
///   - edges (range large)   -> capped at ampMax (invisible on high contrast)
/// Static pattern -> no temporal shimmer. Offline-validated by the D-series
/// harness experiments (plateau collapse 17.8->2.8/1.5 post-Q98).
///
/// Knobs: SideScreen_exp_dither = 1|2 (ampMax in 8-bit LSB units; 0 = off)
///        SideScreen_exp_ditherK = 5.5 (default)
enum DitherPass {
    static let bayer: [Int] = [
        0, 48, 12, 60, 3, 51, 15, 63,
        32, 16, 44, 28, 35, 19, 47, 31,
        8, 56, 4, 52, 11, 59, 7, 55,
        40, 24, 36, 20, 43, 27, 39, 23,
        2, 50, 14, 62, 1, 49, 13, 61,
        34, 18, 46, 30, 33, 17, 45, 29,
        10, 58, 6, 54, 9, 57, 5, 53,
        42, 26, 38, 22, 41, 25, 37, 21,
    ]

    static var enabled: Bool {
        UserDefaults.standard.integer(forKey: "SideScreen_exp_dither") > 0
    }

    static var ampMax: Int {
        max(1, UserDefaults.standard.integer(forKey: "SideScreen_exp_dither"))
    }

    /// 8px-window range -> amplitude scale (fixed point, 1/16 LSB units).
    /// k = 5.5 maps a 256-step ramp's 8px range (~0.73) to ampMax.
    static var kQ16: Int {
        let k = UserDefaults.standard.double(forKey: "SideScreen_exp_ditherK")
        return Int((k > 0 ? k : 5.5) * 16)
    }

    /// Per-frame CPU budget (µs). Photo/video frames are the worst case for
    /// the per-pixel pass but banding is invisible there (noise-masked), so
    /// partial coverage is free perceptually. The stop point is row-
    /// deterministic -> consistent per frame -> no temporal shimmer.
    static var budgetUs: Int {
        let b = UserDefaults.standard.integer(forKey: "SideScreen_exp_ditherBudget")
        return b > 0 ? b : 4000
    }

    /// In-place dither of the Y plane. Returns false when the buffer format
    /// is not an 8-bit 4:2:0 biplanar (format guard, like PatternInjector).
    @discardableResult
    static func apply(_ buf: CVPixelBuffer) -> Bool {
        let fmt = CVPixelBufferGetPixelFormatType(buf)
        guard fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else {
            return false
        }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let yb = CVPixelBufferGetBaseAddressOfPlane(buf, 0) else { return false }
        let w = CVPixelBufferGetWidth(buf)
        let h = CVPixelBufferGetHeight(buf)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
        let p = yb.assumingMemoryBound(to: UInt8.self)
        let ampMaxQ = ampMax * 16
        let kQ = kQ16
        let b = bayer
        let budgetNs = Int64(budgetUs) * 1000
        let t0 = Int64(DispatchTime.now().uptimeNanoseconds)

        for y in 0..<h {
            if y & 31 == 0 && DispatchTime.now().uptimeNanoseconds - UInt64(t0) > UInt64(budgetNs) {
                break  // time-boxed: photo frames degrade gracefully, no drops
            }
            let row = y * rowBytes
            let y8 = max(0, y - 8) * rowBytes
            let byRow = (y & 7) * 8
            // Row pre-check: sample both axes at 8 columns. All-zero => flat
            // row (the common UI case) -> skip in ~µs. A miss only means the
            // row pays the full per-pixel pass (never an artifact).
            var rowFlat = true
            for s in 0..<8 {
                let sx = (s * 2 + 1) * w / 16
                if Int(p[row + sx]) - Int(p[row + max(0, sx - 8)]) != 0
                    || Int(p[row + sx]) - Int(p[y8 + sx]) != 0 {
                    rowFlat = false
                    break
                }
            }
            if rowFlat { continue }
            var x = 0
            while x < w {
                let v = Int(p[row + x])
                let vx = Int(p[row + max(0, x - 8)])
                let vy = Int(p[y8 + x])
                var range = abs(v - vx)
                let d = abs(v - vy)
                if d > range { range = d }
                // Flat fast path — most pixels of a structured row are flat.
                if range == 0 { x += 1; continue }
                var ampQ = range * kQ
                if ampQ > ampMaxQ { ampQ = ampMaxQ }
                // noise = amp * (bayer/31.5 - 1)  in 1/16-LSB fixed point:
                //   nQ = ampQ * (b*2 - 63);  noise_LSB = nQ / (16 * 63)
                //   exact divisor 1008; approximated by *65>>16 (0.02% error)
                let nQ = ampQ * (b[byRow + (x & 7)] * 2 - 63)
                var nv = v + ((nQ * 65 + 32768) >> 16)  // round-to-nearest
                if nv < 0 { nv = 0 } else if nv > 255 { nv = 255 }
                p[row + x] = UInt8(nv)
                x += 1
            }
        }
        return true
    }
}
