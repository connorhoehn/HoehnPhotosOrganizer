import AppKit
import CoreGraphics
import os.log
import SwiftUI

private let log = Logger(subsystem: "HoehnPhotosOrganizer", category: "FilmStripDetection")

/// Runs frame detection across all provided scan files and transitions to review when done.
///
/// Detection is performed sequentially per file using the YOLOv8 Core ML model.
/// Thumbnails are cropped from each detected frame for display in `FrameReviewView`.
struct FilmStripDetectingView: View {
    let template: ImportTemplate
    let fileURLs: [URL]
    /// CW degrees applied to each strip image before YOLO detection (0/90/180/270).
    var stripRotationDegrees: Int = 0
    let onComplete: ([DetectedFrame]) -> Void
    let onBack: () -> Void

    @State private var progress: Double = 0
    @State private var statusMessage = "Preparing…"
    @State private var failedFiles: [String] = []
    @State private var isCancelled = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 28) {
                Image(systemName: "film.stack")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.accentColor)

                VStack(spacing: 8) {
                    Text("Detecting Frames")
                        .font(.title.bold())
                    Text(statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                }

                ProgressView(value: progress)
                    .frame(maxWidth: 360)
                    .progressViewStyle(.linear)

                if !failedFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Warning: \(failedFiles.count) file\(failedFiles.count == 1 ? "" : "s") could not be processed")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                        ForEach(failedFiles, id: \.self) { name in
                            Text("• \(name)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }

                Button("Cancel") {
                    isCancelled = true
                    onBack()
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await detectAll() }
    }

    // MARK: - Detection

    private func detectAll() async {
        var allFrames: [DetectedFrame] = []
        let yolo = YOLOFrameDetector()

        log.info("detectAll: starting — \(fileURLs.count) file(s)")

        for (i, url) in fileURLs.enumerated() {
            guard !isCancelled else { return }

            statusMessage = "Scanning \(url.lastPathComponent) (\(i + 1) of \(fileURLs.count))…"
            progress = Double(i) / Double(fileURLs.count)
            log.info("detectAll: processing file \(i + 1)/\(fileURLs.count) — \(url.lastPathComponent)")

            do {
                let rawImage = try await Task.detached(priority: .userInitiated) {
                    try FilmStripFrameExtractor.loadImage(at: url)
                }.value
                let rotation = stripRotationDegrees
                let cgImage: CGImage = rotation != 0
                    ? (FilmStripFrameExtractor.rotateStatic(rawImage, clockwiseDegrees: rotation) ?? rawImage)
                    : rawImage
                log.info("detectAll: image loaded — \(cgImage.width)×\(cgImage.height)px (strip rotation \(rotation)°)")

                let rects = try await yolo.detectFrames(in: cgImage)
                log.info("detectAll: YOLO found \(rects.count) rect(s)")

                let frames: [DetectedFrame] = rects.enumerated().compactMap { idx, rect in
                    guard let thumb = Self.thumbnail(from: cgImage, rect: rect) else {
                        log.warning("detectAll: thumbnail failed for rect \(idx) \(rect.debugDescription)")
                        return nil
                    }
                    return DetectedFrame(id: UUID(), sourceScanURL: url,
                                        cropRect: rect, thumbnail: thumb, frameIndex: idx + 1)
                }
                log.info("detectAll: \(frames.count) DetectedFrame(s) produced from \(url.lastPathComponent)")
                allFrames.append(contentsOf: frames)

            } catch {
                log.error("detectAll: failed for \(url.lastPathComponent) — \(error.localizedDescription)")
                failedFiles.append(url.lastPathComponent)
                statusMessage = "Error: \(error.localizedDescription)"
            }
        }

        guard !isCancelled else { return }

        progress = 1.0
        statusMessage = "\(allFrames.count) frame\(allFrames.count == 1 ? "" : "s") found across \(fileURLs.count - failedFiles.count) scan\(fileURLs.count - failedFiles.count == 1 ? "" : "s")."
        log.info("detectAll: complete — \(allFrames.count) total frames")

        try? await Task.sleep(nanoseconds: 350_000_000)
        if !isCancelled { onComplete(allFrames) }
    }

    // MARK: - Thumbnail helper

    /// Crops `rect` from `image` and downsamples to a display-safe thumbnail.
    static func thumbnail(from image: CGImage, rect: CGRect, maxDimension: Int = 320) -> NSImage? {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clampedRect = rect.intersection(imageBounds)
        guard !clampedRect.isNull, clampedRect.width > 4, clampedRect.height > 4 else { return nil }
        guard let cropped = image.cropping(to: clampedRect),
              cropped.width > 0, cropped.height > 0 else { return nil }
        let w = cropped.width, h = cropped.height
        let scale = w <= maxDimension && h <= maxDimension
            ? 1.0
            : Double(maxDimension) / Double(max(w, h))
        let nw = max(1, Int(Double(w) * scale))
        let nh = max(1, Int(Double(h) * scale))
        // Always use sRGB — source images may be grayscale (Epson TIFF), which is incompatible
        // with noneSkipLast | byteOrder32Big (a 4-bytes/pixel format requiring 3 channels).
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo) else { return nil }
        // CGBitmapContext on macOS uses y-up by default. Apply a flip so y=0 is at the
        // visual top, matching CGImage raster order and preventing upside-down output.
        ctx.translateBy(x: 0, y: CGFloat(nh))
        ctx.scaleBy(x: 1.0, y: -1.0)
        ctx.interpolationQuality = .medium
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let result = ctx.makeImage() else { return nil }
        return NSImage(cgImage: result, size: NSSize(width: nw, height: nh))
    }
}
