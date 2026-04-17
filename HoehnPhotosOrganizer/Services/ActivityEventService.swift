import Foundation
import SwiftUI

/// Single write point for all activity events in the app.
/// Every action (import, adjustment, print, note, rollback) calls this service.
actor ActivityEventService {
    private let repo: ActivityEventRepository

    init(repo: ActivityEventRepository) { self.repo = repo }

    // MARK: - Import

    func emitImportBatch(
        title: String,
        fileCount: Int,
        metadata: [String: Any]? = nil
    ) async throws -> ActivityEvent {
        let event = ActivityEvent(
            id: UUID().uuidString,
            kind: .importBatch,
            parentEventId: nil,
            photoAssetId: nil,
            title: title,
            detail: "\(fileCount) file(s) imported",
            metadata: metadata.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) },
            occurredAt: Date(),
            createdAt: Date()
        )
        try await repo.insert(event)
        return event
    }

    func emitFrameExtraction(
        parentBatchId: String,
        photoAssetId: String,
        frameName: String,
        success: Bool
    ) async throws {
        let event = ActivityEvent(
            id: UUID().uuidString,
            kind: .frameExtraction,
            parentEventId: parentBatchId,
            photoAssetId: photoAssetId,
            title: success ? "Extracted \(frameName)" : "Extraction failed: \(frameName)",
            detail: nil,
            metadata: nil,
            occurredAt: Date(),
            createdAt: Date()
        )
        try await repo.insert(event)
    }

    // MARK: - Adjustments

    func emitAdjustment(
        photoAssetId: String,
        parentEventId: String? = nil,
        description: String,
        snapshotId: String? = nil
    ) async throws -> ActivityEvent {
        let meta = snapshotId.map { ["snapshot_id": $0] }
        let event = ActivityEvent(
            id: UUID().uuidString,
            kind: .adjustment,
            parentEventId: parentEventId,
            photoAssetId: photoAssetId,
            title: "Adjustment",
            detail: description,
            metadata: meta.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) },
            occurredAt: Date(),
            createdAt: Date()
        )
        try await repo.insert(event)
        return event
    }

    func emitRollback(
        photoAssetId: String,
        restoredSnapshotId: String,
        description: String
    ) async throws {
        let event = ActivityEvent(
            id: UUID().uuidString,
            kind: .rollback,
            parentEventId: nil,
            photoAssetId: photoAssetId,
            title: "Rolled back adjustment",
            detail: description,
            metadata: try? String(data: JSONSerialization.data(withJSONObject: ["snapshot_id": restoredSnapshotId]), encoding: .utf8),
            occurredAt: Date(),
            createdAt: Date()
        )
        try await repo.insert(event)
    }

    // MARK: - Print

    func emitPrintAttempt(
        photoAssetId: String,
        printType: String,
        paper: String,
        outcome: String?
    ) async throws -> ActivityEvent {
        let event = ActivityEvent(
            id: UUID().uuidString,
            kind: .printAttempt,
            parentEventId: nil,
            photoAssetId: photoAssetId,
            title: "Print attempt — \(printType)",
            detail: "Paper: \(paper)" + (outcome.map { " · \($0)" } ?? ""),
            metadata: nil,
            occurredAt: Date(),
            createdAt: Date()
        )
        try await repo.insert(event)
        return event
    }

    // MARK: - Notes

    func emitNote(
        body: String,
        photoAssetId: String? = nil,
        parentEventId: String? = nil
    ) async throws {
        let event = ActivityEvent(
            id: UUID().uuidString,
            kind: .note,
            parentEventId: parentEventId,
            photoAssetId: photoAssetId,
            title: "Note",
            detail: body,
            metadata: nil,
            occurredAt: Date(),
            createdAt: Date()
        )
        try await repo.insert(event)
    }

    // MARK: - Batch

    func emitBatchTransform(
        title: String,
        photoCount: Int,
        operationDescription: String
    ) async throws -> ActivityEvent {
        let event = ActivityEvent(
            id: UUID().uuidString,
            kind: .batchTransform,
            parentEventId: nil,
            photoAssetId: nil,
            title: title,
            detail: "\(photoCount) photo(s) — \(operationDescription)",
            metadata: nil,
            occurredAt: Date(),
            createdAt: Date()
        )
        try await repo.insert(event)
        return event
    }

    // MARK: - Editorial review

    /// Emits a root editorial review event for a photo. Returns the event so child
    /// events (e.g. adjustment applied, metadata enriched) can be threaded under it.
    @discardableResult
    func emitEditorialReview(
        photoAssetId: String,
        score: Int?,
        printReadiness: String?,
        summary: String?,
        inputTokens: Int,
        outputTokens: Int,
        estimatedCostUSD: Double
    ) async throws -> ActivityEvent {
        let scoreText = score.map { "\($0)/10" } ?? "—"
        let readiness = printReadiness.map { " · \($0)" } ?? ""
        let cost = String(format: "$%.4f", estimatedCostUSD)
        let metaDict: [String: Any] = [
            "score": score as Any,
            "print_readiness": printReadiness as Any,
            "input_tokens": inputTokens,
            "output_tokens": outputTokens,
            "estimated_cost_usd": estimatedCostUSD
        ]
        let event = ActivityEvent(
            id: UUID().uuidString,
            kind: .editorialReview,
            parentEventId: nil,
            photoAssetId: photoAssetId,
            title: "Editorial review — \(scoreText)\(readiness)",
            detail: summary,
            metadata: (try? JSONSerialization.data(withJSONObject: metaDict)).flatMap { String(data: $0, encoding: .utf8) },
            occurredAt: Date(),
            createdAt: Date()
        )
        try await repo.insert(event)
        // Cost sub-event as child
        let costEvent = ActivityEvent(
            id: UUID().uuidString,
            kind: .editorialReview,
            parentEventId: event.id,
            photoAssetId: photoAssetId,
            title: "Claude — \(inputTokens) in / \(outputTokens) out · \(cost)",
            detail: nil,
            metadata: nil,
            occurredAt: Date(),
            createdAt: Date()
        )
        try await repo.insert(costEvent)
        return event
    }

    // MARK: - Face detection

    @discardableResult
    func emitFaceDetection(
        photoAssetId: String,
        faceCount: Int,
        identifiedNames: [String]
    ) async throws -> ActivityEvent {
        let names = identifiedNames.isEmpty ? "unidentified" : identifiedNames.joined(separator: ", ")
        let event = ActivityEvent(
            id: UUID().uuidString,
            kind: .faceDetection,
            parentEventId: nil,
            photoAssetId: photoAssetId,
            title: "\(faceCount) face(s) detected",
            detail: names,
            metadata: nil,
            occurredAt: Date(),
            createdAt: Date()
        )
        try await repo.insert(event)
        return event
    }

    // MARK: - Metadata enrichment

    func emitMetadataEnrichment(
        photoAssetId: String,
        fields: [String],
        parentEventId: String? = nil
    ) async throws {
        guard !fields.isEmpty else { return }
        let event = ActivityEvent(
            id: UUID().uuidString,
            kind: .metadataEnrichment,
            parentEventId: parentEventId,
            photoAssetId: photoAssetId,
            title: "Metadata enriched",
            detail: fields.joined(separator: ", "),
            metadata: nil,
            occurredAt: Date(),
            createdAt: Date()
        )
        try await repo.insert(event)
    }

    // MARK: - Print Job

    /// Emit a root `printJob` event with a serialized PrintJobSnapshot.
    @discardableResult
    func emitPrintJob(
        photoAssetId: String,
        title: String,
        detail: String,
        snapshot: PrintJobSnapshot
    ) async throws -> ActivityEvent {
        let event = ActivityEvent(
            id: UUID().uuidString,
            kind: .printJob,
            parentEventId: nil,
            photoAssetId: photoAssetId,
            title: title,
            detail: detail,
            metadata: snapshot.jsonString(),
            occurredAt: Date(),
            createdAt: Date()
        )
        try await repo.insert(event)
        return event
    }

    /// Emit a `.printAttempt` child event under a print job parent.
    func emitPrintAttemptChild(
        parentEventId: String,
        photoAssetId: String,
        printerName: String?,
        templateName: String?
    ) async throws {
        let parts = [printerName, templateName].compactMap { $0 }
        let event = ActivityEvent(
            id: UUID().uuidString,
            kind: .printAttempt,
            parentEventId: parentEventId,
            photoAssetId: photoAssetId,
            title: "Print sent to \(printerName ?? "printer")",
            detail: parts.isEmpty ? nil : parts.joined(separator: " · "),
            metadata: nil,
            occurredAt: Date(),
            createdAt: Date()
        )
        try await repo.insert(event)
    }

    // MARK: - Scan Attachment

    /// Emit a `.scanAttachment` child event with a file path reference.
    func emitScanAttachment(
        parentEventId: String,
        photoAssetId: String?,
        title: String,
        detail: String?,
        filePath: String
    ) async throws {
        let meta = try? String(
            data: JSONSerialization.data(withJSONObject: ["filePath": filePath]),
            encoding: .utf8
        )
        let event = ActivityEvent(
            id: UUID().uuidString,
            kind: .scanAttachment,
            parentEventId: parentEventId,
            photoAssetId: photoAssetId,
            title: title,
            detail: detail,
            metadata: meta,
            occurredAt: Date(),
            createdAt: Date()
        )
        try await repo.insert(event)
    }

    // MARK: - AI Summary

    /// Emit an `.aiSummary` child event with analysis text and optional structured suggestions.
    @discardableResult
    func emitAISummary(
        parentEventId: String,
        photoAssetId: String?,
        detail: String,
        suggestions: [String: Any]? = nil
    ) async throws -> ActivityEvent {
        let meta: String? = suggestions.flatMap {
            (try? JSONSerialization.data(withJSONObject: $0)).flatMap { String(data: $0, encoding: .utf8) }
        }
        let event = ActivityEvent(
            id: UUID().uuidString,
            kind: .aiSummary,
            parentEventId: parentEventId,
            photoAssetId: photoAssetId,
            title: "AI analyzed the thread",
            detail: detail,
            metadata: meta,
            occurredAt: Date(),
            createdAt: Date()
        )
        try await repo.insert(event)
        return event
    }

    // MARK: - Search sessions

    @discardableResult
    func emitSearch(
        query: String,
        filterJSON: String?,
        personNames: [String],
        resultCount: Int?,
        conversationJSON: String?,
        savedSearchRuleId: String? = nil
    ) async throws -> ActivityEvent {
        var metaDict: [String: Any] = [:]
        if let fj = filterJSON { metaDict["filter_json"] = fj }
        if !personNames.isEmpty { metaDict["person_names"] = personNames }
        if let rc = resultCount { metaDict["result_count"] = rc }
        if let cj = conversationJSON { metaDict["conversation_json"] = cj }

        let detail = personNames.isEmpty
            ? (resultCount.map { "\($0) results" } ?? nil)
            : "\(personNames.joined(separator: ", "))" + (resultCount.map { " · \($0) results" } ?? "")

        let event = ActivityEvent(
            id: UUID().uuidString,
            kind: .search,
            parentEventId: nil,
            photoAssetId: nil,
            title: query,
            detail: detail,
            metadata: (try? JSONSerialization.data(withJSONObject: metaDict)).flatMap { String(data: $0, encoding: .utf8) },
            occurredAt: Date(),
            createdAt: Date(),
            savedSearchRuleId: savedSearchRuleId
        )
        try await repo.insert(event)
        return event
    }

    // MARK: - Studio

    @discardableResult
    func emitStudioRenderCompleted(
        medium: String, durationSeconds: Double,
        photoName: String? = nil, photoAssetId: String? = nil
    ) async throws -> ActivityEvent {
        let durationText = durationSeconds < 60
            ? String(format: "%.1fs", durationSeconds)
            : String(format: "%.0f min", durationSeconds / 60)
        let titleSuffix = photoName.map { " — \($0)" } ?? ""
        let metaDict: [String: Any] = ["medium": medium, "duration_seconds": durationSeconds]
        let event = ActivityEvent(
            id: UUID().uuidString, kind: .studioRender, parentEventId: nil,
            photoAssetId: photoAssetId,
            title: "Studio render · \(medium)\(titleSuffix)",
            detail: "Completed in \(durationText)",
            metadata: (try? JSONSerialization.data(withJSONObject: metaDict)).flatMap { String(data: $0, encoding: .utf8) },
            occurredAt: Date(), createdAt: Date()
        )
        try await repo.insert(event)
        return event
    }

    @discardableResult
    func emitStudioVersionSaved(
        versionName: String, medium: String, photoAssetId: String? = nil
    ) async throws -> ActivityEvent {
        let event = ActivityEvent(
            id: UUID().uuidString, kind: .studioVersion, parentEventId: nil,
            photoAssetId: photoAssetId,
            title: "Studio version saved",
            detail: "\(versionName) · \(medium)",
            metadata: (try? JSONSerialization.data(withJSONObject: ["version_name": versionName, "medium": medium])).flatMap { String(data: $0, encoding: .utf8) },
            occurredAt: Date(), createdAt: Date()
        )
        try await repo.insert(event)
        return event
    }

    @discardableResult
    func emitStudioExported(
        format: String, filePath: String, photoAssetId: String? = nil
    ) async throws -> ActivityEvent {
        let fileName = (filePath as NSString).lastPathComponent
        let event = ActivityEvent(
            id: UUID().uuidString, kind: .studioExport, parentEventId: nil,
            photoAssetId: photoAssetId,
            title: "Studio export · \(format.uppercased())",
            detail: fileName,
            metadata: (try? JSONSerialization.data(withJSONObject: ["format": format, "file_path": filePath])).flatMap { String(data: $0, encoding: .utf8) },
            occurredAt: Date(), createdAt: Date()
        )
        try await repo.insert(event)
        return event
    }

    @discardableResult
    func emitStudioSentToPrintLab(
        medium: String, photoAssetId: String? = nil
    ) async throws -> ActivityEvent {
        let event = ActivityEvent(
            id: UUID().uuidString, kind: .studioPrintLab, parentEventId: nil,
            photoAssetId: photoAssetId,
            title: "Studio → Print Lab", detail: medium,
            metadata: (try? JSONSerialization.data(withJSONObject: ["medium": medium])).flatMap { String(data: $0, encoding: .utf8) },
            occurredAt: Date(), createdAt: Date()
        )
        try await repo.insert(event)
        return event
    }

    // MARK: - Job lifecycle

    /// Emit when a triage job is created (e.g. after import bucketing).
    @discardableResult
    func emitJobCreated(
        jobId: String, title: String, photoCount: Int
    ) async throws -> ActivityEvent {
        let metaDict: [String: Any] = ["job_id": jobId, "photo_count": photoCount]
        let event = ActivityEvent(
            id: UUID().uuidString, kind: .jobCreated, parentEventId: nil,
            photoAssetId: nil,
            title: "Job created: \(title)",
            detail: "\(photoCount) photos",
            metadata: (try? JSONSerialization.data(withJSONObject: metaDict)).flatMap { String(data: $0, encoding: .utf8) },
            occurredAt: Date(), createdAt: Date()
        )
        try await repo.insert(event)
        return event
    }

    /// Emit when a triage job is marked complete.
    @discardableResult
    func emitJobCompleted(
        jobId: String, title: String, photoCount: Int
    ) async throws -> ActivityEvent {
        let metaDict: [String: Any] = ["job_id": jobId, "photo_count": photoCount]
        let event = ActivityEvent(
            id: UUID().uuidString, kind: .jobCompleted, parentEventId: nil,
            photoAssetId: nil,
            title: "Job completed: \(title)",
            detail: "\(photoCount) photos triaged",
            metadata: (try? JSONSerialization.data(withJSONObject: metaDict)).flatMap { String(data: $0, encoding: .utf8) },
            occurredAt: Date(), createdAt: Date()
        )
        try await repo.insert(event)
        return event
    }

    /// Emit when a triage job is split into sub-jobs.
    @discardableResult
    func emitJobSplit(
        parentJobId: String, parentTitle: String, childCount: Int
    ) async throws -> ActivityEvent {
        let metaDict: [String: Any] = ["parent_job_id": parentJobId, "child_count": childCount]
        let event = ActivityEvent(
            id: UUID().uuidString, kind: .jobSplit, parentEventId: nil,
            photoAssetId: nil,
            title: "Job split: \(parentTitle)",
            detail: "Split into \(childCount) sub-jobs",
            metadata: (try? JSONSerialization.data(withJSONObject: metaDict)).flatMap { String(data: $0, encoding: .utf8) },
            occurredAt: Date(), createdAt: Date()
        )
        try await repo.insert(event)
        return event
    }

    // MARK: - Image Versioning

    @discardableResult
    func emitVersionCreated(
        photoAssetId: String,
        versionName: String,
        versionNumber: Int
    ) async throws -> ActivityEvent {
        let metaDict: [String: Any] = ["version_name": versionName, "version_number": versionNumber]
        let event = ActivityEvent(
            id: UUID().uuidString, kind: .versionCreated, parentEventId: nil,
            photoAssetId: photoAssetId,
            title: "Version saved: \(versionName)",
            detail: "Version \(versionNumber)",
            metadata: (try? JSONSerialization.data(withJSONObject: metaDict)).flatMap { String(data: $0, encoding: .utf8) },
            occurredAt: Date(), createdAt: Date()
        )
        try await repo.insert(event)
        return event
    }

    // MARK: - CurveLab

    @discardableResult
    func emitCurveLinearized(
        inputQuad: String, measurementFile: String, outputQuad: String, smoothing: Double
    ) async throws -> ActivityEvent {
        let metaDict: [String: Any] = [
            "input_quad": inputQuad,
            "measurement_file": measurementFile,
            "output_quad": outputQuad,
            "smoothing": smoothing
        ]
        let event = ActivityEvent(
            id: UUID().uuidString, kind: .curveLinearized, parentEventId: nil,
            photoAssetId: nil,
            title: "Curve linearized — \(outputQuad)",
            detail: "From \(inputQuad) + \(measurementFile)",
            metadata: (try? JSONSerialization.data(withJSONObject: metaDict)).flatMap { String(data: $0, encoding: .utf8) },
            occurredAt: Date(), createdAt: Date()
        )
        try await repo.insert(event)
        return event
    }

    @discardableResult
    func emitCurveSaved(
        fileName: String, profileName: String
    ) async throws -> ActivityEvent {
        let metaDict: [String: Any] = ["file_name": fileName, "profile_name": profileName]
        let event = ActivityEvent(
            id: UUID().uuidString, kind: .curveSaved, parentEventId: nil,
            photoAssetId: nil,
            title: "Curve saved — \(fileName)",
            detail: "Profile: \(profileName)",
            metadata: (try? JSONSerialization.data(withJSONObject: metaDict)).flatMap { String(data: $0, encoding: .utf8) },
            occurredAt: Date(), createdAt: Date()
        )
        try await repo.insert(event)
        return event
    }

    @discardableResult
    func emitCurveBlended(
        curve1: String, curve2: String, outputName: String
    ) async throws -> ActivityEvent {
        let metaDict: [String: Any] = ["curve1": curve1, "curve2": curve2, "output_name": outputName]
        let event = ActivityEvent(
            id: UUID().uuidString, kind: .curveBlended, parentEventId: nil,
            photoAssetId: nil,
            title: "Curves blended — \(outputName)",
            detail: "\(curve1) + \(curve2)",
            metadata: (try? JSONSerialization.data(withJSONObject: metaDict)).flatMap { String(data: $0, encoding: .utf8) },
            occurredAt: Date(), createdAt: Date()
        )
        try await repo.insert(event)
        return event
    }

    // MARK: - Outbox processing (called by EventOutboxProcessor)

    /// Insert a pre-built ActivityEvent idempotently — safe to call on retry.
    func insertOrIgnore(_ event: ActivityEvent) async throws {
        try await repo.insertOrIgnore(event)
    }
}

// MARK: - SwiftUI environment key

private struct ActivityEventServiceKey: EnvironmentKey {
    static var defaultValue: ActivityEventService? { nil }
}

extension EnvironmentValues {
    var activityEventService: ActivityEventService? {
        get { self[ActivityEventServiceKey.self] }
        set { self[ActivityEventServiceKey.self] = newValue }
    }
}
