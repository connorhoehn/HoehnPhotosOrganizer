import XCTest
@testable import HoehnPhotosOrganizer

/// Verifies that `ImageAdjustmentService.applyAdjustments(to:adjustments:db:)` returns
/// an `ApplyResult` that surfaces per-photo failures instead of swallowing them.
/// Two photos are routed to a writable temp directory (success). A third points at
/// `/this/path/does/not/exist/...` so the XMP sidecar write throws.
final class ImageAdjustmentServiceResultTests: XCTestCase {
    var db: AppDatabase!
    var service: ImageAdjustmentService!
    var workDir: URL!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        service = ImageAdjustmentService()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir = workDir {
            try? FileManager.default.removeItem(at: dir)
        }
        workDir = nil
        service = nil
        db = nil
    }

    func testApplyAdjustmentsSurfacesPerPhotoFailures() async throws {
        // Two photos with valid (writable) parent directories — sidecars will be
        // created successfully alongside these paths.
        let okOnePath = workDir.appendingPathComponent("ok_one.dng").path
        let okTwoPath = workDir.appendingPathComponent("ok_two.dng").path

        // One photo whose parent directory does not exist — XMPSidecarService will
        // fail to write the sidecar, surfacing the failure in ApplyResult.failures.
        let badPath = "/this/path/definitely/does/not/exist/\(UUID().uuidString)/bad.dng"

        let okOne = PhotoAsset.new(canonicalName: "ok_one.dng",
                                   role: .original,
                                   filePath: okOnePath,
                                   fileSize: 0)
        let okTwo = PhotoAsset.new(canonicalName: "ok_two.dng",
                                   role: .original,
                                   filePath: okTwoPath,
                                   fileSize: 0)
        let bad = PhotoAsset.new(canonicalName: "bad.dng",
                                 role: .original,
                                 filePath: badPath,
                                 fileSize: 0)

        let adjustments: [ImageAdjustment] = [
            .levels(blacks: 0, whites: 0, shadows: 0, highlights: 0, exposure: 0.5)
        ]

        let result = try await service.applyAdjustments(
            to: [okOne, okTwo, bad],
            adjustments: adjustments,
            db: db
        )

        XCTAssertEqual(result.successCount, 2,
                       "Two photos with valid paths should succeed")
        XCTAssertEqual(result.failures.count, 1,
                       "One photo with an invalid path should be surfaced as a failure")

        let failingNames = result.failures.map { $0.photo.canonicalName }
        XCTAssertTrue(failingNames.contains("bad.dng"),
                      "The failing photo's canonicalName must be present in the failures list")
        XCTAssertFalse(failingNames.contains("ok_one.dng"),
                       "A successful photo must NOT appear in the failures list")
        XCTAssertFalse(failingNames.contains("ok_two.dng"),
                       "A successful photo must NOT appear in the failures list")

        // Sanity: each failure carries a non-empty error string.
        for failure in result.failures {
            XCTAssertFalse(failure.error.isEmpty,
                           "Failure entries must include a non-empty error message")
        }
    }
}
