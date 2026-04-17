import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Vision

// MARK: - Result

struct OrientationClassificationResult {
    /// Degrees to rotate clockwise to make the image upright (0, 90, 180, or 270).
    let rotationDegrees: Int
    /// Detection confidence 0–1.
    let confidence: Float
    /// Which strategy produced the result: "ml_model", "face_detection", "luminance", or "default".
    let method: String
}

// MARK: - Service

/// Classifies the correct upright orientation for a photo proxy.
///
/// Strategy (in priority order):
/// 1. **ML model** — OrientationDetector_i8 (EfficientNetV2-S, 98.82% validation accuracy).
///    Resizes to 384×384, applies ImageNet normalisation, runs CoreML inference.
///    Classes: 0 = 0°, 1 = 90°CW, 2 = 180°, 3 = 270°CW correction to apply.
/// 2. **Face detection** — runs VNDetectFaceRectanglesRequest at all 4 orientations;
///    the orientation with the highest cumulative confidence wins.
/// 3. **Luminance gravity** — sky/backgrounds are typically brightest at the top of a
///    correctly-oriented image; picks the rotation that puts the brightest quadrant on top.
/// 4. **Default** — returns 0° (no change) if no strategy produces a confident result.
actor OrientationClassificationService {

    // MARK: - Constants

    private static let inputSize = 384
    // ImageNet normalisation: (pixel/255 − mean) / std, per channel
    private static let mean: [Float] = [0.485, 0.456, 0.406]
    private static let std:  [Float] = [0.229, 0.224, 0.225]

    // MARK: - Model (loaded once at init via Xcode-generated class)

    private let mlModel: OrientationDetector_i8?

    nonisolated init() {
        let config = MLModelConfiguration()
        config.computeUnits = .all   // Neural Engine + GPU + CPU; ANE is fastest for i8 models
        mlModel = try? OrientationDetector_i8(configuration: config)
        if mlModel == nil {
            print("[OrientationClassificationService] ⚠️ OrientationDetector_i8 failed to load — falling back to Vision heuristics.")
        }
    }

    // MARK: - Public API

    func classify(proxyURL: URL) async -> OrientationClassificationResult {
        if let result = await classifyViaML(url: proxyURL) {
            return result
        }
        if let result = await classifyViaFaces(url: proxyURL) {
            return result
        }
        return classifyViaLuminance(url: proxyURL)
            ?? OrientationClassificationResult(rotationDegrees: 0, confidence: 0.1, method: "default")
    }

    /// In-memory variant — skips the disk read that `classify(proxyURL:)` requires.
    /// ML runs directly on the already-decoded CGImage; face/luminance fallbacks use the
    /// same image rendered to a temporary bitmap rather than re-opening a file.
    func classify(cgImage: CGImage) async -> OrientationClassificationResult {
        if let result = await classifyViaML(cgImage: cgImage) {
            return result
        }
        if let result = await classifyViaFaces(cgImage: cgImage) {
            return result
        }
        return classifyViaLuminance(cgImage: cgImage)
            ?? OrientationClassificationResult(rotationDegrees: 0, confidence: 0.1, method: "default")
    }

    // MARK: - Strategy 1: Core ML model

    private func classifyViaML(cgImage: CGImage) async -> OrientationClassificationResult? {
        guard let model = mlModel else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let pixels = Self.rgbaPixels(from: cgImage, size: Self.inputSize) else { return nil }
            return Self.runInference(model: model, pixels: pixels)
        }.value
    }

    private func classifyViaML(url: URL) async -> OrientationClassificationResult? {
        guard let model = mlModel else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg  = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  let pixels = Self.rgbaPixels(from: cg, size: Self.inputSize)
            else { return nil }
            return Self.runInference(model: model, pixels: pixels)
        }.value
    }

    /// Draws `cg` into a `size × size` RGBA bitmap and returns the raw bytes.
    private static func rgbaPixels(from cg: CGImage, size: Int) -> [UInt8]? {
        guard let cs  = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: size, height: size,
                  bitsPerComponent: 8, bytesPerRow: size * 4,
                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = ctx.data else { return nil }
        return Array(UnsafeBufferPointer(
            start: data.bindMemory(to: UInt8.self, capacity: size * size * 4),
            count: size * size * 4
        ))
    }

    /// Shared inference path: normalise pixels → MLMultiArray → model → argmax.
    private static func runInference(
        model: OrientationDetector_i8, pixels: [UInt8]
    ) -> OrientationClassificationResult? {
        let size = inputSize
        guard let array = try? MLMultiArray(
            shape: [1, 3, size as NSNumber, size as NSNumber], dataType: .float32
        ) else { return nil }

        let ptr = UnsafeMutablePointer<Float>(OpaquePointer(array.dataPointer))
        let planeSize = size * size
        for row in 0..<size {
            for col in 0..<size {
                let pixelBase = (row * size + col) * 4
                for c in 0..<3 {
                    let raw  = Float(pixels[pixelBase + c]) / 255.0
                    let norm = (raw - mean[c]) / std[c]
                    ptr[c * planeSize + row * size + col] = norm
                }
            }
        }

        guard let input = try? OrientationDetector_i8Input(input: array),
              let out   = try? model.prediction(input: input) else { return nil }

        let classScores = (0..<4).map { out.output[$0].floatValue }
        guard let topScore = classScores.max(),
              let classIdx = classScores.firstIndex(of: topScore) else { return nil }

        return OrientationClassificationResult(
            rotationDegrees: classIdx * 90, confidence: topScore, method: "ml_model"
        )
    }

    // MARK: - Strategy 2: Face detection

    private func classifyViaFaces(cgImage: CGImage) async -> OrientationClassificationResult? {
        let candidates: [(CGImagePropertyOrientation, Int)] = [
            (.up, 0), (.right, 90), (.down, 180), (.left, 270)
        ]
        var bestDegrees = 0
        var bestConfidence: Float = -1
        for (orientation, degrees) in candidates {
            let conf = await Task.detached(priority: .userInitiated) {
                let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
                let request = VNDetectFaceRectanglesRequest()
                try? handler.perform([request])
                return (request.results ?? []).reduce(Float(0)) { $0 + $1.confidence }
            }.value
            if conf > bestConfidence { bestConfidence = conf; bestDegrees = degrees }
        }
        guard bestConfidence > 0 else { return nil }
        return OrientationClassificationResult(
            rotationDegrees: bestDegrees, confidence: min(1.0, bestConfidence), method: "face_detection"
        )
    }

    private func classifyViaFaces(url: URL) async -> OrientationClassificationResult? {
        let candidates: [(CGImagePropertyOrientation, Int)] = [
            (.up,    0),
            (.right, 90),
            (.down,  180),
            (.left,  270)
        ]

        var bestDegrees = 0
        var bestConfidence: Float = -1

        for (orientation, degrees) in candidates {
            let conf = await faceConfidence(url: url, orientation: orientation)
            if conf > bestConfidence {
                bestConfidence = conf
                bestDegrees = degrees
            }
        }

        guard bestConfidence > 0 else { return nil }

        return OrientationClassificationResult(
            rotationDegrees: bestDegrees,
            confidence: min(1.0, bestConfidence),
            method: "face_detection"
        )
    }

    private func faceConfidence(url: URL, orientation: CGImagePropertyOrientation) async -> Float {
        await Task.detached(priority: .userInitiated) {
            let handler = VNImageRequestHandler(url: url, orientation: orientation, options: [:])
            let request = VNDetectFaceRectanglesRequest()
            try? handler.perform([request])
            return (request.results ?? []).reduce(Float(0)) { $0 + $1.confidence }
        }.value
    }

    // MARK: - Strategy 3: Luminance gravity heuristic

    private func classifyViaLuminance(cgImage: CGImage) -> OrientationClassificationResult? {
        classifyViaLuminance(full: cgImage)
    }

    private func classifyViaLuminance(url: URL) -> OrientationClassificationResult? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let full = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceThumbnailMaxPixelSize: 128 as CFNumber,
                  kCGImageSourceCreateThumbnailFromImageIfAbsent: true
              ] as CFDictionary) else { return nil }
        return classifyViaLuminance(full: full)
    }

    private func classifyViaLuminance(full: CGImage) -> OrientationClassificationResult? {
        let size = 64
        guard let cs  = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: size, height: size,
                  bitsPerComponent: 8, bytesPerRow: size * 4,
                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = ctx.data else { return nil }

        let ptr = data.bindMemory(to: UInt8.self, capacity: size * size * 4)
        let mid = size / 2
        var top = Float(0), bottom = Float(0), left = Float(0), right = Float(0)

        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                let lum = (0.299 * Float(ptr[i]) + 0.587 * Float(ptr[i+1]) + 0.114 * Float(ptr[i+2])) / 255.0
                if y < mid { top    += lum } else { bottom += lum }
                if x < mid { left   += lum } else { right  += lum }
            }
        }

        let half = Float(size * size / 2)
        let t = top    / half
        let b = bottom / half
        let l = left   / half
        let r = right  / half

        // After rotating CW by d degrees the named side of the original image becomes the new top:
        //   0°  → current top stays at top    (score = t)
        //  90°  → current left goes to top    (score = l)
        // 180°  → current bottom goes to top  (score = b)
        // 270°  → current right goes to top   (score = r)
        let scores: [(degrees: Int, score: Float)] = [
            (0,   t),
            (90,  l),
            (180, b),
            (270, r)
        ]

        guard let best  = scores.max(by: { $0.score < $1.score }),
              let worst = scores.min(by: { $0.score < $1.score }) else { return nil }

        let spread = best.score - worst.score

        guard spread > 0.04 else {
            return OrientationClassificationResult(rotationDegrees: 0, confidence: 0.1, method: "default")
        }

        return OrientationClassificationResult(
            rotationDegrees: best.degrees,
            confidence: min(0.7, spread * 10),
            method: "luminance"
        )
    }
}
