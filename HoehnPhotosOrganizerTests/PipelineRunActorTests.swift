import XCTest
import CoreImage
import ImageIO
import GRDB
@testable import HoehnPhotosOrganizer

final class PipelineRunActorTests: XCTestCase {

    var db: AppDatabase!
    var actor: PipelineRunActor!

    // Temp directory cleaned up after each test
    var tempDir: URL!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        actor = PipelineRunActor()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    /// Creates a minimal 100×100 red JPEG suitable as a proxy input fixture.
    private func makeProxyFixture(name: String = "fixture.jpg") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let ci = CIImage(color: CIColor(red: 0.8, green: 0.1, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(ci, from: ci.extent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw NSError(domain: "PipelineRunActorTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create fixture JPEG"])
        }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        CGImageDestinationFinalize(dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Fixture JPEG not written to \(url.path)")
        return url
    }

    /// Inserts a source PhotoAsset row and returns its ID.
    private func makeSourcePhoto(name: String = "source_001.jpg") async throws -> String {
        let asset = PhotoAsset.new(
            canonicalName: name,
            role: .original,
            filePath: "/fake/\(name)",
            fileSize: 1024
        )
        try await db.dbPool.write { try asset.insert($0) }
        return asset.id
    }

    /// Creates a single-step (grayscale) pipeline and returns its ID.
    private func makeGrayscalePipeline(sourcePhotoId: String) async throws -> String {
        let pipelineId = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: .now)
        let pipeline = PipelineDefinition(
            id: pipelineId,
            name: "Test Grayscale",
            purpose: PipelinePurpose.printPrep.rawValue,
            createdAt: now,
            updatedAt: now
        )
        let step = PipelineStep(
            id: UUID().uuidString,
            pipelineId: pipelineId,
            stepOrder: 0,
            stepType: PipelineStepType.grayscale.rawValue,
            paramsJson: nil
        )
        try await db.dbPool.write { db in
            try pipeline.insert(db)
            try step.insert(db)
        }
        return pipelineId
    }

    /// Runs the actor and waits for the progress stream to complete.
    private func runAndWait(
        pipelineId: String,
        sourcePhotoId: String,
        proxyURL: URL,
        outputDirectory: URL
    ) async -> String {
        let (runID, progress) = actor.run(
            pipelineId: pipelineId,
            sourcePhotoId: sourcePhotoId,
            proxyURL: proxyURL,
            outputDirectory: outputDirectory,
            db: db
        )
        // Drain the stream — this blocks until the detached Task finishes
        for await _ in progress { }
        return runID
    }

    // MARK: - Tests

    // PIPE-3, AST-4: Run creates a workflow_output role photo_assets row for the output image
    func testRunCreatesWorkflowOutputPhotoAssetRow() async throws {
        let proxyURL = try makeProxyFixture()
        let sourceId = try await makeSourcePhoto()
        let pipelineId = try await makeGrayscalePipeline(sourcePhotoId: sourceId)

        _ = await runAndWait(
            pipelineId: pipelineId,
            sourcePhotoId: sourceId,
            proxyURL: proxyURL,
            outputDirectory: tempDir
        )

        let outputAssets = try await db.dbPool.read { db in
            try PhotoAsset.filter(Column("role") == PhotoRole.workflowOutput.rawValue).fetchAll(db)
        }
        XCTAssertEqual(outputAssets.count, 1, "Expected exactly one workflowOutput PhotoAsset row")
    }

    // PIPE-3, AST-3: Run creates an asset_lineage row linking input to output
    func testRunCreatesAssetLineageRow() async throws {
        let proxyURL = try makeProxyFixture()
        let sourceId = try await makeSourcePhoto()
        let pipelineId = try await makeGrayscalePipeline(sourcePhotoId: sourceId)

        _ = await runAndWait(
            pipelineId: pipelineId,
            sourcePhotoId: sourceId,
            proxyURL: proxyURL,
            outputDirectory: tempDir
        )

        let lineageRows = try await db.dbPool.read { db in
            try AssetLineage
                .filter(Column("parent_photo_id") == sourceId)
                .filter(Column("operation") == "pipeline_run")
                .fetchAll(db)
        }
        XCTAssertEqual(lineageRows.count, 1, "Expected exactly one asset_lineage row")
        XCTAssertEqual(lineageRows.first?.parentPhotoId, sourceId)
    }

    // PIPE-5: Run record stores input params and start/end timestamps
    func testRunStoresParamsAndTimestamps() async throws {
        let proxyURL = try makeProxyFixture()
        let sourceId = try await makeSourcePhoto()
        let pipelineId = try await makeGrayscalePipeline(sourcePhotoId: sourceId)

        let runID = await runAndWait(
            pipelineId: pipelineId,
            sourcePhotoId: sourceId,
            proxyURL: proxyURL,
            outputDirectory: tempDir
        )

        let run = try await db.dbPool.read { db in
            try PipelineRun.fetchOne(db, key: runID)
        }
        XCTAssertNotNil(run, "PipelineRun row must exist")
        XCTAssertFalse(run!.startedAt.isEmpty, "startedAt must be set")
        XCTAssertNotNil(run!.completedAt, "completedAt must be set after run completes")
        XCTAssertEqual(run!.status, PipelineRunStatus.succeeded.rawValue)
    }

    // PIPE-5: Run stores per-step result entries
    func testRunStoresPerStepResult() async throws {
        let proxyURL = try makeProxyFixture()
        let sourceId = try await makeSourcePhoto()
        let pipelineId = try await makeGrayscalePipeline(sourcePhotoId: sourceId)

        let runID = await runAndWait(
            pipelineId: pipelineId,
            sourcePhotoId: sourceId,
            proxyURL: proxyURL,
            outputDirectory: tempDir
        )

        let stepRows = try await db.dbPool.read { db in
            try PipelineRunStep
                .filter(Column("run_id") == runID)
                .fetchAll(db)
        }
        // Pipeline has exactly 1 grayscale step
        XCTAssertEqual(stepRows.count, 1, "Expected one PipelineRunStep row per pipeline step")
        XCTAssertEqual(stepRows.first?.stepType, PipelineStepType.grayscale.rawValue)
        XCTAssertNotNil(stepRows.first?.completedAt, "Step completedAt must be set")
    }

    // PIPE-5: Run transitions status to 'succeeded' when all steps complete
    func testRunStatusTransitionsToSucceeded() async throws {
        let proxyURL = try makeProxyFixture()
        let sourceId = try await makeSourcePhoto()
        let pipelineId = try await makeGrayscalePipeline(sourcePhotoId: sourceId)

        let runID = await runAndWait(
            pipelineId: pipelineId,
            sourcePhotoId: sourceId,
            proxyURL: proxyURL,
            outputDirectory: tempDir
        )

        let run = try await db.dbPool.read { db in
            try PipelineRun.fetchOne(db, key: runID)
        }
        XCTAssertEqual(run?.status, PipelineRunStatus.succeeded.rawValue)
    }

    // PIPE-5: Run transitions status to 'failed' when a step throws an error
    // ValidationPreflightStep with an impossible minimumDPI triggers ValidationError.insufficientDPI
    func testRunStatusTransitionsToFailedOnStepError() async throws {
        let proxyURL = try makeProxyFixture()
        let sourceId = try await makeSourcePhoto()

        // Create a pipeline with a ValidationPreflightStep requiring 9999 DPI —
        // the fixture JPEG has no DPI metadata so defaults to 72, which fails the check.
        let pipelineId = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: .now)
        let pipeline = PipelineDefinition(
            id: pipelineId,
            name: "Impossible DPI Pipeline",
            purpose: PipelinePurpose.printPrep.rawValue,
            createdAt: now,
            updatedAt: now
        )
        // ValidationPreflightStep requires filePath param pointing to the actual file
        let paramsJson = try String(
            data: JSONEncoder().encode([
                "filePath": proxyURL.path,
                "minimumDPI": "9999"
            ]),
            encoding: .utf8
        )!
        let step = PipelineStep(
            id: UUID().uuidString,
            pipelineId: pipelineId,
            stepOrder: 0,
            stepType: PipelineStepType.validationPreflight.rawValue,
            paramsJson: paramsJson
        )
        try await db.dbPool.write { db in
            try pipeline.insert(db)
            try step.insert(db)
        }

        let runID = await runAndWait(
            pipelineId: pipelineId,
            sourcePhotoId: sourceId,
            proxyURL: proxyURL,
            outputDirectory: tempDir
        )

        let run = try await db.dbPool.read { db in
            try PipelineRun.fetchOne(db, key: runID)
        }
        XCTAssertEqual(run?.status, PipelineRunStatus.failed.rawValue, "Run must be marked failed when a step throws")
        XCTAssertNotNil(run?.errorMessage, "errorMessage must be set on failed run")
    }

    // PIPE-5: Cancelled run stores 'cancelled' status
    // Out of scope for Phase 6 — cancellation not implemented
    func testCancelledRunStoresCancelledStatus() throws {
        throw XCTSkip("Cancellation not in scope for Phase 6")
    }
}
