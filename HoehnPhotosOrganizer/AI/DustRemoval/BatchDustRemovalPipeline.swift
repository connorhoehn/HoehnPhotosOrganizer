import CoreGraphics
import CoreImage
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers
import os.log

private let batchLog = Logger(subsystem: "HoehnPhotosOrganizer", category: "BatchDustRemoval")

// MARK: - Progress

/// Progress event emitted for each photo processed in the batch.
struct DustRemovalProgress: Sendable {
    let total: Int
    let completed: Int
    let failed: Int
    let skipped: Int  // images with no detected artifacts
    let currentPhotoName: String
    let phase: Phase

    enum Phase: String, Sendable {
        case rendering   // DNG -> TIFF/JPEG
        case detecting   // YOLOv8 dust/hair detection
        case inpainting  // LaMa/MAT fill
        case saving      // writing output
        case done
        case error
    }
}

// MARK: - Configuration

/// Configuration for a batch dust removal run.
struct DustRemovalConfig: Sendable {
    /// Minimum confidence for dust/hair detections (0–1).
    var confidenceThreshold: Float = 0.25
    /// Pixels to expand each detection bounding box before inpainting.
    var dilationRadius: Int = 8
    /// Which inpainting model to use.
    var inpaintingStrategy: InpaintingStrategy = .auto
    /// Maximum concurrent processing tasks (memory-bounded).
    var concurrency: Int = 2
    /// If true, save a debug overlay image showing detections alongside the cleaned output.
    var saveDebugOverlays: Bool = false
    /// JPEG quality for output files (0–1).
    var outputQuality: Double = 0.92
}

// MARK: - Per-image result

/// Detailed result for a single processed image.
struct DustRemovalImageResult: Sendable {
    let photoId: String
    let photoName: String
    let artifactsDetected: Int
    let dustCount: Int
    let hairCount: Int
    let maskedPixels: Int
    let inferenceTime: TimeInterval
    let outputPath: String?
    let error: String?
}

// MARK: - BatchDustRemovalPipeline

/// Coordinates the full detect-then-inpaint pipeline across a batch of scanned
/// film photos. Manages DNG rendering, YOLOv8 detection, mask generation, and
/// LaMa/MAT inpainting with progress reporting.
///
/// Processing order per image:
/// 1. DNG -> render to JPEG/TIFF (via proxy if available, or CIImage decode)
/// 2. YOLOv8 dust/hair detector
/// 3. Dilate bboxes -> binary mask
/// 4. LaMa / MAT inpainting
/// 5. Save result + record lineage
///
/// Target: fully local batch processing on Apple Silicon.
actor BatchDustRemovalPipeline {

    private let dustDetector = DustDetectionService()
    private let inpainter = InpaintingService()
    private let config: DustRemovalConfig

    /// Per-image results accumulated during the batch run.
    private(set) var imageResults: [DustRemovalImageResult] = []

    nonisolated init(config: DustRemovalConfig = DustRemovalConfig()) {
        self.config = config
    }

    // MARK: - Availability

    /// `true` when both detection and inpainting models are present.
    nonisolated static var isAvailable: Bool {
        DustDetectionService.isAvailable && InpaintingService.isAvailable
    }

    /// Describes which components are missing.
    nonisolated static var availabilityReport: String {
        var missing: [String] = []
        if !DustDetectionService.isAvailable {
            missing.append("FilmDustDetector model")
        }
        if !InpaintingService.lamaIsAvailable && !InpaintingService.matIsAvailable {
            missing.append("LaMa or MAT inpainting model")
        }
        if missing.isEmpty { return "All models available" }
        return "Missing: " + missing.joined(separator: ", ")
    }

    // MARK: - Public API

    /// Process a batch of photos through the dust removal pipeline.
    ///
    /// - Parameters:
    ///   - photos: Array of (photoId, sourceURL) tuples. sourceURL can be a DNG,
    ///     TIFF, or JPEG. For DNGs, the proxy JPEG is used if available.
    ///   - proxyLookup: Closure that returns the proxy URL for a photo ID, if available.
    ///   - outputDirectory: Where to write cleaned output files.
    ///   - db: Database for lineage recording.
    /// - Returns: AsyncStream of progress events.
    nonisolated func processPhotos(
        photos: [(id: String, name: String, sourceURL: URL, proxyURL: URL?)],
        outputDirectory: URL,
        db: AppDatabase? = nil
    ) -> AsyncStream<DustRemovalProgress> {
        AsyncStream { continuation in
            Task {
                await self.runBatch(
                    photos: photos,
                    outputDirectory: outputDirectory,
                    db: db,
                    continuation: continuation
                )
                continuation.finish()
            }
        }
    }

    // MARK: - Batch execution

    private func runBatch(
        photos: [(id: String, name: String, sourceURL: URL, proxyURL: URL?)],
        outputDirectory: URL,
        db: AppDatabase?,
        continuation: AsyncStream<DustRemovalProgress>.Continuation
    ) async {
        let total = photos.count
        var completed = 0
        var failed = 0
        var skipped = 0

        // Ensure output directory exists
        try? FileManager.default.createDirectory(
            at: outputDirectory, withIntermediateDirectories: true
        )

        let cleanedDir = outputDirectory.appendingPathComponent("cleaned", isDirectory: true)
        try? FileManager.default.createDirectory(at: cleanedDir, withIntermediateDirectories: true)

        let debugDir: URL?
        if config.saveDebugOverlays {
            let dir = outputDirectory.appendingPathComponent("debug", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            debugDir = dir
        } else {
            debugDir = nil
        }

        batchLog.info("BatchDustRemoval: starting \(total) photos, strategy=\(self.config.inpaintingStrategy.rawValue)")

        for photo in photos {
            let progress = { (phase: DustRemovalProgress.Phase) in
                DustRemovalProgress(
                    total: total,
                    completed: completed,
                    failed: failed,
                    skipped: skipped,
                    currentPhotoName: photo.name,
                    phase: phase
                )
            }

            do {
                continuation.yield(progress(.rendering))

                // Step 1: Load image (prefer proxy for speed, fall back to source)
                let cgImage = try loadImage(sourceURL: photo.sourceURL, proxyURL: photo.proxyURL)

                // Step 2: Detect dust/hair artifacts
                continuation.yield(progress(.detecting))
                let detectionResult = try await dustDetector.detectAndGenerateMask(
                    in: cgImage,
                    confidenceThreshold: config.confidenceThreshold,
                    dilationRadius: config.dilationRadius
                )

                guard let (detections, mask) = detectionResult else {
                    // No artifacts found — skip inpainting
                    skipped += 1
                    completed += 1
                    let result = DustRemovalImageResult(
                        photoId: photo.id,
                        photoName: photo.name,
                        artifactsDetected: 0,
                        dustCount: 0,
                        hairCount: 0,
                        maskedPixels: 0,
                        inferenceTime: 0,
                        outputPath: nil,
                        error: nil
                    )
                    imageResults.append(result)
                    continuation.yield(progress(.done))
                    continue
                }

                let dustCount = detections.filter { $0.artifactType == .dust }.count
                let hairCount = detections.filter { $0.artifactType == .hair }.count

                batchLog.info("BatchDustRemoval: \(photo.name) — \(dustCount) dust, \(hairCount) hair")

                // Step 3: Inpaint
                continuation.yield(progress(.inpainting))
                let inpaintResult = try await inpainter.inpaint(
                    image: cgImage,
                    mask: mask,
                    strategy: config.inpaintingStrategy,
                    detections: detections
                )

                // Step 4: Save output
                continuation.yield(progress(.saving))
                let baseName = (photo.name as NSString).deletingPathExtension
                let outputName = "\(baseName)_cleaned.jpg"
                let outputURL = cleanedDir.appendingPathComponent(outputName)

                try writeJPEG(inpaintResult.image, to: outputURL, quality: config.outputQuality)

                // Save debug overlay if enabled
                if let debugDir = debugDir {
                    let debugName = "\(baseName)_debug.jpg"
                    let debugURL = debugDir.appendingPathComponent(debugName)
                    if let overlay = renderDebugOverlay(
                        image: cgImage, detections: detections, mask: mask
                    ) {
                        try? writeJPEG(overlay, to: debugURL, quality: 0.85)
                    }
                }

                // Record lineage if database available
                if let db = db {
                    await recordLineage(
                        photoId: photo.id,
                        outputPath: outputURL.path,
                        detections: detections,
                        strategy: inpaintResult.strategy,
                        db: db
                    )
                }

                let result = DustRemovalImageResult(
                    photoId: photo.id,
                    photoName: photo.name,
                    artifactsDetected: detections.count,
                    dustCount: dustCount,
                    hairCount: hairCount,
                    maskedPixels: inpaintResult.maskedPixelCount,
                    inferenceTime: inpaintResult.inferenceTime,
                    outputPath: outputURL.path,
                    error: nil
                )
                imageResults.append(result)
                completed += 1
                continuation.yield(progress(.done))

            } catch {
                batchLog.error("BatchDustRemoval: \(photo.name) failed — \(error.localizedDescription)")
                let result = DustRemovalImageResult(
                    photoId: photo.id,
                    photoName: photo.name,
                    artifactsDetected: 0,
                    dustCount: 0,
                    hairCount: 0,
                    maskedPixels: 0,
                    inferenceTime: 0,
                    outputPath: nil,
                    error: error.localizedDescription
                )
                imageResults.append(result)
                failed += 1
                continuation.yield(progress(.error))
            }
        }

        batchLog.info("BatchDustRemoval: done — \(completed) completed, \(failed) failed, \(skipped) clean")
    }

    // MARK: - Image loading

    /// Load a CGImage from the best available source.
    /// Prefers the proxy JPEG (already rendered, fast to load) over the raw DNG.
    private nonisolated func loadImage(sourceURL: URL, proxyURL: URL?) throws -> CGImage {
        // Try proxy first (pre-rendered JPEG, fast)
        if let proxyURL = proxyURL,
           let source = CGImageSourceCreateWithURL(proxyURL as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return image
        }

        // DNG/TIFF: use CGImageSource with type hints for compatibility
        let ext = sourceURL.pathExtension.lowercased()
        let isDNG = ext == "dng"
        let sourceOpts: [CFDictionary?] = isDNG
            ? [nil, [kCGImageSourceTypeIdentifierHint: UTType.tiff.identifier] as CFDictionary]
            : [nil]

        for opts in sourceOpts {
            guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, opts),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            return image
        }

        // Last resort: CIImage decode
        guard let ciImage = CIImage(contentsOf: sourceURL) else {
            throw DustDetectionError.imageConversionFailed
        }
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw DustDetectionError.imageConversionFailed
        }
        return cgImage
    }

    // MARK: - JPEG writing

    private nonisolated func writeJPEG(_ image: CGImage, to url: URL, quality: Double) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw InpaintingError.postprocessingFailed
        }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw InpaintingError.postprocessingFailed
        }
    }

    // MARK: - Debug overlay

    /// Renders a debug image showing bounding boxes and the inpainting mask overlaid
    /// on the original for visual inspection.
    private nonisolated func renderDebugOverlay(
        image: CGImage,
        detections: [DustDetection],
        mask: CGImage
    ) -> CGImage? {
        let w = image.width, h = image.height

        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: w, height: h,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: cs,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        // Draw original
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Semi-transparent red overlay for mask
        ctx.saveGState()
        ctx.setAlpha(0.3)
        ctx.draw(mask, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()

        // Draw bounding boxes
        ctx.setLineWidth(2)
        for detection in detections {
            let color: CGColor
            switch detection.artifactType {
            case .dust:
                color = CGColor(red: 1, green: 0.3, blue: 0, alpha: 0.8) // orange
            case .hair:
                color = CGColor(red: 1, green: 0, blue: 0.3, alpha: 0.8) // red-pink
            }
            ctx.setStrokeColor(color)

            // CGContext y-axis is flipped relative to image coordinates
            let box = detection.boundingBox
            let flippedRect = CGRect(
                x: box.origin.x,
                y: CGFloat(h) - box.origin.y - box.height,
                width: box.width,
                height: box.height
            )
            ctx.stroke(flippedRect)
        }

        return ctx.makeImage()
    }

    // MARK: - Lineage recording

    private func recordLineage(
        photoId: String,
        outputPath: String,
        detections: [DustDetection],
        strategy: InpaintingStrategy,
        db: AppDatabase
    ) async {
        let now = ISO8601DateFormatter().string(from: .now)
        let dustCount = detections.filter { $0.artifactType == .dust }.count
        let hairCount = detections.filter { $0.artifactType == .hair }.count

        let metadata: [String: Any] = [
            "operation": "dust_removal",
            "dustCount": dustCount,
            "hairCount": hairCount,
            "strategy": strategy.rawValue,
            "totalDetections": detections.count
        ]
        let metadataJson = (try? JSONSerialization.data(withJSONObject: metadata))
            .flatMap { String(data: $0, encoding: .utf8) }

        let outputName = (outputPath as NSString).lastPathComponent
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int) ?? 0

        // Create output PhotoAsset
        var outputAsset = PhotoAsset.new(
            canonicalName: outputName,
            role: .workflowOutput,
            filePath: outputPath,
            fileSize: fileSize
        )

        let lineage = AssetLineage(
            id: UUID().uuidString,
            parentPhotoId: photoId,
            childPhotoId: outputAsset.id,
            operation: "dust_removal",
            frameIndex: nil,
            sourceFileName: outputName,
            createdAt: now,
            metadataJson: metadataJson,
            cropRectX: nil,
            cropRectY: nil,
            cropRectW: nil,
            cropRectH: nil
        )

        do {
            try await db.dbPool.write { db in
                try outputAsset.insert(db)
                try lineage.insert(db)
            }
        } catch {
            batchLog.error("BatchDustRemoval: lineage recording failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Output directory

    /// Returns the default dust removal output directory.
    /// Path: ~/Library/Application Support/HoehnPhotosOrganizer/dust_removal/
    nonisolated static func outputDirectory() -> URL {
        let fm = FileManager.default
        let appSupport = try! fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = appSupport
            .appendingPathComponent("HoehnPhotosOrganizer", isDirectory: true)
            .appendingPathComponent("dust_removal", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
