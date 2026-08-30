import CoreGraphics
import CoreText
import Foundation
import ImageIO
import AppKit

private struct LabError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct ImageRGBA {
    let width: Int
    let height: Int
    let pixels: [UInt8]
}

private struct CorpusEntry: Codable {
    let pattern: String
    let width: Int
    let height: Int
    let path: String
    let sha256: String
}

private struct CorpusManifest: Codable {
    let generatedBy: String
    let width: Int
    let height: Int
    let entries: [CorpusEntry]
}

private struct QualityMetrics: Codable {
    let reference: String
    let output: String
    let width: Int
    let height: Int
    let pixels: Int
    let rgbMAE: Double
    let rgbRMSE: Double
    let psnrDB: Double?
    let maxAbsoluteError: Int
    let absoluteErrorP50: Double
    let absoluteErrorP95: Double
    let absoluteErrorP99: Double
    let exactRGBPixelPercent: Double
    let lumaMAE: Double
    let chromaProxyMAE: Double
}

private let defaultSize = (width: 2800, height: 1752)

private func argument(_ name: String, in args: [String], default value: String? = nil) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return value }
    return args[index + 1]
}

private func requiredArgument(_ name: String, in args: [String]) throws -> String {
    guard let value = argument(name, in: args) else {
        throw LabError(message: "missing (name)")
    }
    return value
}

private func intArgument(_ name: String, in args: [String], default value: Int) -> Int {
    Int(argument(name, in: args) ?? "") ?? value
}

private func makeContext(width: Int, height: Int, pixels: inout [UInt8]) -> CGContext {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    return CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

private func drawPixelPattern(
    pattern: String,
    width: Int,
    height: Int,
    pixels: inout [UInt8]
) throws {
    let context = makeContext(width: width, height: height, pixels: &pixels)
    context.interpolationQuality = .none
    context.setAllowsAntialiasing(false)
    context.setFillColor(color(1, 1, 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    if pattern == "gradient" {
        for y in 0..<height {
            let t = CGFloat(y) / CGFloat(max(height - 1, 1))
            context.setFillColor(color(t, t, t))
            context.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        return
    }

    if pattern.hasPrefix("motion") {
        let frame = Int(pattern.split(separator: "-").last ?? "0") ?? 0
        context.setFillColor(color(0.035, 0.04, 0.05))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let grid = 64
        context.setStrokeColor(color(0.16, 0.18, 0.22))
        context.setLineWidth(1)
        for x in stride(from: 0, to: width, by: grid) {
            context.move(to: CGPoint(x: CGFloat(x) + 0.5, y: 0))
            context.addLine(to: CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(height)))
        }
        for y in stride(from: 0, to: height, by: grid) {
            context.move(to: CGPoint(x: 0, y: CGFloat(y) + 0.5))
            context.addLine(to: CGPoint(x: CGFloat(width), y: CGFloat(y) + 0.5))
        }
        context.strokePath()
        let x = (frame * 4) % max(width, 1)
        context.setFillColor(color(1, 0.13, 0.08))
        context.fill(CGRect(x: x, y: 0, width: 22, height: height))
        context.setFillColor(color(0.1, 0.55, 1))
        context.fill(CGRect(x: (x + width / 2) % width, y: height / 4, width: 18, height: height / 2))
        drawFrameMarker(context: context, frame: frame, width: width, height: height)
        return
    }

    if pattern == "chroma" {
        context.setFillColor(color(0.5, 0.5, 0.5))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let stripeY = height / 2
        for x in 0..<width {
            context.setFillColor(x.isMultiple(of: 2) ? color(1, 0, 0) : color(0, 0, 1))
            context.fill(CGRect(x: x, y: stripeY, width: 1, height: 2))
        }
        let patchColors: [CGColor] = [
            color(1, 0, 0), color(0, 1, 0), color(0, 0, 1), color(1, 1, 0),
            color(0, 1, 1), color(1, 0, 1), color(0.2, 0.2, 0.2), color(0.8, 0.8, 0.8),
        ]
        let patchW = width / 8
        let patchH = height / 4
        for index in patchColors.indices {
            context.setFillColor(patchColors[index])
            context.fill(CGRect(
                x: (index % 8) * patchW,
                y: height - patchH * (index / 8 + 1),
                width: patchW,
                height: patchH
            ))
        }
        drawOnePixelRules(context: context, width: width, height: height)
        return
    }

    guard pattern == "static-ui" else {
        throw LabError(message: "unknown pattern '(pattern)' (use static-ui, gradient, chroma, or motion-N)")
    }

    context.setFillColor(color(0.96, 0.965, 0.97))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(color(0.11, 0.13, 0.16))
    context.fill(CGRect(x: 0, y: height - 116, width: width, height: 116))
    context.setFillColor(color(0.2, 0.23, 0.28))
    context.fill(CGRect(x: 48, y: 48, width: width - 96, height: height - 210))
    context.setFillColor(color(0.98, 0.98, 0.99, 0.96))
    context.fill(CGRect(x: 96, y: 174, width: width - 192, height: height - 390))

    context.setFillColor(color(0.12, 0.45, 0.95))
    context.fill(CGRect(x: 120, y: height - 88, width: 360, height: 8))
    context.setFillColor(color(0.94, 0.2, 0.15))
    context.fill(CGRect(x: 520, y: height - 88, width: 240, height: 8))

    drawText(context: context, text: "SideScreen visual parity lab", at: CGPoint(x: 120, y: height - 72), size: 32, foreground: color(1, 1, 1))
    drawText(context: context, text: "San Francisco / thin UI / chroma edges / one-pixel geometry", at: CGPoint(x: 140, y: height - 240), size: 22, foreground: color(0.15, 0.17, 0.2))
    let sizes: [CGFloat] = [9, 10, 11, 12, 14, 18, 24]
    for (index, size) in sizes.enumerated() {
        let y = height - 330 - index * 56
        drawText(context: context, text: "(Int(size)) pt  The quick brown fox — 0123456789  {}<> !=", at: CGPoint(x: 140, y: y), size: size, foreground: color(0.04, 0.05, 0.06))
    }
    drawText(context: context, text: "RED", at: CGPoint(x: width / 2, y: height - 330), size: 24, foreground: color(0.9, 0.04, 0.04))
    drawText(context: context, text: "BLUE", at: CGPoint(x: width / 2, y: height - 390), size: 24, foreground: color(0.02, 0.15, 0.92))
    drawText(context: context, text: "let frame = renderer.present(source)", at: CGPoint(x: width / 2, y: height - 470), size: 18, foreground: color(0.45, 0.08, 0.7))

    drawOnePixelRules(context: context, width: width, height: height)
}

private func drawFrameMarker(context: CGContext, frame: Int, width: Int, height: Int) {
    context.setFillColor(color(1, 1, 1))
    context.fill(CGRect(x: 24, y: height - 74, width: 380, height: 52))
    drawText(context: context, text: String(format: "FRAME %06d", frame), at: CGPoint(x: 38, y: height - 60), size: 22, foreground: color(0, 0, 0))
}

private func drawOnePixelRules(context: CGContext, width: Int, height: Int) {
    context.setLineWidth(1)
    context.setStrokeColor(color(0, 0, 0))
    for offset in 0..<8 {
        let y = 80 + offset * 12
        context.move(to: CGPoint(x: 40, y: CGFloat(y) + 0.5))
        context.addLine(to: CGPoint(x: CGFloat(min(width - 40, 1160)), y: CGFloat(y) + 0.5))
    }
    for offset in 0..<6 {
        let x = 1340 + offset * 28
        context.move(to: CGPoint(x: CGFloat(x) + 0.5, y: 80))
        context.addLine(to: CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(min(height - 120, 900))))
    }
    context.strokePath()
}

private func drawText(context: CGContext, text: String, at point: CGPoint, size: CGFloat, foreground: CGColor) {
    let font = NSFont.systemFont(ofSize: size)
    let attributed = NSAttributedString(string: text, attributes: [
        .font: font,
        .foregroundColor: NSColor(cgColor: foreground) ?? NSColor.black,
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    context.saveGState()
    context.textPosition = point
    CTLineDraw(line, context)
    context.restoreGState()
}

private func savePNG(_ image: ImageRGBA, to url: URL) throws {
    var pixels = image.pixels
    let context = makeContext(width: image.width, height: image.height, pixels: &pixels)
    guard let cgImage = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw LabError(message: "could not create PNG destination (url.path)")
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw LabError(message: "could not finalize PNG (url.path)")
    }
}

private func loadPNG(_ url: URL) throws -> ImageRGBA {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw LabError(message: "could not read PNG (url.path)")
    }
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = makeContext(width: image.width, height: image.height, pixels: &pixels)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return ImageRGBA(width: image.width, height: image.height, pixels: pixels)
}

private func sha256(_ url: URL) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
    process.arguments = ["-a", "256", url.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    process.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return output.split(separator: " ").first.map(String.init) ?? "unknown"
}

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url)
}

private func analyze(reference: ImageRGBA, output: ImageRGBA, referencePath: String, outputPath: String) throws -> QualityMetrics {
    guard reference.width == output.width, reference.height == output.height else {
        throw LabError(message: "dimension mismatch reference=(reference.width)x(reference.height) output=(output.width)x(output.height)")
    }
    let pixelCount = reference.width * reference.height
    var absoluteHistogram = [Int](repeating: 0, count: 256)
    var sumAbs = 0.0
    var sumSquared = 0.0
    var lumaAbs = 0.0
    var chromaAbs = 0.0
    var exact = 0
    var maxError = 0
    for index in 0..<pixelCount {
        let offset = index * 4
        let rr = Int(reference.pixels[offset])
        let rg = Int(reference.pixels[offset + 1])
        let rb = Int(reference.pixels[offset + 2])
        let or = Int(output.pixels[offset])
        let og = Int(output.pixels[offset + 1])
        let ob = Int(output.pixels[offset + 2])
        let dr = abs(rr - or), dg = abs(rg - og), db = abs(rb - ob)
        let localMax = max(dr, dg, db)
        maxError = max(maxError, localMax)
        absoluteHistogram[dr] += 1
        absoluteHistogram[dg] += 1
        absoluteHistogram[db] += 1
        sumAbs += Double(dr + dg + db) / 3.0
        sumSquared += Double(dr * dr + dg * dg + db * db) / 3.0
        let refLuma = 0.2126 * Double(rr) + 0.7152 * Double(rg) + 0.0722 * Double(rb)
        let outLuma = 0.2126 * Double(or) + 0.7152 * Double(og) + 0.0722 * Double(ob)
        lumaAbs += abs(refLuma - outLuma)
        let refChroma = abs(Double(rr - rb))
        let outChroma = abs(Double(or - ob))
        chromaAbs += abs(refChroma - outChroma)
        if dr == 0 && dg == 0 && db == 0 { exact += 1 }
    }
    let channelSamples = pixelCount * 3
    let mae = sumAbs / Double(pixelCount)
    let mse = sumSquared / Double(pixelCount)
    let psnr = mse == 0 ? nil : 10.0 * log10((255.0 * 255.0) / mse)
    func histogramPercentile(_ fraction: Double) -> Double {
        let target = Int(ceil(fraction * Double(channelSamples)))
        var running = 0
        for (value, count) in absoluteHistogram.enumerated() {
            running += count
            if running >= target { return Double(value) }
        }
        return 255
    }
    return QualityMetrics(
        reference: referencePath,
        output: outputPath,
        width: reference.width,
        height: reference.height,
        pixels: pixelCount,
        rgbMAE: mae,
        rgbRMSE: sqrt(mse),
        psnrDB: psnr,
        maxAbsoluteError: maxError,
        absoluteErrorP50: histogramPercentile(0.50),
        absoluteErrorP95: histogramPercentile(0.95),
        absoluteErrorP99: histogramPercentile(0.99),
        exactRGBPixelPercent: Double(exact) * 100.0 / Double(pixelCount),
        lumaMAE: lumaAbs / Double(pixelCount),
        chromaProxyMAE: chromaAbs / Double(pixelCount)
    )
}

private func writeMarkdown(_ metrics: QualityMetrics, to url: URL) throws {
    let text = """
    # SideScreen visual-quality report

    Reference: `\(metrics.reference)`
    Output: `\(metrics.output)`
    Dimensions: `\(metrics.width)x\(metrics.height)`

    | Metric | Value |
    |---|---:|
    | RGB MAE | \(String(format: "%.4f", metrics.rgbMAE)) |
    | RGB RMSE | \(String(format: "%.4f", metrics.rgbRMSE)) |
    | RGB PSNR | \(metrics.psnrDB.map { String(format: "%.3f", $0) } ?? "infinite") dB |
    | Max absolute channel error | \(metrics.maxAbsoluteError) |
    | Absolute error p50 / p95 / p99 | \(metrics.absoluteErrorP50) / \(metrics.absoluteErrorP95) / \(metrics.absoluteErrorP99) |
    | Exact RGB pixel match | \(String(format: "%.3f", metrics.exactRGBPixelPercent))% |
    | Luma MAE | \(String(format: "%.4f", metrics.lumaMAE)) |
    | Chroma proxy MAE | \(String(format: "%.4f", metrics.chromaProxyMAE)) |

    This is a digital-path comparison. It does not measure OLED electro-optical behavior or panel photography.
    """
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func run(_ args: [String]) throws {
    guard let command = args.first else {
        throw LabError(message: "use generate, corpus, or analyze")
    }
    switch command {
    case "generate":
        let pattern = try requiredArgument("--pattern", in: args)
        let width = intArgument("--width", in: args, default: defaultSize.width)
        let height = intArgument("--height", in: args, default: defaultSize.height)
        let output = URL(fileURLWithPath: try requiredArgument("--output", in: args))
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        try drawPixelPattern(pattern: pattern, width: width, height: height, pixels: &pixels)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try savePNG(ImageRGBA(width: width, height: height, pixels: pixels), to: output)
        print("generated pattern=\(pattern) size=\(width)x\(height) path=\(output.path) sha256=\(sha256(output))")

    case "corpus":
        let directory = URL(fileURLWithPath: try requiredArgument("--output-dir", in: args), isDirectory: true)
        let width = intArgument("--width", in: args, default: defaultSize.width)
        let height = intArgument("--height", in: args, default: defaultSize.height)
        let patterns = argument("--patterns", in: args)?.split(separator: ",").map(String.init)
            ?? ["static-ui", "gradient", "chroma", "motion-0001", "motion-0030"]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var entries: [CorpusEntry] = []
        for pattern in patterns {
            let output = directory.appendingPathComponent("\(pattern).png")
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            try drawPixelPattern(pattern: pattern, width: width, height: height, pixels: &pixels)
            try savePNG(ImageRGBA(width: width, height: height, pixels: pixels), to: output)
            entries.append(CorpusEntry(pattern: pattern, width: width, height: height, path: output.path, sha256: sha256(output)))
        }
        try writeJSON(CorpusManifest(generatedBy: "tabletbridge-quality-lab", width: width, height: height, entries: entries), to: directory.appendingPathComponent("manifest.json"))
        print("generated corpus entries=\(entries.count) dir=\(directory.path)")

    case "analyze":
        let referenceURL = URL(fileURLWithPath: try requiredArgument("--reference", in: args))
        let outputURL = URL(fileURLWithPath: try requiredArgument("--output", in: args))
        let metrics = try analyze(reference: loadPNG(referenceURL), output: loadPNG(outputURL), referencePath: referenceURL.path, outputPath: outputURL.path)
        let jsonURL = URL(fileURLWithPath: argument("--json", in: args) ?? outputURL.deletingPathExtension().appendingPathExtension("metrics.json").path)
        let markdownURL = URL(fileURLWithPath: argument("--markdown", in: args) ?? outputURL.deletingPathExtension().appendingPathExtension("report.md").path)
        try writeJSON(metrics, to: jsonURL)
        try writeMarkdown(metrics, to: markdownURL)
        let psnrText = metrics.psnrDB.map { String(format: "%.3f", $0) } ?? "infinite"
        print("analyzed reference=\(referenceURL.path) output=\(outputURL.path) mae=\(String(format: "%.4f", metrics.rgbMAE)) psnr=\(psnrText)dB")

    default:
        throw LabError(message: "unknown command '\(command)'")
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    fputs("quality lab error: \(error.localizedDescription)\n", stderr)
    exit(2)
}
