import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum FilmStripOrientation: String, Sendable {
    case horizontal
    case vertical

    nonisolated var label: String {
        switch self {
        case .horizontal:
            "Horizontal"
        case .vertical:
            "Vertical"
        }
    }
}

enum PipelineToolStatus: String, Codable, Sendable {
    case started
    case succeeded
    case failed
    case skipped
    case fallback
}

struct PipelineToolRun: Identifiable, Codable, Sendable {
    let id: UUID
    let timestamp: String
    let name: String
    let status: PipelineToolStatus
    let detail: String

    nonisolated init(name: String, status: PipelineToolStatus, detail: String, timestamp: String = ISO8601DateFormatter().string(from: Date())) {
        self.id = UUID()
        self.timestamp = timestamp
        self.name = name
        self.status = status
        self.detail = detail
    }
}

struct FilmStripExtractionResult: Sendable {
    let sourceURL: URL
    /// Strip-space rects that were used as the input to export (may be manually edited).
    let frameRects: [CGRect]
    let exportedURLs: [URL]
    /// Per-frame border-trim results when trimming was enabled. Empty when trimming was off.
    let trimResults: [FrameTrimResult]
    /// JSON manifest mapping this extraction back to the original source scan.
    let lineageManifestURL: URL?
    /// Ordered list of tools that ran during extraction/export.
    let toolRuns: [PipelineToolRun]
}

struct FilmStripLineageManifest: Codable, Sendable {
    struct Clip: Codable, Sendable {
        let frameIndex: Int
        let exportedFileName: String
        let sourceRect: RectCodable
        let trimApplied: Bool
        let trimConfidence: Double?
    }

    let sourceFileName: String
    let sourceFilePath: String
    let extractedAt: String
    let orientation: String
    let detectorMethod: String
    let clips: [Clip]
}

struct RectCodable: Codable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }
}

enum FilmStripFrameExtractorError: Error, LocalizedError {
    case failedToOpenImage(URL)
    case failedToDecodeImage(URL)
    case failedToCreateAnalysisContext
    case noFramesDetected
    case failedToCropFrame(index: Int)
    case failedToCreateDestination(URL)
    case failedToFinalizeDestination(URL)

    var errorDescription: String? {
        switch self {
        case .failedToOpenImage(let url):
            "Failed to open image at \(url.path)."
        case .failedToDecodeImage(let url):
            "Failed to decode image at \(url.path)."
        case .failedToCreateAnalysisContext:
            "Failed to create pixel analysis context."
        case .noFramesDetected:
            "No valid frame boundaries were detected."
        case .failedToCropFrame(let index):
            "Failed to crop frame \(index)."
        case .failedToCreateDestination(let url):
            "Failed to create TIFF destination at \(url.path)."
        case .failedToFinalizeDestination(let url):
            "Failed to finalize TIFF destination at \(url.path)."
        }
    }
}

struct FilmStripFrameExtractor: Sendable {

    enum ExportFormat: String, CaseIterable, Sendable {
        case tiff = "TIFF"
        case dng  = "DNG"
        case jpeg = "JPEG"
        case png  = "PNG"
        case heic = "HEIC"

        var fileExtension: String {
            switch self {
            case .tiff: return "tif"
            case .dng:  return "dng"
            case .jpeg: return "jpg"
            case .png:  return "png"
            case .heic: return "heic"
            }
        }

        var utType: UTType {
            switch self {
            case .tiff: return .tiff
            case .dng:  return .tiff   // unused for DNG — MinimalDNGWriter handles the write
            case .jpeg: return .jpeg
            case .png:  return .png
            case .heic: return .heic
            }
        }
    }

    struct Configuration: Sendable {
        var outputPrefix: String = "frame"
        /// When `true`, each exported frame is passed through `FilmFrameTrimmer` to remove the
        /// dark film-rebate border on all four sides before writing to disk.
        var trimBordersAfterExport: Bool = true
        /// Trimmer configuration. Change to tune aspect-ratio validation or border thresholds.
        var trimmerConfiguration: FilmFrameTrimmer.Configuration = .default
        /// Preserve source scan basename in exported clip names for lineage.
        var includeSourceBasenameInClipName: Bool = true
        /// Output file format for exported frames.
        var exportFormat: ExportFormat = .tiff
        /// Per-frame rotation overrides. Key is 1-based frame index, value is clockwise degrees (0/90/180/270).
        var frameRotations: [Int: Int] = [:]
        /// Strip-level pre-rotation (CW degrees: 0/90/180/270) applied to the entire scan image
        /// before YOLO detection AND before frame export.  Use when the scanner saved a sideways strip
        /// with orientation=1 (no EXIF rotation flag).
        var stripRotationDegrees: Int = 0

        nonisolated static let `default` = Configuration()
    }

    let configuration: Configuration

    nonisolated init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    // MARK: - Public export API

    /// Exports frame crops from `sourceURL` using the provided `frameRects` (caller-supplied,
    /// e.g. from YOLOFrameDetector) to `outputDirectory`.
    nonisolated func exportFrames(from sourceURL: URL, frameRects: [CGRect], to outputDirectory: URL) throws -> FilmStripExtractionResult {
        var cgImage = try Self.loadImage(at: sourceURL)
        if configuration.stripRotationDegrees != 0,
           let rotated = Self.rotateStatic(cgImage, clockwiseDegrees: configuration.stripRotationDegrees) {
            cgImage = rotated
        }
        return try exportFrames(from: sourceURL, image: cgImage, frameRects: frameRects, to: outputDirectory)
    }

    // MARK: - Internal export implementation

    nonisolated private func exportFrames(from sourceURL: URL, image: CGImage, frameRects: [CGRect], to outputDirectory: URL) throws -> FilmStripExtractionResult {
        guard !frameRects.isEmpty else {
            throw FilmStripFrameExtractorError.noFramesDetected
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let trimmer = configuration.trimBordersAfterExport
            ? FilmFrameTrimmer(configuration: configuration.trimmerConfiguration)
            : nil as FilmFrameTrimmer?

        let stripBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let sourceStem = sourceURL.deletingPathExtension().lastPathComponent

        var exportedURLs: [URL] = []
        var trimResults: [FrameTrimResult] = []
        var manifestClips: [FilmStripLineageManifest.Clip] = []
        var toolRuns: [PipelineToolRun] = [
            PipelineToolRun(name: "createOutputDirectory", status: .succeeded, detail: outputDirectory.path),
            PipelineToolRun(name: "selectExportNaming", status: .succeeded, detail: configuration.includeSourceBasenameInClipName ? "Use source basename in clip filename." : "Use generic output prefix.")
        ]

        for (index, rect) in frameRects.enumerated() {
            // Step 1: initial crop to the strip-level frame rect
            let clampedRect = rect.integral.clamped(to: stripBounds)
            guard clampedRect.width >= 2, clampedRect.height >= 2,
                  let initialCrop = image.cropping(to: clampedRect)
            else {
                toolRuns.append(PipelineToolRun(name: "cropFrame_\(index + 1)", status: .failed, detail: "Initial crop failed for frame \(index + 1)."))
                throw FilmStripFrameExtractorError.failedToCropFrame(index: index + 1)
            }
            toolRuns.append(PipelineToolRun(name: "cropFrame_\(index + 1)", status: .succeeded, detail: "Cropped strip frame candidate."))

            // Step 2: optionally trim rebate borders
            var finalImage = initialCrop
            if let trimmer {
                if let trimResult = try? trimmer.trim(frame: initialCrop, originalRect: clampedRect, index: index + 1) {
                    trimResults.append(trimResult)
                    if trimResult.passed {
                        // Re-crop the full-res image with the trimmed (tighter) rect
                        let trimmedClamped = trimResult.trimmedRect.integral.clamped(to: stripBounds)
                        if trimmedClamped.width >= 16, trimmedClamped.height >= 16,
                           let trimmedCrop = image.cropping(to: trimmedClamped) {
                            finalImage = trimmedCrop
                            toolRuns.append(PipelineToolRun(name: "trimBorders_\(index + 1)", status: .succeeded, detail: "Trimmed borders with confidence \(String(format: "%.2f", trimResult.confidence))."))
                        }
                    } else {
                        toolRuns.append(PipelineToolRun(name: "trimBorders_\(index + 1)", status: .fallback, detail: "Low confidence trim (\(String(format: "%.2f", trimResult.confidence))); original crop kept."))
                    }
                } else {
                    toolRuns.append(PipelineToolRun(name: "trimBorders_\(index + 1)", status: .failed, detail: "Trim analysis failed; original crop kept."))
                }
            } else {
                toolRuns.append(PipelineToolRun(name: "trimBorders_\(index + 1)", status: .skipped, detail: "Border trimming disabled."))
            }

            let clipNameStem: String
            if configuration.includeSourceBasenameInClipName {
                clipNameStem = sourceStem
            } else {
                clipNameStem = configuration.outputPrefix
            }

            // Apply user-specified rotation (CW degrees).
            if let degrees = configuration.frameRotations[index + 1], degrees != 0,
               let rotated = rotateImage(finalImage, clockwiseDegrees: degrees) {
                finalImage = rotated
                toolRuns.append(PipelineToolRun(name: "rotateFrame_\(index + 1)", status: .succeeded, detail: "Rotated \(degrees)° CW."))
            }

            let outputURL = outputDirectory.appendingPathComponent(
                "\(clipNameStem)_\(String(format: "%02d", index + 1)).\(configuration.exportFormat.fileExtension)"
            )

            try writeImage(finalImage, to: outputURL, format: configuration.exportFormat)
            exportedURLs.append(outputURL)
            toolRuns.append(PipelineToolRun(name: "writeClip_\(index + 1)", status: .succeeded, detail: outputURL.lastPathComponent))

            let trimResult = trimResults.last(where: { $0.frameIndex == index + 1 })
            manifestClips.append(
                FilmStripLineageManifest.Clip(
                    frameIndex: index + 1,
                    exportedFileName: outputURL.lastPathComponent,
                    sourceRect: RectCodable(clampedRect),
                    trimApplied: trimResult?.passed == true,
                    trimConfidence: trimResult?.confidence
                )
            )
        }

        let orientation: FilmStripOrientation = imageLikelyVertical(image) ? .vertical : .horizontal
        let manifest = FilmStripLineageManifest(
            sourceFileName: sourceURL.lastPathComponent,
            sourceFilePath: sourceURL.path,
            extractedAt: ISO8601DateFormatter().string(from: Date()),
            orientation: orientation.rawValue,
            detectorMethod: "yolo",
            clips: manifestClips
        )

        let manifestURL = outputDirectory.appendingPathComponent("\(sourceStem)_lineage.json")
        do {
            try writeLineageManifest(manifest, to: manifestURL)
            toolRuns.append(PipelineToolRun(name: "writeLineageManifest", status: .succeeded, detail: manifestURL.lastPathComponent))
        } catch {
            toolRuns.append(PipelineToolRun(name: "writeLineageManifest", status: .failed, detail: error.localizedDescription))
        }

        return FilmStripExtractionResult(
            sourceURL: sourceURL,
            frameRects: frameRects,
            exportedURLs: exportedURLs,
            trimResults: trimResults,
            lineageManifestURL: FileManager.default.fileExists(atPath: manifestURL.path) ? manifestURL : nil,
            toolRuns: toolRuns
        )
    }

    // MARK: - Helpers

    nonisolated private func imageLikelyVertical(_ image: CGImage) -> Bool {
        Double(image.height) / Double(image.width) > 1.2
    }

    nonisolated static func loadImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw FilmStripFrameExtractorError.failedToOpenImage(url)
        }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldAllowFloat: true
        ]

        guard var image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            throw FilmStripFrameExtractorError.failedToDecodeImage(url)
        }

        // CGImageSourceCreateImageAtIndex ignores orientation metadata; scanners (e.g. Epson)
        // often save portrait strips with orientation=6 (needs 90° CW) or 8 (needs 90° CCW).
        // Apply correction so YOLO and frame crops work in display-correct pixel space.
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            let rawOrientation = props[kCGImagePropertyOrientation as String] as? Int32
                ?? (props[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[kCGImagePropertyTIFFOrientation as String] as? Int32
                ?? 1
            print("[FilmStripFrameExtractor] loadImage: orientation=\(rawOrientation) — \(url.lastPathComponent)")
            if let corrected = applyEXIFOrientation(rawOrientation, to: image) {
                image = corrected
            }
        }

        return image
    }

    /// Rotate a CGImage to correct for EXIF/TIFF orientation tags.
    /// Only handles the 4 rotation-only orientations (1/3/6/8); flipped variants are rare for scanners.
    private static func applyEXIFOrientation(_ orientation: Int32, to image: CGImage) -> CGImage? {
        let cw: Int
        switch orientation {
        case 1: return nil  // Normal — no change needed
        case 3: cw = 180
        case 6: cw = 90     // Stored 90° CCW, rotate CW to fix
        case 8: cw = 270    // Stored 90° CW, rotate CCW to fix
        default: return nil
        }
        return rotateStatic(image, clockwiseDegrees: cw)
    }

    nonisolated static func rotateStatic(_ image: CGImage, clockwiseDegrees: Int) -> CGImage? {
        let degrees = ((clockwiseDegrees % 360) + 360) % 360
        guard degrees != 0 else { return image }

        let swap = degrees == 90 || degrees == 270
        let newW = swap ? image.height : image.width
        let newH = swap ? image.width  : image.height
        let radians = -CGFloat(degrees) * .pi / 180.0

        guard let space = image.colorSpace,
              let ctx = CGContext(
                data: nil, width: newW, height: newH,
                bitsPerComponent: image.bitsPerComponent,
                bytesPerRow: 0, space: space,
                bitmapInfo: image.bitmapInfo.rawValue
              ) else { return nil }

        ctx.translateBy(x: CGFloat(newW) / 2, y: CGFloat(newH) / 2)
        ctx.rotate(by: radians)
        ctx.translateBy(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// Estimate the likely number of frames based on image aspect ratio.
    /// 35mm film strip: each frame ~24mm wide, typical gap ~2mm → aspect ratio ~1.5:1 per frame.
    nonisolated static func estimateFrameCount(imageWidth: Int, imageHeight: Int) -> Int {
        let isVertical = imageHeight > imageWidth
        if isVertical {
            // Frames stacked vertically; one 35mm frame is 1.5× wider than tall
            let estimatedFrameHeight = Double(imageWidth) * (36.0 / 24.0)
            return max(1, min(6, Int((Double(imageHeight) / estimatedFrameHeight).rounded())))
        } else {
            let stripAspect = Double(imageWidth) / Double(imageHeight)
            return max(1, min(12, Int((stripAspect / 1.5).rounded())))
        }
    }

    nonisolated private func rotateImage(_ image: CGImage, clockwiseDegrees: Int) -> CGImage? {
        let degrees = ((clockwiseDegrees % 360) + 360) % 360
        guard degrees != 0 else { return image }

        let swap = degrees == 90 || degrees == 270
        let newW = swap ? image.height : image.width
        let newH = swap ? image.width  : image.height
        let radians = -CGFloat(degrees) * .pi / 180.0  // negative = clockwise in Core Graphics

        guard let space = image.colorSpace,
              let ctx = CGContext(
                data: nil, width: newW, height: newH,
                bitsPerComponent: image.bitsPerComponent,
                bytesPerRow: 0, space: space,
                bitmapInfo: image.bitmapInfo.rawValue
              ) else { return nil }

        ctx.translateBy(x: CGFloat(newW) / 2, y: CGFloat(newH) / 2)
        ctx.rotate(by: radians)
        ctx.translateBy(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    nonisolated private func writeImage(_ image: CGImage, to url: URL, format: ExportFormat) throws {
        // DNG uses MinimalDNGWriter to produce a proper Linear DNG binary.
        if format == .dng {
            try MinimalDNGWriter.write(image, to: url)
            return
        }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, format.utType.identifier as CFString, 1, nil
        ) else {
            throw FilmStripFrameExtractorError.failedToCreateDestination(url)
        }

        var properties: [CFString: Any] = [:]
        switch format {
        case .tiff:
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 1] as CFDictionary
        case .jpeg:
            properties[kCGImageDestinationLossyCompressionQuality] = 0.92
        case .heic:
            properties[kCGImageDestinationLossyCompressionQuality] = 0.90
        case .png, .dng:
            break
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw FilmStripFrameExtractorError.failedToFinalizeDestination(url)
        }
    }

    nonisolated private func writeLineageManifest(_ manifest: FilmStripLineageManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }
}

private extension CGRect {
    nonisolated var integral: CGRect {
        CGRect(
            x: floor(origin.x),
            y: floor(origin.y),
            width: floor(size.width),
            height: floor(size.height)
        )
    }

    nonisolated func clamped(to bounds: CGRect) -> CGRect {
        let minX = max(origin.x, bounds.minX)
        let minY = max(origin.y, bounds.minY)
        let maxX = min(origin.x + size.width, bounds.maxX)
        let maxY = min(origin.y + size.height, bounds.maxY)
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
}
