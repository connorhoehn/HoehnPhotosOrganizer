import CoreGraphics
import Foundation

// MARK: - FaceGalleryRecord

/// A denormalized view of a face embedding, bundling photo and person info
/// so the gallery view doesn't need to make per-cell DB round-trips.
struct FaceGalleryRecord: Identifiable, Sendable {
    let embedding: FaceEmbedding
    let canonicalName: String  // photo_assets.canonical_name
    let personName: String?    // person_identities.name, or nil if unlabeled

    var id: String { embedding.id }

    var proxyURL: URL {
        let base = (canonicalName as NSString).deletingPathExtension
        return ProxyGenerationActor.proxiesDirectory()
            .appendingPathComponent(base + ".jpg")
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
