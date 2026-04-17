import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import os.log

private let dustLog = Logger(subsystem: "HoehnPhotosOrganizer", category: "DustDetection")

// MARK: - Detection Result

/// A single dust or hair artifact detection with bounding box and classification.
struct DustDetection: Sendable {
    enum ArtifactType: String, Sendable {
        case dust
        case hair
    }

    /// Bounding box in original image pixel coordinates.
    let boundingBox: CGRect
    /// Detected artifact type (dust speck vs hair strand).
    let artifactType: ArtifactType
    /// Detection confidence 0–1.
    let confidence: Float
}

// MARK: - DustDetectionError

enum DustDetectionError: Error, LocalizedError {
    case modelNotFound
    case imageConversionFailed
    case unexpectedOutputFormat(String)
    case maskGenerationFailed

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "FilmDustDetector model not found in app bundle."
        case .imageConversionFailed:
            return "Failed to convert image to CVPixelBuffer for dust detection."
        case .unexpectedOutputFormat(let detail):
            return "Dust detector output format unexpected: \(detail)"
        case .maskGenerationFailed:
            return "Failed to generate inpainting mask from detections."
        }
    }
}

// MARK: - DustDetectionService

/// Detects dust specks and hair artifacts on scanned film images using a fine-tuned
/// YOLOv8 CoreML model. Produces bounding-box detections that are dilated into
/// pixel-level masks suitable for inpainting.
///
/// Model: `FilmDustDetector.mlmodelc` (YOLOv8n fine-tuned on film scan artifacts)
/// Classes: 0 = dust, 1 = hair
/// Input: 640x640 letterboxed image (same as existing FilmStripDetector)
/// Performance: ~6ms/image on M-series Neural Engine
actor DustDetectionService {

    static let modelName = "FilmDustDetector"
    private static let inputSize: CGFloat = 640

    // MARK: - Lazy model

    private var mlModel: MLModel?

    /// `true` when the bundled Core ML model is present.
    nonisolated static var isAvailable: Bool {
        Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") != nil
            || Bundle.main.url(forResource: modelName, withExtension: "mlpackage") != nil
    }

    // MARK: - Public API

    /// Detect dust and hair artifacts in the given image.
    /// Returns detections sorted by confidence (highest first).
    func detectArtifacts(
        in image: CGImage,
        confidenceThreshold: Float = 0.25
    ) async throws -> [DustDetection] {
        let model = try loadModel()
        let originalSize = CGSize(width: image.width, height: image.height)

        guard let pixelBuffer = Self.pixelBuffer(from: image, side: Int(Self.inputSize)) else {
            throw DustDetectionError.imageConversionFailed
        }

        dustLog.info("DustDetector: \(image.width)x\(image.height) -> letterboxed \(Int(Self.inputSize))x\(Int(Self.inputSize))")

        let inputProvider = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: pixelBuffer)
        ])
        let output = try await model.prediction(from: inputProvider)

        guard let boxArray = output.featureValue(for: "coordinates")?.multiArrayValue
                          ?? output.featureValue(for: "var_846")?.multiArrayValue,
              let scoreArray = output.featureValue(for: "confidence")?.multiArrayValue
                            ?? output.featureValue(for: "var_848")?.multiArrayValue else {
            let keys = output.featureNames.joined(separator: ", ")
            throw DustDetectionError.unexpectedOutputFormat(
                "Expected 'coordinates'/'confidence'. Got: \(keys)"
            )
        }

        let detections = Self.parseDetections(
            boxes: boxArray,
            scores: scoreArray,
            originalSize: originalSize,
            threshold: confidenceThreshold
        )

        dustLog.info("DustDetector: \(detections.count) artifact(s) detected (threshold=\(confidenceThreshold))")

        return detections.sorted { $0.confidence > $1.confidence }
    }

    /// Generate a binary inpainting mask from detections.
    ///
    /// Each bounding box is dilated by `dilationRadius` pixels to ensure full
    /// coverage of the artifact edges. The mask is a grayscale CGImage where
    /// white (255) = inpaint region, black (0) = preserve.
    ///
    /// - Parameters:
    ///   - detections: Artifact detections from `detectArtifacts(in:)`.
    ///   - imageSize: Size of the original image (mask will match this).
    ///   - dilationRadius: Pixels to expand each bounding box (default 8).
    nonisolated func generateMask(
        from detections: [DustDetection],
        imageSize: CGSize,
        dilationRadius: Int = 8
    ) throws -> CGImage {
        let width = Int(imageSize.width)
        let height = Int(imageSize.height)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else {
            throw DustDetectionError.maskGenerationFailed
        }

        // Start with black (preserve everything)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Fill dilated bounding boxes in white (inpaint regions)
        context.setFillColor(CGColor(gray: 1, alpha: 1))

        let dilation = CGFloat(dilationRadius)
        for detection in detections {
            let box = detection.boundingBox
            // Dilate: expand each edge outward
            let dilated = CGRect(
                x: max(0, box.origin.x - dilation),
                y: max(0, box.origin.y - dilation),
                width: min(CGFloat(width) - max(0, box.origin.x - dilation),
                           box.width + dilation * 2),
                height: min(CGFloat(height) - max(0, box.origin.y - dilation),
                            box.height + dilation * 2)
            )

            // For hair artifacts, use an elongated elliptical mask instead of a rectangle
            // to better match the thin, curved shape of hairs
            if detection.artifactType == .hair {
                context.saveGState()
                context.addEllipse(in: dilated)
                context.fillPath()
                context.restoreGState()
            } else {
                // Dust specks: use rounded rect for softer mask edges
                let cornerRadius = min(dilated.width, dilated.height) * 0.3
                let path = CGPath(
                    roundedRect: dilated,
                    cornerWidth: cornerRadius,
                    cornerHeight: cornerRadius,
                    transform: nil
                )
                context.addPath(path)
                context.fillPath()
            }
        }

        guard let maskImage = context.makeImage() else {
            throw DustDetectionError.maskGenerationFailed
        }

        return maskImage
    }

    /// Convenience: detect artifacts and generate mask in one call.
    func detectAndGenerateMask(
        in image: CGImage,
        confidenceThreshold: Float = 0.25,
        dilationRadius: Int = 8
    ) async throws -> (detections: [DustDetection], mask: CGImage)? {
        let detections = try await detectArtifacts(
            in: image,
            confidenceThreshold: confidenceThreshold
        )

        guard !detections.isEmpty else {
            dustLog.info("DustDetector: No artifacts found — image is clean")
            return nil
        }

        let imageSize = CGSize(width: image.width, height: image.height)
        let mask = try generateMask(
            from: detections,
            imageSize: imageSize,
            dilationRadius: dilationRadius
        )

        return (detections, mask)
    }

    // MARK: - Model loading

    private func loadModel() throws -> MLModel {
        if let m = mlModel { return m }

        guard let modelURL = Bundle.main.url(forResource: Self.modelName, withExtension: "mlmodelc")
                          ?? Bundle.main.url(forResource: Self.modelName, withExtension: "mlpackage") else {
            throw DustDetectionError.modelNotFound
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all  // Neural Engine + GPU + CPU
        let model = try MLModel(contentsOf: modelURL, configuration: config)
        mlModel = model
        dustLog.info("DustDetector: Model loaded from \(modelURL.lastPathComponent)")
        return model
    }

    // MARK: - Pixel buffer

    /// Scales `image` into a `side x side` CVPixelBuffer using letterboxing (black bars)
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

        // Black letterbox background
        ctx?.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx?.fill(CGRect(x: 0, y: 0, width: side, height: side))

        // Draw image letterboxed, centred within side x side
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
    ) -> [DustDetection] {
        let boxFloats = floatArray(from: boxes)
        let scoreFloats = floatArray(from: scores)

        guard !boxFloats.isEmpty, !scoreFloats.isEmpty else { return [] }

        let detectionCount = boxFloats.count / 4
        guard detectionCount > 0 else { return [] }

        // 2 classes: dust (0), hair (1)
        let numClasses = max(1, scoreFloats.count / detectionCount)
        let needsNorm = boxFloats.prefix(min(40, boxFloats.count)).contains { $0 > 1.0 }
        let divisor: Float = needsNorm ? Float(inputSize) : 1.0

        // Letterbox parameters
        let imgW = CGFloat(originalSize.width), imgH = CGFloat(originalSize.height)
        let lbScale = min(inputSize / imgW, inputSize / imgH)
        let lbContentW = imgW * lbScale, lbContentH = imgH * lbScale
        let lbPadX = (inputSize - lbContentW) / 2
        let lbPadY = (inputSize - lbContentH) / 2

        var results: [DustDetection] = []

        for i in 0..<detectionCount {
            // Find best class for this detection
            let scoreBase = i * numClasses
            let scoreEnd = min(scoreBase + numClasses, scoreFloats.count)
            let classScores = Array(scoreFloats[scoreBase..<scoreEnd])
            guard let maxScore = classScores.max(), maxScore >= threshold else { continue }
            let classIdx = classScores.firstIndex(of: maxScore) ?? 0

            let base = i * 4
            let c0 = CGFloat(boxFloats[base + 0] / divisor)
            let c1 = CGFloat(boxFloats[base + 1] / divisor)
            let c2 = CGFloat(boxFloats[base + 2] / divisor)
            let c3 = CGFloat(boxFloats[base + 3] / divisor)

            // xywh normalised [0,1] -> pixel coords in 640x640 letterbox space
            let cx_lb = c0 * inputSize, cy_lb = c1 * inputSize
            let w_lb = c2 * inputSize, h_lb = c3 * inputSize
            let x1_lb = cx_lb - w_lb / 2, y1_lb = cy_lb - h_lb / 2
            let x2_lb = cx_lb + w_lb / 2, y2_lb = cy_lb + h_lb / 2

            // Remove letterbox padding -> original image pixel space
            let x1 = (x1_lb - lbPadX) / lbScale
            let y1 = (y1_lb - lbPadY) / lbScale
            let x2 = (x2_lb - lbPadX) / lbScale
            let y2 = (y2_lb - lbPadY) / lbScale

            // Discard detections whose centre falls outside the image
            let cx = (x1 + x2) / 2, cy = (y1 + y2) / 2
            guard cx >= 0, cx <= imgW, cy >= 0, cy <= imgH else { continue }

            let rect = CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
            guard rect.width > 0, rect.height > 0 else { continue }

            let artifactType: DustDetection.ArtifactType = classIdx == 1 ? .hair : .dust

            results.append(DustDetection(
                boundingBox: rect,
                artifactType: artifactType,
                confidence: maxScore
            ))
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
