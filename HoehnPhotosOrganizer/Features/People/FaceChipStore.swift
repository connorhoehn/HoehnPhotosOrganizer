import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// On-disk storage for cropped face thumbnails, keyed by `face_embedding.id`.
///
/// Faces in this app get *displayed* far more often than they get *indexed* — every
/// gallery scroll, every wizard step, every cluster card. Re-decoding the photo and
/// re-cropping on every access is wasteful, and proxy-based crops blur out badly when
/// the face is a small share of the frame. The chip store solves both:
///
/// 1. Crops are pre-rendered from the best available source (original file if local,
///    proxy otherwise) at a fixed 512 px max side.
/// 2. They live as plain JPEGs on disk → instant `NSImage(contentsOf:)`.
/// 3. The filename is deterministic (`{faceId}.jpg`) so the cache can check existence
///    via a single `fileExists` call without any DB or in-memory state.
///
/// Lifetime: chips are written when a face is indexed (eager) or first viewed (lazy
/// backfill), and deleted when their `face_embeddings` row is deleted. Orphan files
/// from crashes or aborted re-indexes are harmless until a future GC sweep.
enum FaceChipStore {

    /// 512 px max edge — sharp at 80–150 px chip sizes on retina (2× = 160–300 native px)
    /// without bloating disk. Typical encoded chip lands at 30–80 KB.
    static let targetMaxEdge: Int = 512

    /// JPEG quality. 0.85 keeps facial detail crisp without obvious chroma artefacts.
    static let jpegQuality: Double = 0.85

    /// Returns the directory holding face-chip JPEGs, creating it if needed.
    /// Path: `~/Library/Application Support/HoehnPhotosOrganizer/face-chips/`
    nonisolated static func chipsDirectory() -> URL {
        let fm = FileManager.default
        // swiftlint:disable:next force_try
        let appSupport = try! fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = appSupport
            .appendingPathComponent("HoehnPhotosOrganizer", isDirectory: true)
            .appendingPathComponent("face-chips", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Deterministic chip file path for a face embedding id.
    nonisolated static func chipURL(faceId: String) -> URL {
        chipsDirectory().appendingPathComponent("\(faceId).jpg")
    }

    /// True if a chip JPEG already exists on disk for this face.
    nonisolated static func chipExists(faceId: String) -> Bool {
        FileManager.default.fileExists(atPath: chipURL(faceId: faceId).path)
    }

    // MARK: - Generation

    /// Generate and persist a chip for a face from the best available source.
    ///
    /// Tries `sourceURL` first (original photo, typically highest resolution). Falls
    /// back to `proxyURL` when the source can't be opened — common when the original
    /// lives on an unmounted external drive.
    ///
    /// Returns the chip's CGImage on success so the caller can serve the in-flight
    /// generation without re-reading the JPEG it just wrote.
    @discardableResult
    nonisolated static func generateChip(
        faceId: String,
        sourceURL: URL?,
        proxyURL: URL,
        bbox: CGRect
    ) -> CGImage? {
        // Prefer original source for resolution; fall back to proxy.
        let candidate: URL? = {
            if let s = sourceURL, FileManager.default.fileExists(atPath: s.path) {
                return s
            }
            if FileManager.default.fileExists(atPath: proxyURL.path) {
                return proxyURL
            }
            return nil
        }()
        guard let imageURL = candidate else { return nil }

        // Decode at a size large enough that the face crop lands at >= targetMaxEdge,
        // regardless of how small the face is within the frame. If the face fills 10%
        // of the source width, we need source ≥ targetMaxEdge / 0.10 = 5120 px to land
        // at 512 px after cropping. Cap at 4096 px so we don't blow memory on a 100MP
        // landscape with a tiny face — a 4096 px decode still gives a clearly-readable
        // chip for any face wider than ~6% of the frame.
        let minBboxFraction = max(0.04, min(bbox.width, bbox.height))
        let desiredDecodeEdge = min(4096, max(1024, Int(Double(targetMaxEdge) / minBboxFraction)))

        let opts: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: desiredDecodeEdge,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, opts as CFDictionary),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary),
              let cropped = cropAndResize(cg, bbox: bbox, maxEdge: targetMaxEdge)
        else { return nil }

        // Persist as JPEG. Best-effort: if the write fails (disk full, permissions),
        // we still return the in-memory CGImage so the user sees a face.
        let outURL = chipURL(faceId: faceId)
        if let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            let props = [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
            CGImageDestinationAddImage(dest, cropped, props)
            _ = CGImageDestinationFinalize(dest)
        }
        return cropped
    }

    // MARK: - Deletion

    /// Best-effort cleanup. Used when a face row is removed (per-photo, per-job, or
    /// full re-index). Missing files are not an error.
    nonisolated static func deleteChips(faceIds: [String]) {
        let fm = FileManager.default
        for id in faceIds {
            try? fm.removeItem(at: chipURL(faceId: id))
        }
    }

    nonisolated static func deleteAll() {
        let fm = FileManager.default
        let dir = chipsDirectory()
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in entries {
            try? fm.removeItem(at: url)
        }
    }

    /// Sweep the chips directory and delete any JPEG whose filename stem is *not* in
    /// `validFaceIds`. Used at app launch to clean up orphans left over from crashes,
    /// aborted re-indexes, or paths that bypass the normal deletion routines.
    ///
    /// Returns the number of files removed (0 in the steady state).
    @discardableResult
    nonisolated static func garbageCollectOrphans(validFaceIds: Set<String>) -> Int {
        let fm = FileManager.default
        let dir = chipsDirectory()
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return 0
        }
        var removed = 0
        for url in entries where url.pathExtension.lowercased() == "jpg" {
            let stem = url.deletingPathExtension().lastPathComponent
            if !validFaceIds.contains(stem) {
                try? fm.removeItem(at: url)
                removed += 1
            }
        }
        return removed
    }

    // MARK: - Internals

    /// Crops `bbox` (normalized Vision rect, origin bottom-left) from `image`, then
    /// scales the cropped region so its longest edge equals `maxEdge`.
    nonisolated private static func cropAndResize(_ image: CGImage, bbox: CGRect, maxEdge: Int) -> CGImage? {
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)

        let pixelRect = CGRect(
            x: bbox.minX * imgW,
            y: bbox.minY * imgH,
            width: bbox.width * imgW,
            height: bbox.height * imgH
        )
        let flippedY = imgH - pixelRect.maxY

        // 30% padding so we capture hair/chin rather than just the face oval — mirrors
        // FaceChipGrid's convention so chips look consistent.
        let padX = pixelRect.width * 0.30
        let padY = pixelRect.height * 0.30
        let padded = CGRect(
            x: pixelRect.minX - padX,
            y: flippedY - padY,
            width: pixelRect.width + padX * 2,
            height: pixelRect.height + padY * 2
        ).intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))

        guard padded.width > 0, padded.height > 0,
              let cropped = image.cropping(to: padded) else { return nil }

        let longest = max(cropped.width, cropped.height)
        if longest <= maxEdge { return cropped }

        let scale = CGFloat(maxEdge) / CGFloat(longest)
        let outW = max(1, Int(CGFloat(cropped.width) * scale))
        let outH = max(1, Int(CGFloat(cropped.height) * scale))

        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: outW, height: outH,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return cropped }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        return ctx.makeImage() ?? cropped
    }
}
