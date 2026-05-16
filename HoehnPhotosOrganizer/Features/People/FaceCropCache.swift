import AppKit
import ImageIO

// MARK: - FaceCropCache

/// In-memory cache layered over `FaceChipStore`'s on-disk JPEGs.
///
/// Three-tier lookup on `crop(...)`:
///   1. NSCache hit → return immediately.
///   2. On-disk chip JPEG exists (the common case for any face viewed before) →
///      load it, cache it, return.
///   3. No chip yet → generate one via `FaceChipStore` from the highest-res source
///      available (original > proxy), persist it, cache it, return.
///
/// The cache stores fully-decoded NSImages keyed by `face_embedding.id`, with a
/// small entry cap to keep resident memory bounded for huge people galleries.
final class FaceCropCache: Sendable {

    static let shared = FaceCropCache()

    /// Thread-safe by contract from Foundation.
    private nonisolated(unsafe) let cache = NSCache<NSString, NSImage>()

    /// Caps concurrent disk reads + chip-generation work. Six is enough to keep a
    /// gallery scroll smooth without thrashing the I/O queue.
    private let semaphore = DispatchSemaphore(value: 6)

    private init() {
        // Each cached crop is ~512 px max edge → ~200–400 KB resident as NSImage.
        // 200 entries ≈ 40–80 MB worst case, which is fine on any Mac that runs the app.
        cache.countLimit = 200
    }

    /// Returns a sharp face crop for the given face id.
    ///
    /// - Parameters:
    ///   - faceId: `face_embeddings.id` — used as the chip filename.
    ///   - sourceURL: the photo's original file (highest resolution). Pass nil if not
    ///     available; the proxy will be used instead.
    ///   - proxyURL: the photo's 1600 px JPEG proxy. Always required as the fallback.
    ///   - bbox: Vision-style normalized bounding box (origin bottom-left, 0…1).
    func crop(faceId: String, sourceURL: URL?, proxyURL: URL, bbox: CGRect) async -> NSImage? {
        let key = faceId as NSString

        if let cached = cache.object(forKey: key) { return cached }

        // Explicit `() -> NSImage?` so the compiler doesn't infer non-optional
        // from the happy paths and reject `return nil` on the miss path.
        let img: NSImage? = await Task.detached(priority: .utility) { [semaphore] () -> NSImage? in
            semaphore.wait()
            defer { semaphore.signal() }

            // Tier 2: chip exists on disk — just load it.
            let chipURL = FaceChipStore.chipURL(faceId: faceId)
            if FaceChipStore.chipExists(faceId: faceId) {
                if let img = NSImage(contentsOf: chipURL) { return img }
                // Stale/empty file — fall through to regeneration.
            }

            // Tier 3: generate, persist, and return. Prefers source → proxy.
            guard let cg = FaceChipStore.generateChip(
                faceId: faceId,
                sourceURL: sourceURL,
                proxyURL: proxyURL,
                bbox: bbox
            ) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value

        if let img { cache.setObject(img, forKey: key) }
        return img
    }

    /// Evict a specific entry — call after a face is re-indexed (new id) or its chip
    /// is regenerated. Does not delete the on-disk chip; pair with
    /// `FaceChipStore.deleteChips` if you also want the JPEG gone.
    func evict(faceId: String) {
        cache.removeObject(forKey: faceId as NSString)
    }

    /// Drop all in-memory entries. The on-disk store is unaffected.
    func evictAll() {
        cache.removeAllObjects()
    }
}
