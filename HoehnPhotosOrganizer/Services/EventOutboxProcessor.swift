import Foundation
import Observation
import SwiftUI

// MARK: - EventOutboxProcessor

/// @Observable background service that drains the event outbox into activity_events.
///
/// Usage:
///   processor.enqueue(kind: .adjustment, photoAssetId: id, title: "Adjusted")
///   processor.on(.editorialReview) { event in ... }  // hook fired after each event persists
///
/// Guarantees:
///   - Events survive app crashes (written to event_outbox first)
///   - Duplicate-safe: idempotent insert into activity_events
///   - Retry: up to EventOutboxService.maxAttempts before marking failed
///   - queueDepth and failedCount are live-updated for UI badges
@MainActor
@Observable
final class EventOutboxProcessor {

    // MARK: - Observable state

    var queueDepth: Int = 0
    var failedCount: Int = 0
    var isProcessing: Bool = false
    var lastDrainedAt: Date? = nil
    var lastError: String? = nil

    // MARK: - Dependencies

    private let outboxService: EventOutboxService
    private let activityService: ActivityEventService

    // MARK: - Hook registry

    typealias EventHook = @Sendable (ActivityEvent) async -> Void
    private var hooks: [ActivityEventKind: [EventHook]] = [:]

    // MARK: - Background loop

    private var pollTask: Task<Void, Never>? = nil
    private let pollInterval: TimeInterval = 3.0

    // MARK: - Init

    init(outboxService: EventOutboxService, activityService: ActivityEventService) {
        self.outboxService = outboxService
        self.activityService = activityService
    }

    // MARK: - Lifecycle

    func start() {
        pollTask?.cancel()
        // Drain immediately on start — picks up any entries left from previous session
        Task { await drain() }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.pollInterval ?? 3))
                guard !Task.isCancelled else { break }
                await self?.drain()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Enqueue (convenience — write to outbox + kick drain)

    /// Enqueue an event for durable processing. Returns immediately;
    /// the event is written to SQLite before this call triggers a drain.
    func enqueue(
        kind: ActivityEventKind,
        photoAssetId: String? = nil,
        parentEventId: String? = nil,
        title: String,
        detail: String? = nil,
        metadata: String? = nil
    ) {
        let capturedOutbox = outboxService
        Task {
            do {
                try await capturedOutbox.enqueue(
                    kind: kind,
                    photoAssetId: photoAssetId,
                    parentEventId: parentEventId,
                    title: title,
                    detail: detail,
                    metadata: metadata
                )
                // Trigger an immediate drain rather than waiting for the next poll cycle
                await drain()
            } catch {
                await MainActor.run { self.lastError = "Enqueue failed: \(error.localizedDescription)" }
            }
        }
    }

    // MARK: - Manual drain / retry

    func drainNow() async {
        await drain()
    }

    func resetFailed() async {
        do {
            let count = try await outboxService.resetFailed()
            if count > 0 { await drain() }
        } catch {
            lastError = "Reset failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Hook registry

    /// Register a hook to be called after an event of the given kind is
    /// successfully persisted to activity_events. Called on MainActor.
    func on(_ kind: ActivityEventKind, _ hook: @escaping EventHook) {
        hooks[kind, default: []].append(hook)
    }

    // MARK: - Private drain loop

    private func drain() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        do {
            let pending = try await outboxService.fetchPending()
            for entry in pending {
                await processEntry(entry)
            }
            if !pending.isEmpty { lastDrainedAt = Date() }
            // Refresh counts after every drain cycle
            queueDepth  = (try? await outboxService.pendingCount()) ?? queueDepth
            failedCount = (try? await outboxService.failedCount())  ?? failedCount
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func processEntry(_ entry: EventOutboxEntry) async {
        // Atomically claim — if another process beat us, skip
        do {
            let claimed = try await outboxService.claim(id: entry.id)
            guard claimed else { return }
        } catch {
            return
        }

        do {
            guard let kind = ActivityEventKind(rawValue: entry.kind) else {
                throw OutboxError.unknownKind(entry.kind)
            }

            // Build the ActivityEvent from the outbox entry (same id = idempotent)
            let event = ActivityEvent(
                id: entry.id,
                kind: kind,
                parentEventId: entry.parentEventId,
                photoAssetId: entry.photoAssetId,
                title: entry.title,
                detail: entry.detail,
                metadata: entry.metadata,
                occurredAt: entry.occurredAt,
                createdAt: entry.createdAt
            )

            // Insert into activity_events — idempotent (INSERT OR IGNORE)
            try await activityService.insertOrIgnore(event)
            try await outboxService.markDone(id: entry.id)

            // Fire registered hooks
            for hook in hooks[kind] ?? [] {
                await hook(event)
            }
        } catch {
            try? await outboxService.markFailed(id: entry.id, error: error.localizedDescription)
        }
    }

}

// MARK: - SwiftUI environment key

private struct EventOutboxProcessorKey: EnvironmentKey {
    static var defaultValue: EventOutboxProcessor? { nil }
}

extension EnvironmentValues {
    var eventOutboxProcessor: EventOutboxProcessor? {
        get { self[EventOutboxProcessorKey.self] }
        set { self[EventOutboxProcessorKey.self] = newValue }
    }
}
