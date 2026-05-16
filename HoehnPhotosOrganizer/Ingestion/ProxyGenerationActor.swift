import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// MARK: - Progress

struct ProxyGenerationProgress: Sendable {
    let total: Int
    let completed: Int
    let failed: Int
}

// MARK: - Actor

actor ProxyGenerationActor {
    private let photoRepo: PhotoRepository
    private let proxyRepo: ProxyAssetRepository
    private let embeddingRepo: EmbeddingRepository?
    private let appDatabase: AppDatabase?
    private let clipService = MobileCLIPService()
    private let orientationClassifier = OrientationClassificationService()

    init(
        photoRepo: PhotoRepository,
        proxyRepo: ProxyAssetRepository,
        embeddingRepo: EmbeddingRepository? = nil,
        appDatabase: AppDatabase? = nil
    ) {
        self.photoRepo = photoRepo
        self.proxyRepo = proxyRepo
        self.embeddingRepo = embeddingRepo
        self.appDatabase = appDatabase
    }

    // MARK: - Public API

    /// Processes all PhotoAssets with processingState = proxyPending.
    /// Yields ProxyGenerationProgress after each asset is handled.
    /// - Parameters:
    ///   - driveMount: The root URL of the mounted drive.
    ///     Each PhotoAsset.filePath is appended to this URL to resolve the source file.
    ///     Absolute paths (local imports, film frame exports) are used as-is regardless.
    ///   - driveUUID: Optional volume UUID to stamp on each processed asset's source_drive_uuid.
    nonisolated func processQueue(driveMount: URL, driveUUID: String? = nil) -> AsyncStream<ProxyGenerationProgress> {
        AsyncStream { continuation in
            Task {
                await self.run(driveMount: driveMount, driveUUID: driveUUID, continuation: continuation)
                continuation.finish()
            }
        }
    }

    /// Convenience overload for locally-imported files where all filePaths are absolute.
    /// Uses the filesystem root as the nominal drive mount.
    nonisolated func processLocalQueue() -> AsyncStream<ProxyGenerationProgress> {
        processQueue(driveMount: URL(fileURLWithPath: "/"))
    }

    // MARK: - Private processing loop

    // Batch size for paginated proxyPending fetches. Caps peak RAM at ~1000 PhotoAsset rows
    // instead of loading the entire pending queue (~100 MB at 100k scale).
    private static let pageBatchSize = 1_000

    private func run(
        driveMount: URL,
        driveUUID: String? = nil,
        continuation: AsyncStream<ProxyGenerationProgress>.Continuation
    ) async {
        let total = (try? await photoRepo.fetchCountByProcessingState(.proxyPending)) ?? 0
        var completed = 0
        var failed = 0
        var processedIds: Set<String> = []

        let proxiesDir = Self.proxiesDirectory()

        // All per-photo writes funnel through this batcher so 1000 photos cost ~10 transactions
        // instead of ~6000. nil when called without an AppDatabase (legacy frame-extraction
        // callers) — falls back to per-write paths via the repos.
        let batcher: PhotoProcessingBatcher? = appDatabase.map { PhotoProcessingBatcher(db: $0) }
        defer {
            // Drain on any control-flow exit — best-effort because we can't `try await` in defer.
            if let b = batcher { Task { try? await b.flush() } }
        }

        while true {
            let batch = (try? await photoRepo.fetchByProcessingState(.proxyPending, limit: Self.pageBatchSize)) ?? []
            let unprocessed = batch.filter { !processedIds.contains($0.id) }
            if unprocessed.isEmpty { break }

        for asset in unprocessed {
            processedIds.insert(asset.id)
            // Absolute paths (local imports, film frame exports) are used as-is;
            // relative paths are resolved against the drive mount.
            let sourceURL: URL
            if asset.filePath.hasPrefix("/") {
                sourceURL = URL(fileURLWithPath: asset.filePath)
            } else {
                sourceURL = driveMount.appendingPathComponent(asset.filePath)
            }
            // Use canonicalName (camera filename) as the output filename
            let baseName = (asset.canonicalName as NSString).deletingPathExtension
            let outFilename = baseName + ".jpg"
            let outURL = proxiesDir.appendingPathComponent(outFilename)

            do {
                // Redeem security-scoped bookmark so access works after app restarts
                let scopeURL = await BookmarkStore.shared.startAccess(for: sourceURL)
                defer { scopeURL?.stopAccessingSecurityScopedResource() }

                let (cgImage, width, height) = try generateProxy(from: sourceURL)
                try writeJPEG(cgImage, to: outURL)

                let attrs = try? FileManager.default.attributesOfItem(atPath: outURL.path)
                let byteSize = (attrs?[.size] as? Int) ?? 0

                // PRX-10: 300 px thumbnail pass — second Core Image pass reusing same CGImageSource
                let thumbsDir = Self.thumbsDirectory()
                let thumbURL = thumbsDir.appendingPathComponent(outFilename) // same filename, separate dir
                var thumbnailPath: String? = nil
                var thumbnailByteSize: Int? = nil
                if let (thumbImage, _, _) = try? generateThumbnail(from: sourceURL) {
                    try? writeJPEG(thumbImage, to: thumbURL)
                    let thumbAttrs = try? FileManager.default.attributesOfItem(atPath: thumbURL.path)
                    thumbnailPath = thumbURL.path
                    thumbnailByteSize = (thumbAttrs?[.size] as? Int) ?? 0
                }

                let proxyAsset = ProxyAsset(
                    id: UUID().uuidString,
                    photoId: asset.id,
                    filePath: outURL.path,
                    width: width,
                    height: height,
                    byteSize: byteSize,
                    thumbnailPath: thumbnailPath,
                    thumbnailByteSize: thumbnailByteSize,
                    createdAt: ISO8601DateFormatter().string(from: .now)
                )
                if let batcher {
                    try await batcher.appendProxyAsset(proxyAsset)
                    try await batcher.appendProcessingState(id: asset.id, state: .proxyReady)
                    try await batcher.appendProxyFields(
                        id: asset.id,
                        proxyPath: outURL.path,
                        sourceDriveUUID: driveUUID,
                        sourceDrivePath: asset.filePath
                    )
                } else {
                    try await proxyRepo.upsert(proxyAsset)
                    try await photoRepo.updateProcessingState(id: asset.id, state: .proxyReady)
                    try await photoRepo.stampProxyFields(
                        id: asset.id,
                        proxyPath: outURL.path,
                        sourceDriveUUID: driveUUID,
                        sourceDrivePath: asset.filePath
                    )
                }

                // MobileCLIP image embedding — best-effort, failure does not block import
                if let repo = embeddingRepo {
                    do {
                        let vec = try await clipService.encodeImage(cgImage)
                        let normalised = clipService.normalise(vec)
                        if let batcher {
                            try await batcher.appendClipEmbedding(photoAssetId: asset.id, embedding: normalised)
                        } else {
                            try await repo.storeEmbedding(photoAssetId: asset.id, embedding: normalised)
                        }
                        print("[MobileCLIP] ✓ embedded \(asset.id)")
                    } catch {
                        print("[MobileCLIP] ✗ \(asset.id): \(error.localizedDescription)")
                    }
                }

                // Auto-orient: classify against the in-memory cgImage we already decoded
                // (skips the extra disk read the old proxyURL: variant did).
                let orientResult = await orientationClassifier.classify(cgImage: cgImage)
                if orientResult.rotationDegrees != 0 {
                    Self.applyRotationToFile(orientResult.rotationDegrees, url: outURL)
                    Self.applyRotationToFile(orientResult.rotationDegrees, url: thumbURL)
                    if let batcher {
                        try await batcher.appendTouchUpdatedAt(id: asset.id)
                    } else {
                        try? await photoRepo.touchUpdatedAt(id: asset.id)
                    }
                    print("[AutoOrient] \(asset.canonicalName): \(orientResult.rotationDegrees)°CW via \(orientResult.method)")
                }

                completed += 1
            } catch {
                if let batcher {
                    try? await batcher.appendProcessingState(
                        id: asset.id,
                        state: .proxyPending,
                        errorMessage: error.localizedDescription
                    )
                } else {
                    try? await photoRepo.updateProcessingState(
                        id: asset.id,
                        state: .proxyPending,
                        errorMessage: error.localizedDescription
                    )
                }
                failed += 1
            }

            continuation.yield(ProxyGenerationProgress(total: total, completed: completed, failed: failed))
        }
        } // end while true

        // Commit the trailing batch before returning so the caller's "isGeneratingProxies = false"
        // doesn't beat the last writes to the DB.
        if let batcher { try? await batcher.flush() }
    }

    // MARK: - Thumbnail generation (PRX-10)

    /// Returns (CGImage, width, height) at longest edge ≤ 300 px.
    ///
    /// Reuses the same CGImageSource thumbnail extraction path as generateProxy but
    /// with kCGImageSourceThumbnailMaxPixelSize = 300. This is the fast path — avoids
    /// full CIImage decode of the source file.
    private func generateThumbnail(from url: URL) throws -> (CGImage, Int, Int) {
        let isDNG = url.pathExtension.lowercased() == "dng"
        // Try without TIFF hint first (real camera DNGs); retry with hint for TIFF-as-DNG exports.
        let candidates: [CFDictionary?] = isDNG
            ? [nil, [kCGImageSourceTypeIdentifierHint: UTType.tiff.identifier] as CFDictionary]
            : [nil]
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: 300
        ]
        for sourceOpts in candidates {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOpts) else { continue }
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { continue }
            if let converted = ensure8BitRGBA(thumb) {
                return (converted, converted.width, converted.height)
            }
            return (thumb, thumb.width, thumb.height)
        }
        throw NSError(
            domain: "ProxyGeneration", code: 11,
            userInfo: [NSLocalizedDescriptionKey: "Thumbnail extraction failed: \(url.lastPathComponent)"]
        )
    }

    // MARK: - Proxy generation

    /// Returns (CGImage, width, height) at longest edge ≤ 1600 px.
    ///
    /// Strategy:
    /// 1. Try CGImageSourceCreateThumbnailAtIndex — extracts the embedded preview
    ///    already baked into RAW/DNG files (fast path, PRX-5).
    /// 2. Fall back to CIImage full decode + CILanczosScaleTransform.
    ///
    /// IMPORTANT: All returned CGImages are converted to 8-bit RGBA to ensure
    /// proper JPEG export. This is critical for 16-bit grayscale TIFFs (film scans)
    /// which would otherwise render as pure black.
    private func generateProxy(from url: URL) throws -> (CGImage, Int, Int) {
        let isDNG = url.pathExtension.lowercased() == "dng"
        // TIFF hint is needed for our MinimalDNGWriter exports (TIFF bytes in a .dng wrapper).
        // Real camera DNGs work WITHOUT the hint — try without first, then retry with hint.
        let sourceOptsList: [CFDictionary?] = isDNG
            ? [nil, [kCGImageSourceTypeIdentifierHint: UTType.tiff.identifier] as CFDictionary]
            : [nil]

        // Always decode from the full image — never use the tiny embedded EXIF thumbnail
        // that cameras bake into JPEGs. kCGImageSourceCreateThumbnailFromImageIfAbsent
        // would return a 160 px thumbnail scaled up to 2400 px, producing a blurry proxy.
        // kCGImageSourceCreateThumbnailFromImageAlways forces a full decode every time.
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 2400
        ]
        let imgOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]

        for sourceOpts in sourceOptsList {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOpts) else { continue }

            // Path 1: fast thumbnail extraction (uses embedded JPEG preview for camera DNGs)
            if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
                if let converted = ensure8BitRGBA(thumb) {
                    return (converted, converted.width, converted.height)
                }
                return (thumb, thumb.width, thumb.height)
            }

            // Path 1b: thumbnail failed — decode full image and scale
            if let cgImg = CGImageSourceCreateImageAtIndex(source, 0, imgOptions as CFDictionary),
               let converted = ensure8BitRGBA(cgImg) {
                let (w, h) = scaledDimensions(CGFloat(converted.width), CGFloat(converted.height), maxEdge: 1600)
                if w == converted.width && h == converted.height {
                    return (converted, w, h)
                }
                let ci = CIImage(cgImage: converted)
                let scale = Double(max(w, h)) / Double(max(converted.width, converted.height))
                let f = CIFilter(name: "CILanczosScaleTransform")!
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(scale, forKey: kCIInputScaleKey)
                f.setValue(1.0, forKey: "inputAspectRatio")
                if let out = f.outputImage,
                   let scaled = Self.makeCIContext().createCGImage(out, from: out.extent, format: .RGBA8,
                                                                   colorSpace: CGColorSpaceCreateDeviceRGB()) {
                    return (scaled, scaled.width, scaled.height)
                }
                return (converted, converted.width, converted.height)
            }
        }

        // Path 2: full CIImage decode + Lanczos scale (non-DNG files, or DNG fallback)
        guard let ciImage = CIImage(contentsOf: url) else {
            throw NSError(
                domain: "ProxyGeneration", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot decode \(url.lastPathComponent)"]
            )
        }

        let (w, h) = scaledDimensions(ciImage.extent.width, ciImage.extent.height, maxEdge: 1600)
        let scaleFilter = CIFilter(name: "CILanczosScaleTransform")!
        let scale = Double(max(w, h)) / Double(max(ciImage.extent.width, ciImage.extent.height))
        scaleFilter.setValue(ciImage, forKey: kCIInputImageKey)
        scaleFilter.setValue(scale, forKey: kCIInputScaleKey)
        scaleFilter.setValue(1.0, forKey: "inputAspectRatio")

        guard let output = scaleFilter.outputImage else {
            throw NSError(
                domain: "ProxyGeneration", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Scale filter failed for \(url.lastPathComponent)"]
            )
        }

        // Explicitly create 8-bit RGBA for safe JPEG export.
        // Self.makeCIContext() prefers GPU but falls back to software rendering when
        // IOSurface allocation fails (e.g. during concurrent import of large files).
        guard let cgImage = Self.makeCIContext().createCGImage(output, from: output.extent, format: .RGBA8,
                                                               colorSpace: CGColorSpaceCreateDeviceRGB()) else {
            throw NSError(
                domain: "ProxyGeneration", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "CGImage creation failed for \(url.lastPathComponent)"]
            )
        }
        return (cgImage, cgImage.width, cgImage.height)
    }

    /// Converts a CGImage to 8-bit RGBA if needed.
    /// Returns nil if conversion fails, or the image unchanged if already 8-bit RGBA.
    private func ensure8BitRGBA(_ image: CGImage) -> CGImage? {
        // If already 8-bit RGBA, return as-is
        if image.bitsPerComponent == 8 && image.bitsPerPixel == 32 {
            return image
        }

        // Create a context to convert to 8-bit RGBA
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw NSError(
                domain: "ProxyGeneration", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Cannot create JPEG destination at \(url.lastPathComponent)"]
            )
        }
        let props = [kCGImageDestinationLossyCompressionQuality: 0.90] as CFDictionary
        CGImageDestinationAddImage(dest, image, props)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(
                domain: "ProxyGeneration", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "JPEG finalization failed for \(url.lastPathComponent)"]
            )
        }
    }

    // MARK: - CIContext factory

    /// Shared CIContext used for every proxy decode in this actor instance.
    ///
    /// Previously this was constructed once **per image** (called inside
    /// `generateProxy`), which on a 100K-photo import meant 100K CIContext
    /// allocations — each holds non-trivial internal state (render queues, color
    /// space caches). One context can safely serve every render here because
    /// CIContext is thread-safe and the work is CPU-only (no GPU IOSurface).
    ///
    /// Rendering to CPU memory avoids the IOSurface failures that occur when
    /// multiple large files are decoded concurrently during import.
    private static let sharedCIContext: CIContext = CIContext(options: [
        .useSoftwareRenderer: true,
        .outputColorSpace: CGColorSpaceCreateDeviceRGB() as Any
    ])

    private static func makeCIContext() -> CIContext { sharedCIContext }

    // MARK: - Scaling helpers

    private func scaledDimensions(_ w: CGFloat, _ h: CGFloat, maxEdge: Int) -> (Int, Int) {
        let scale = Double(maxEdge) / Double(max(w, h))
        if scale >= 1 { return (Int(w), Int(h)) }
        return (max(1, Int(w * scale)), max(1, Int(h * scale)))
    }

    // MARK: - Directory

    /// Returns the proxies directory inside Application Support, creating it if needed.
    /// Path: ~/Library/Application Support/HoehnPhotosOrganizer/proxies/
    static func proxiesDirectory() -> URL {
        let fm = FileManager.default
        // swiftlint:disable:next force_try
        let appSupport = try! fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = appSupport
            .appendingPathComponent("HoehnPhotosOrganizer", isDirectory: true)
            .appendingPathComponent("proxies", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Returns the thumbs subdirectory inside the proxies directory, creating it if needed.
    /// Path: ~/Library/Application Support/HoehnPhotosOrganizer/proxies/thumbs/
    ///
    /// Thumbnails are stored in a separate subdirectory from full proxies to prevent
    /// filename collisions: both use {canonicalName}.jpg but live in different directories (Pitfall 4).
    static func thumbsDirectory() -> URL {
        let thumbs = proxiesDirectory().appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
        return thumbs
    }

    /// Returns the originals directory inside Application Support, creating it if needed.
    /// Path: ~/Library/Application Support/HoehnPhotosOrganizer/originals/
    static func originalsDirectory() -> URL {
        let fm = FileManager.default
        let appSupport = try! fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = appSupport
            .appendingPathComponent("HoehnPhotosOrganizer", isDirectory: true)
            .appendingPathComponent("originals", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Physically rotate a JPEG file by `degrees` clockwise in place.
    /// Runs synchronously — call from within an actor or detached task.
    static func applyRotationToFile(_ degrees: Int, url: URL) {
        guard FileManager.default.fileExists(atPath: url.path),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg  = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }

        let srcW = cg.width, srcH = cg.height
        let (dstW, dstH) = degrees == 180 ? (srcW, srcH) : (srcH, srcW)

        guard let cs  = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: dstW, height: dstH,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return }

        switch degrees {
        case 90:
            ctx.translateBy(x: 0, y: CGFloat(dstH))
            ctx.rotate(by: -.pi / 2)
        case 180:
            ctx.translateBy(x: CGFloat(dstW), y: CGFloat(dstH))
            ctx.rotate(by: .pi)
        case 270:
            ctx.translateBy(x: CGFloat(dstW), y: 0)
            ctx.rotate(by: .pi / 2)
        default:
            return
        }

        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(srcW), height: CGFloat(srcH)))

        guard let rotated = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(
                  url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
              ) else { return }
        CGImageDestinationAddImage(dest, rotated,
            [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
