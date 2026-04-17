import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

final class PipelineRepositoryTests: XCTestCase {

    var db: AppDatabase!
    var repo: PipelineRepository!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        repo = PipelineRepository(db: db)
    }

    // PIPE-1: Create a pipeline definition and persist it to the DB
    func testCreatePipelineDefinition() async throws {
        let definition = try await repo.createPipeline(
            name: "Test Pipeline",
            purpose: .printPrep,
            steps: []
        )
        XCTAssertFalse(definition.id.isEmpty)
        XCTAssertEqual(definition.name, "Test Pipeline")
        XCTAssertEqual(definition.purpose, PipelinePurpose.printPrep.rawValue)

        // Verify row exists in DB
        let count = try await db.dbPool.read { db in
            try PipelineDefinition.fetchCount(db)
        }
        XCTAssertEqual(count, 1)
    }

    // PIPE-1: Fetch a pipeline definition by ID
    func testFetchPipelineDefinitionByID() async throws {
        let created = try await repo.createPipeline(
            name: "Edge Pipeline",
            purpose: .engravingPrep,
            steps: [(.edgeDetection, ["intensity": "2.0"])]
        )

        let fetched = try await repo.fetchPipeline(id: created.id)
        XCTAssertNotNil(fetched)
        let (definition, steps) = fetched!
        XCTAssertEqual(definition.id, created.id)
        XCTAssertEqual(definition.name, "Edge Pipeline")
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps[0].stepType, PipelineStepType.edgeDetection.rawValue)
    }

    // PIPE-1: Update a pipeline definition (name, description, steps)
    func testUpdatePipelineDefinition() async throws {
        var created = try await repo.createPipeline(
            name: "Original",
            purpose: .tracingPrep,
            steps: [(.grayscale, nil)]
        )

        created.name = "Updated"
        try await repo.updatePipeline(created, steps: [(.grayscale, nil), (.edgeDetection, nil)])

        let fetched = try await repo.fetchPipeline(id: created.id)
        XCTAssertNotNil(fetched)
        let (definition, steps) = fetched!
        XCTAssertEqual(definition.name, "Updated")
        XCTAssertEqual(steps.count, 2)
    }

    // PIPE-1: Delete a pipeline definition and verify cascade to pipeline_steps
    func testDeletePipelineDefinitionCascadesSteps() async throws {
        let created = try await repo.createPipeline(
            name: "Doomed",
            purpose: .scanCleanup,
            steps: [(.grayscale, nil), (.resizeCrop, ["width": "800", "height": "600"])]
        )

        // Verify 2 steps were created
        let stepsBefore = try await db.dbPool.read { db in
            try PipelineStep.filter(Column("pipeline_id") == created.id).fetchCount(db)
        }
        XCTAssertEqual(stepsBefore, 2)

        try await repo.deletePipeline(id: created.id)

        // Verify definition is gone
        let defCount = try await db.dbPool.read { db in
            try PipelineDefinition.fetchCount(db)
        }
        XCTAssertEqual(defCount, 0)

        // Verify steps were cascade deleted
        let stepsAfter = try await db.dbPool.read { db in
            try PipelineStep.filter(Column("pipeline_id") == created.id).fetchCount(db)
        }
        XCTAssertEqual(stepsAfter, 0)
    }

    // PIPE-4: PipelinePurpose enum persists as raw string and decodes correctly
    func testPipelinePurposeRoundTrip() async throws {
        let created = try await repo.createPipeline(
            name: "Tracing Pipeline",
            purpose: .tracingPrep,
            steps: []
        )

        let fetched = try await repo.fetchPipeline(id: created.id)
        XCTAssertNotNil(fetched)
        let (definition, _) = fetched!
        XCTAssertEqual(definition.purpose, PipelinePurpose.tracingPrep.rawValue)
        XCTAssertEqual(definition.purpose, "tracing_prep")
    }

    // PIPE-1: fetchAll returns all pipeline definitions for display in the UI
    func testFetchAllPipelinesForDisplay() async throws {
        _ = try await repo.createPipeline(name: "Pipeline A", purpose: .printPrep, steps: [])
        _ = try await repo.createPipeline(name: "Pipeline B", purpose: .socialExport, steps: [])
        _ = try await repo.createPipeline(name: "Pipeline C", purpose: .engravingPrep, steps: [])

        let all = try await repo.fetchAllPipelines()
        XCTAssertEqual(all.count, 3)
        // All three pipelines must be present (names in any order, ordered by created_at desc)
        let names = Set(all.map(\.name))
        XCTAssertTrue(names.contains("Pipeline A"))
        XCTAssertTrue(names.contains("Pipeline B"))
        XCTAssertTrue(names.contains("Pipeline C"))
    }
}
