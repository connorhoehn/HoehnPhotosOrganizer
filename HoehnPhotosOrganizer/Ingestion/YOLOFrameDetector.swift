import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import os.log

private let yoloLog = Logger(subsystem: "HoehnPhotosOrganizer", category: "YOLODetector")

/// Detects film frame bounding boxes using the bundled YOLOv8 Core ML model.
/// Runs a single letterboxed inference pass on the full strip image.
struct YOLOFrameDetector: Sendable {

    static let modelName = "FilmStripDetector"
    private static let inputSize: CGFloat = 640

    /// `true` when the bundled Core ML model is present.
    nonisolated static var isAvailable: Bool {
        Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") != nil
            || Bundle.main.url(forResource: modelName, withExtension: "mlpackage") != nil
    }

    // MARK: - Public API

    /// Runs single-pass inference on `image` and returns detected frame rects in pixel
    /// coordinates (original image space), sorted top-to-bottom / left-to-right.
    func detectFrames(in image: CGImage, confidenceThreshold: Float = 0.35) async throws -> [CGRect] {
        guard let modelURL = Bundle.main.url(forResource: Self.modelName, withExtension: "mlmodelc")
                          ?? Bundle.main.url(forResource: Self.modelName, withExtension: "mlpackage") else {
            throw YOLODetectorError.modelNotFound
        }

        let mlModel = try MLModel(contentsOf: modelURL)
        let originalSize = CGSize(width: image.width, height: image.height)

        // Letterbox the full strip to 640×640 for a single inference pass.
        guard let pixelBuffer = Self.pixelBuffer(from: image, side: Int(Self.inputSize)) else {
            throw YOLODetectorError.imageConversionFailed
        }

        yoloLog.info("YOLODetector: \(image.width)×\(image.height) → letterboxed \(Int(Self.inputSize))×\(Int(Self.inputSize))")

        let inputProvider = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: pixelBuffer)
        ])
        let output = try await mlModel.prediction(from: inputProvider)

        guard let boxArray   = output.featureValue(for: "coordinates")?.multiArrayValue
                            ?? output.featureValue(for: "var_846")?.multiArrayValue,
              let scoreArray = output.featureValue(for: "confidence")?.multiArrayValue
                            ?? output.featureValue(for: "var_848")?.multiArrayValue else {
            let keys = output.featureNames.joined(separator: ", ")
            throw YOLODetectorError.unexpectedOutputFormat(
                "Expected 'coordinates'/'confidence' or 'var_846'/'var_848'. Got: \(keys)"
            )
        }

        let rects = Self.parseDetections(
            boxes: boxArray,
            scores: scoreArray,
            originalSize: originalSize,
            threshold: confidenceThreshold
        )

        yoloLog.info("YOLODetector: \(rects.count) frame(s) detected (threshold=\(confidenceThreshold))")

        return rects.sorted { l, r in
            abs(l.minY - r.minY) > l.height * 0.5 ? l.minY < r.minY : l.minX < r.minX
        }
    }

    // MARK: - Pixel buffer

    /// Scales `image` into a `side × side` CVPixelBuffer using letterboxing (black bars)
    /// to preserve aspect ratio, matching YOLO training letterboxing.
    private static func pixelBuffer(from image: CGImage, side: Int) -> CVPixelBuffer? {
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!
        ] as CFDictionary

        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, side, side,
                                  kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
              let pb else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: side, height: side,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )

        // Black letterbox background.
        ctx?.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx?.fill(CGRect(x: 0, y: 0, width: side, height: side))

        // Draw image letterboxed, centred within side×side.
        let imgW = CGFloat(image.width), imgH = CGFloat(image.height)
        let scale = min(CGFloat(side) / imgW, CGFloat(side) / imgH)
        let drawW = imgW * scale, drawH = imgH * scale
        let drawX = (CGFloat(side) - drawW) / 2
        let drawY = (CGFloat(side) - drawH) / 2

        ctx?.interpolationQuality = .medium
        ctx?.draw(image, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
        return pb
    }

    // MARK: - Output parsing

    private static func parseDetections(
        boxes: MLMultiArray,
        scores: MLMultiArray,
        originalSize: CGSize,
        threshold: Float
    ) -> [CGRect] {
        let boxFloats   = floatArray(from: boxes)
        let scoreFloats = floatArray(from: scores)

        guard !boxFloats.isEmpty, !scoreFloats.isEmpty else { return [] }

        let detectionCount = boxFloats.count / 4
        guard detectionCount > 0 else { return [] }

        let numClasses = max(1, scoreFloats.count / detectionCount)
        let needsNorm = boxFloats.prefix(min(40, boxFloats.count)).contains { $0 > 1.0 }
        let divisor: Float = needsNorm ? Float(inputSize) : 1.0

        // Letterbox parameters for the original image within the 640×640 buffer.
        let imgW = CGFloat(originalSize.width), imgH = CGFloat(originalSize.height)
        let lbScale   = min(inputSize / imgW, inputSize / imgH)
        let lbContentW = imgW * lbScale, lbContentH = imgH * lbScale
        let lbPadX = (inputSize - lbContentW) / 2
        let lbPadY = (inputSize - lbContentH) / 2

        let confPerDetection: [Float] = (0..<detectionCount).map { i in
            let base = i * numClasses
            let end  = min(base + numClasses, scoreFloats.count)
            return scoreFloats[base..<end].max() ?? 0
        }

        let maxConf     = confPerDetection.max() ?? 0
        let aboveThresh = confPerDetection.filter { $0 >= threshold }.count
        yoloLog.info("YOLODetector: N=\(detectionCount) maxConf=\(String(format: "%.3f", maxConf)) above(\(threshold))=\(aboveThresh)")

        var results: [CGRect] = []

        for i in 0..<detectionCount {
            guard confPerDetection[i] >= threshold else { continue }

            let base = i * 4
            let c0 = CGFloat(boxFloats[base + 0] / divisor)
            let c1 = CGFloat(boxFloats[base + 1] / divisor)
            let c2 = CGFloat(boxFloats[base + 2] / divisor)
            let c3 = CGFloat(boxFloats[base + 3] / divisor)

            // xywh normalised [0,1] → pixel coords in 640×640 letterbox space.
            let cx_lb = c0 * inputSize, cy_lb = c1 * inputSize
            let w_lb  = c2 * inputSize, h_lb  = c3 * inputSize
            let x1_lb = cx_lb - w_lb / 2, y1_lb = cy_lb - h_lb / 2
            let x2_lb = cx_lb + w_lb / 2, y2_lb = cy_lb + h_lb / 2

            // Remove letterbox padding → original image pixel space.
            let x1 = (x1_lb - lbPadX) / lbScale
            let y1 = (y1_lb - lbPadY) / lbScale
            let x2 = (x2_lb - lbPadX) / lbScale
            let y2 = (y2_lb - lbPadY) / lbScale

            // Discard detections whose centre falls outside the image content area.
            let cx = (x1 + x2) / 2, cy = (y1 + y2) / 2
            guard cx >= 0, cx <= imgW, cy >= 0, cy <= imgH else { continue }

            let rect = CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
            guard rect.width > 0, rect.height > 0 else { continue }
            results.append(rect)
        }

        return results
    }

    // MARK: - Array helper

    private static func floatArray(from array: MLMultiArray) -> [Float] {
        let count = array.count
        if array.dataType == .float32 {
            let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: count)
            return Array(UnsafeBufferPointer(start: ptr, count: count))
        } else if array.dataType == .double {
            let ptr = array.dataPointer.bindMemory(to: Double.self, capacity: count)
            return (0..<count).map { Float(ptr[$0]) }
        } else {
            return (0..<count).map { array[$0].floatValue }
        }
    }
}

// MARK: - Error

enum YOLODetectorError: Error, LocalizedError {
    case modelNotFound
    case imageConversionFailed
    case unexpectedOutputFormat(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "FilmStripDetector.mlpackage not found in app bundle."
        case .imageConversionFailed:
            return "Failed to convert image to CVPixelBuffer for model input."
        case .unexpectedOutputFormat(let detail):
            return "YOLOv8 output format unexpected: \(detail)"
        }
    }
}
