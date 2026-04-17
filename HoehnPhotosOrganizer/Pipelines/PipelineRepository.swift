import Foundation
import GRDB

actor PipelineRepository {
    private let db: AppDatabase

    init(db: AppDatabase) {
        self.db = db
    }

    // MARK: - Create

    func createPipeline(
        name: String,
        purpose: PipelinePurpose,
        steps: [(PipelineStepType, [String: String]?)]
    ) async throws -> PipelineDefinition {
        let definition = PipelineDefinition.new(name: name, purpose: purpose)
        try await db.dbPool.write { database in
            try definition.insert(database)
            for (order, (stepType, params)) in steps.enumerated() {
                let paramsJson: String? = params.flatMap { dict in
                    guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
                    return String(data: data, encoding: .utf8)
                }
                let step = PipelineStep(
                    id: UUID().uuidString,
                    pipelineId: definition.id,
                    stepOrder: order,
                    stepType: stepType.rawValue,
                    paramsJson: paramsJson
                )
                try step.insert(database)
            }
        }
        return definition
    }

    // MARK: - Read

    func fetchPipeline(id: String) async throws -> (PipelineDefinition, [PipelineStep])? {
        try await db.dbPool.read { database in
            guard let definition = try PipelineDefinition.fetchOne(database, key: id) else { return nil }
            let steps = try PipelineStep
                .filter(Column("pipeline_id") == id)
                .order(Column("step_order"))
                .fetchAll(database)
            return (definition, steps)
        }
    }

    func fetchAllPipelines() async throws -> [PipelineDefinition] {
        try await db.dbPool.read { database in
            try PipelineDefinition
                .order(Column("created_at").desc)
                .fetchAll(database)
        }
    }

    // MARK: - Update

    func updatePipeline(_ definition: PipelineDefinition, steps: [(PipelineStepType, [String: String]?)]) async throws {
        try await db.dbPool.write { database in
            try definition.update(database)
            // Delete all existing steps for this pipeline, then re-insert
            try PipelineStep
                .filter(Column("pipeline_id") == definition.id)
                .deleteAll(database)
            for (order, (stepType, params)) in steps.enumerated() {
                let paramsJson: String? = params.flatMap { dict in
                    guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
                    return String(data: data, encoding: .utf8)
                }
                let step = PipelineStep(
                    id: UUID().uuidString,
                    pipelineId: definition.id,
                    stepOrder: order,
                    stepType: stepType.rawValue,
                    paramsJson: paramsJson
                )
                try step.insert(database)
            }
        }
    }

    // MARK: - Run history

    func fetchRunsForPhoto(photoId: String) async throws -> [PipelineRun] {
        try await db.dbPool.read { database in
            try PipelineRun
                .filter(Column("source_photo_id") == photoId)
                .order(Column("started_at").desc)
                .fetchAll(database)
        }
    }

    // MARK: - Delete

    func deletePipeline(id: String) async throws {
        _ = try await db.dbPool.write { database in
            try PipelineDefinition.deleteOne(database, key: id)
            // FK CASCADE on pipeline_steps.pipeline_id deletes steps automatically
        }
    }
}
