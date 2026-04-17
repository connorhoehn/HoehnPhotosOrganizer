import Foundation
import CoreImage
import ImageIO
import GRDB

// MARK: - PipelineRunProgress

struct PipelineRunProgress: Sendable {
    let stepOrder: Int
    let stepType: PipelineStepType
    let status: PipelineRunStepStatus
    let detail: String?
}

// MARK: - PipelineRunActor

/// Executes a pipeline's steps in sequence against a proxy image.
/// Persists per-step results to pipeline_run_steps, writes the output JPEG,
/// and creates a PhotoAsset (role=workflowOutput) + AssetLineage row on success.
actor PipelineRunActor {

    // MARK: - Public API

    /// Returns a run ID and an AsyncStream of progress events.
    /// Execution runs in a Task.detached block on userInitiated priority to
    /// avoid blocking the MainActor.
    nonisolated func run(
        pipelineId: String,
        sourcePhotoId: String,
        proxyURL: URL,
        outputDirectory: URL,
        db: AppDatabase
    ) -> (runID: String, progress: AsyncStream<PipelineRunProgress>) {
        let runID = UUID().uuidString
        let (stream, continuation) = AsyncStream<PipelineRunProgress>.makeStream()

        Task.detached(priority: .userInitiated) {
            await self.executeRun(
                runID: runID,
                pipelineId: pipelineId,
                sourcePhotoId: sourcePhotoId,
                proxyURL: proxyURL,
                outputDirectory: outputDirectory,
                db: db,
                continuation: continuation
            )
        }
        return (runID, stream)
    }

    // MARK: - Core execution

    private func executeRun(
        runID: String,
        pipelineId: String,
        sourcePhotoId: String,
        proxyURL: URL,
        outputDirectory: URL,
        db: AppDatabase,
        continuation: AsyncStream<PipelineRunProgress>.Continuation
    ) async {
        defer { continuation.finish() }

        let now = { ISO8601DateFormatter().string(from: .now) }

        // 1. Insert PipelineRun row with status=running (short standalone write)
        var run = PipelineRun(
            id: runID,
            pipelineId: pipelineId,
            sourcePhotoId: sourcePhotoId,
            status: PipelineRunStatus.running.rawValue,
            startedAt: now(),
            completedAt: nil,
            errorMessage: nil,
            outputPhotoIdsJson: nil
        )
        do {
            let runSnapshot = run
            try await db.dbPool.write { try runSnapshot.insert($0) }
        } catch {
            // Cannot record the failure if the run row itself failed — return silently
            return
        }

        // 2. Load pipeline steps ordered by step_order
        let steps: [PipelineStep]
        do {
            steps = try await db.dbPool.read { db in
                try PipelineStep
                    .filter(Column("pipeline_id") == pipelineId)
                    .order(Column("step_order"))
                    .fetchAll(db)
            }
        } catch {
            await failRun(&run, error: "Failed to load pipeline steps: \(error.localizedDescription)", db: db, now: now())
            return
        }

        // 3. Guard on proxy CIImage — CIImage(contentsOf:) returns nil silently when
        //    the file is missing or unreadable. This is the safety net.
        guard let ciImage = CIImage(contentsOf: proxyURL) else {
            await failRun(
                &run,
                error: "Proxy file not found at \(proxyURL.lastPathComponent). Ensure proxy generation has completed before running a pipeline.",
                db: db,
                now: now()
            )
            return
        }

        // 4. Create one CIContext per run (RESEARCH pitfall 6 — context creation is expensive)
        let context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any
        ])

        // 5. Execute steps sequentially
        var current = ciImage

        for (idx, stepRecord) in steps.enumerated() {
            guard let stepType = PipelineStepType(rawValue: stepRecord.stepType),
                  let step = makeStep(stepType) else {
                // Unknown step type — skip gracefully (logged via continue)
                continue
            }

            let params: [String: String] = stepRecord.paramsJson
                .flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]

            // Insert running step row
            var runStep = PipelineRunStep(
                id: UUID().uuidString,
                runId: runID,
                stepOrder: idx,
                stepType: stepRecord.stepType,
                status: PipelineRunStepStatus.running.rawValue,
                detail: nil,
                startedAt: now(),
                completedAt: nil,
                paramsJson: stepRecord.paramsJson
            )
            let stepInsert = runStep
            try? await db.dbPool.write { try stepInsert.insert($0) }
            continuation.yield(PipelineRunProgress(stepOrder: idx, stepType: stepType, status: .running, detail: nil))

            do {
                current = try step.execute(input: current, params: params, context: context)

                // Render boundary every 4 steps to flush GPU memory
                // (RESEARCH anti-pattern: unbounded CIImage filter chain)
                if (idx + 1) % 4 == 0 {
                    if let rendered = context.createCGImage(current, from: current.extent) {
                        current = CIImage(cgImage: rendered)
                    }
                }

                runStep.status = PipelineRunStepStatus.succeeded.rawValue
                runStep.completedAt = now()
                let stepSuccess = runStep
                try? await db.dbPool.write { try stepSuccess.update($0) }
                continuation.yield(PipelineRunProgress(stepOrder: idx, stepType: stepType, status: .succeeded, detail: nil))

            } catch {
                runStep.status = PipelineRunStepStatus.failed.rawValue
                runStep.detail = error.localizedDescription
                runStep.completedAt = now()
                let stepFailed = runStep
                try? await db.dbPool.write { try stepFailed.update($0) }
                continuation.yield(PipelineRunProgress(stepOrder: idx, stepType: stepType, status: .failed, detail: error.localizedDescription))

                // Step failure stops execution and marks the whole run as failed
                await failRun(&run, error: error.localizedDescription, db: db, now: now())
                return
            }
        }

        // 6. Write output JPEG — canonical name: {sourceName}_{pipelineId[0..<8]}.jpg
        let sourceStem = proxyURL.deletingPathExtension().lastPathComponent
        let outputName = "\(sourceStem)_\(pipelineId.prefix(8)).jpg"
        let outputURL = outputDirectory.appendingPathComponent(outputName)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        if let cgFinal = context.createCGImage(current, from: current.extent),
           let dest = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.jpeg" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cgFinal, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }

        // 7. Insert output PhotoAsset + AssetLineage atomically
        // PhotoAsset.new() intentionally leaves AST-6 fields nil — those are
        // populated by IngestionActor on a later enrichment pass.
        let fileSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var outputAsset = PhotoAsset.new(
            canonicalName: outputName,
            role: .workflowOutput,
            filePath: outputURL.path,
            fileSize: fileSize
        )

        let lineage = AssetLineage(
            id: UUID().uuidString,
            parentPhotoId: sourcePhotoId,
            childPhotoId: outputAsset.id,
            operation: "pipeline_run",
            frameIndex: nil,
            sourceFileName: proxyURL.lastPathComponent,
            createdAt: now(),
            metadataJson: "{\"pipelineId\":\"\(pipelineId)\"}"
        )

        var outputPhotoIds: [String] = []
        do {
            try await db.dbPool.write { db in
                try outputAsset.insert(db)
                try lineage.insert(db)
            }
            outputPhotoIds.append(outputAsset.id)
        } catch {
            // Non-fatal: the image was written to disk; DB enrichment can retry later
        }

        // 8. Mark run as succeeded
        let encoder = JSONEncoder()
        run.status = PipelineRunStatus.succeeded.rawValue
        run.completedAt = now()
        run.outputPhotoIdsJson = (try? encoder.encode(outputPhotoIds)).flatMap { String(data: $0, encoding: .utf8) }
        try? await db.dbPool.write { try run.update($0) }
    }

    // MARK: - Helpers

    /// Marks a PipelineRun as failed with a user-readable error message.
    private func failRun(_ run: inout PipelineRun, error: String, db: AppDatabase, now: String) async {
        run.status = PipelineRunStatus.failed.rawValue
        run.errorMessage = error
        run.completedAt = now
        let runCopy = run
        try? await db.dbPool.write { try runCopy.update($0) }
    }

    /// Maps a PipelineStepType to its concrete implementation.
    private nonisolated func makeStep(_ type: PipelineStepType) -> (any PipelineStepProtocol)? {
        switch type {
        case .grayscale:           return GrayscaleStep()
        case .edgeDetection:       return EdgeDetectionStep()
        case .lineArt:             return LineArtStep()
        case .contourMap:          return ContourMapStep()
        case .resizeCrop:          return ResizeCropStep()
        case .validationPreflight: return ValidationPreflightStep()
        case .dustRemoval:         return DustRemovalStep()
        }
    }
}
