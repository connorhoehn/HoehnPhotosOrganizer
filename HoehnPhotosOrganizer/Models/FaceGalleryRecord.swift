import CoreGraphics
import Foundation

// MARK: - FaceGalleryRecord

/// A denormalized view of a face embedding, bundling photo and person info
/// so the gallery view doesn't need to make per-cell DB round-trips.
struct FaceGalleryRecord: Identifiable, Sendable {
    let embedding: FaceEmbedding
    let canonicalName: String  // photo_assets.canonical_name
    let personName: String?    // person_identities.name, or nil if unlabeled
    /// Absolute path to the photo's original source file. Optional because legacy DB
    /// rows may have been imported before file_path was reliably populated; in that
    /// case FaceCropCache falls back to the proxy.
    let filePath: String?

    var id: String { embedding.id }

    var proxyURL: URL {
        let base = (canonicalName as NSString).deletingPathExtension
        return ProxyGenerationActor.proxiesDirectory()
            .appendingPathComponent(base + ".jpg")
    }

    /// URL of the original photo on disk, or nil if file_path is missing.
    /// Used by FaceChipStore to crop face chips from the highest-resolution source.
    var sourceURL: URL? {
        filePath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    var bbox: CGRect {
        CGRect(
            x: embedding.bboxX,
            y: embedding.bboxY,
            width: embedding.bboxWidth,
            height: embedding.bboxHeight
        )
    }

    var isLabeled: Bool { embedding.personId != nil && !embedding.needsReview }
    var needsReview: Bool { embedding.needsReview }
    var labeledBy: String? { embedding.labeledBy }
}
