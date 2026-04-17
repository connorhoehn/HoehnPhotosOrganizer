import UIKit
import Vision
import ImageIO
import HoehnPhotosCore

// MARK: - cropFaceFromProxy

/// Crop a face region from a proxy JPEG using Vision-normalized bbox coordinates.
/// bbox uses Vision coordinate system: origin at bottom-left, normalized 0-1.
func cropFaceFromProxy(proxyURL: URL, bbox: CGRect) -> UIImage? {
    let thumbOpts: [CFString: Any] = [
        kCGImageSourceShouldCache: false,
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 400,
        kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard let src = CGImageSourceCreateWithURL(proxyURL as CFURL, nil),
          let cgImage = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary)
    else { return nil }

    let imgW = CGFloat(cgImage.width)
    let imgH = CGFloat(cgImage.height)
    // Vision bbox: origin bottom-left, normalized — convert to pixel rect
    let pixelRect = VNImageRectForNormalizedRect(bbox, Int(imgW), Int(imgH))
    // Flip Y: Vision origin is bottom-left, CGImage origin is top-left
    let flippedY = imgH - pixelRect.maxY
    // Add 25% padding around the face for context
    let padX = pixelRect.width * 0.25
    let padY = pixelRect.height * 0.25
    let padded = CGRect(
        x: pixelRect.minX - padX, y: flippedY - padY,
        width: pixelRect.width + padX * 2, height: pixelRect.height + padY * 2
    ).intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))
    guard padded.width > 0, padded.height > 0,
          let cropped = cgImage.cropping(to: padded) else { return nil }
    return UIImage(cgImage: cropped)
}

// MARK: - FaceCropCache

/// LRU cache for cropped face thumbnails. Max 200 entries.
/// Uses Swift concurrency actor isolation for thread safety.
actor FaceCropCache {
    static let shared = FaceCropCache()

    private var cache: [String: UIImage] = [:]
    private var accessOrder: [String] = []
    private let maxEntries = 200

    /// Returns a cached crop or loads it from the proxy JPEG and crops it.
    /// - Parameters:
    ///   - id: The face embedding ID used as cache key
    ///   - proxyURL: URL to the proxy JPEG on disk
    ///   - bbox: Vision-normalized bounding box (origin bottom-left, 0-1 range)
    func crop(id: String, proxyURL: URL, bbox: CGRect) async -> UIImage? {
        if let cached = cache[id] {
            // Move to end of access order (most recently used)
            if let idx = accessOrder.firstIndex(of: id) {
                accessOrder.remove(at: idx)
                accessOrder.append(id)
            }
            return cached
        }
        // Perform crop off the main thread
        let result = await Task.detached(priority: .utility) {
            cropFaceFromProxy(proxyURL: proxyURL, bbox: bbox)
        }.value
        if let result {
            store(id: id, image: result)
        }
        return result
    }

    private func store(id: String, image: UIImage) {
        // Evict oldest entry if at capacity (LRU eviction)
        if cache.count >= maxEntries, let oldest = accessOrder.first {
            cache.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }
        cache[id] = image
        accessOrder.append(id)
    }
}

// MARK: - FaceEmbedding + bboxRect

extension FaceEmbedding {
    /// Convenience CGRect from the scalar bbox fields.
    /// Coordinates are Vision-normalized (origin bottom-left, 0-1 range).
    var bboxRect: CGRect {
        CGRect(x: bboxX, y: bboxY, width: bboxWidth, height: bboxHeight)
    }
}
