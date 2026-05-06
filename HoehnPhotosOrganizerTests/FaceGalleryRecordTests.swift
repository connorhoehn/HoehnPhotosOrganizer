import CoreGraphics
import Testing
@testable import HoehnPhotosOrganizer

struct FaceGalleryRecordTests {

    private func makeEmbedding(
        personId: String? = nil,
        needsReview: Bool = false,
        labeledBy: String? = nil,
        bboxX: Double = 0.1, bboxY: Double = 0.2,
        bboxWidth: Double = 0.3, bboxHeight: Double = 0.25
    ) -> FaceEmbedding {
        FaceEmbedding(
            id: UUID().uuidString,
            photoId: "photo-1",
            faceIndex: 0,
            bboxX: bboxX, bboxY: bboxY,
            bboxWidth: bboxWidth, bboxHeight: bboxHeight,
            featureData: nil,
            createdAt: ISO8601DateFormatter().string(from: .now),
            personId: personId,
            labeledBy: labeledBy,
            needsReview: needsReview
        )
    }

    private func makeRecord(embedding: FaceEmbedding) -> FaceGalleryRecord {
        FaceGalleryRecord(embedding: embedding, canonicalName: "IMG_001.NEF", personName: nil)
    }

    // MARK: - bbox

    @Test
    func testBboxConstructsCGRectFromEmbeddingCoordinates() {
        let emb = makeEmbedding(bboxX: 0.1, bboxY: 0.2, bboxWidth: 0.3, bboxHeight: 0.25)
        let record = makeRecord(embedding: emb)
        let box = record.bbox
        #expect(abs(box.origin.x - 0.1)  < 1e-9)
        #expect(abs(box.origin.y - 0.2)  < 1e-9)
        #expect(abs(box.size.width - 0.3)   < 1e-9)
        #expect(abs(box.size.height - 0.25) < 1e-9)
    }

    // MARK: - isLabeled

    @Test
    func testIsLabeledReturnsTrueWhenPersonIdSetAndNotNeedsReview() {
        let record = makeRecord(embedding: makeEmbedding(personId: "p1", needsReview: false))
        #expect(record.isLabeled == true,
                "isLabeled must be true when personId is set and needsReview is false")
    }

    @Test
    func testIsLabeledReturnsFalseWhenPersonIdIsNil() {
        let record = makeRecord(embedding: makeEmbedding(personId: nil, needsReview: false))
        #expect(record.isLabeled == false,
                "isLabeled must be false when personId is nil")
    }

    @Test
    func testIsLabeledReturnsFalseWhenNeedsReviewIsTrue() {
        // Tentative assignment: personId set but awaiting Claude review
        let record = makeRecord(embedding: makeEmbedding(personId: "p1", needsReview: true))
        #expect(record.isLabeled == false,
                "isLabeled must be false when the assignment is pending review")
    }

    // MARK: - labeledBy

    @Test
    func testLabeledByForwardsEmbeddingValue() {
        let record = makeRecord(embedding: makeEmbedding(personId: "p1", needsReview: false, labeledBy: "user"))
        #expect(record.labeledBy == "user",
                "labeledBy must forward the embedding's labeledBy value")
    }
}
