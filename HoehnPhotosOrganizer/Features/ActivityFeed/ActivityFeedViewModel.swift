import Foundation
import GRDB
import Observation

// MARK: - ActivityDisplayItem

/// Wrapper that collapses consecutive studio render events of the same medium
/// into a single grouped entry for display in the activity feed.
enum ActivityDisplayItem: Identifiable {
    case single(ActivityEvent)
    case group(events: [ActivityEvent], medium: String)
    case importGroup(events: [ActivityEvent], totalPhotos: Int)

    var id: String {
        switch self {
        case .single(let e): return e.id
        case .group(let events, _): return "group-\(events.first!.id)"
        case .importGroup(let events, _): return "import-group-\(events.first!.id)"
        }
    }

    var primaryEvent: ActivityEvent {
        switch self {
        case .single(let e): return e
        case .group(let events, _): return events.first!
        case .importGroup(let events, _): return events.first!
        }
    }

    var occurredAt: Date {
        primaryEvent.occurredAt
    }
}

@MainActor
@Observable
final class ActivityFeedViewModel {

    // MARK: - Published state

    var rootEvents: [ActivityEvent] = []
    var expandedEventIds: Set<String> = []
    var childrenCache: [String: [ActivityEvent]] = [:]

    // MARK: - Dependencies

    private let repo: ActivityEventRepository
    private let service: ActivityEventService
    private let photoRepo: PhotoRepository?

    /// Exposed for passing to ActivityNoteInputSheet (actor injection pattern).
    var eventService: ActivityEventService { service }

    /// Photos loaded for an import batch thread view.
    var batchPhotos: [PhotoAsset] = []

    /// Cache mapping photoAssetId -> proxy URL on disk (resolved via canonicalName lookup).
    private var proxyURLCache: [String: URL] = [:]

    // MARK: - Proxy URL resolution

    /// Resolves the proxy thumbnail URL for a given photoAssetId by looking up
    /// the PhotoAsset's canonicalName and building the proxy file path.
    /// Returns a cached result if available. Returns nil if no photoRepo or photo not found.
    func resolveProxyURL(for photoAssetId: String?) -> URL? {
        guard let photoAssetId else { return nil }
        return proxyURLCache[photoAssetId]
    }

    /// Batch-resolves proxy URLs for all visible events that have a photoAssetId.
    /// Called when rootEvents change so thumbnails are ready for display.
    func preloadProxyURLs(for events: [ActivityEvent]) {
        guard let photoRepo else { return }
        let idsToResolve = events.compactMap(\.photoAssetId).filter { proxyURLCache[$0] == nil }
        guard !idsToResolve.isEmpty else { return }

        Task {
            do {
                let photos = try await photoRepo.fetchByIds(Array(Set(idsToResolve)))
                let proxiesDir = ProxyGenerationActor.proxiesDirectory()
                for photo in photos {
                    let baseName = (photo.canonicalName as NSString).deletingPathExtension
                    let url = proxiesDir.appendingPathComponent(baseName + ".jpg")
                    self.proxyURLCache[photo.id] = url
                }
            } catch {
                // Best-effort — proxy resolution failure is non-fatal
            }
        }
    }

    // MARK: - Observation lifecycle

    private var observationTask: Task<Void, Never>?

    init(repo: ActivityEventRepository, service: ActivityEventService, photoRepo: PhotoRepository? = nil) {
        self.repo = repo
        self.service = service
        self.photoRepo = photoRepo
    }

    /// Start observing the DB feed. Call once after the view appears.
    func startObserving() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.repo.feedStream()
            do {
                for try await events in stream {
                    guard !Task.isCancelled else { return }
                    self.rootEvents = events
                    self.preloadProxyURLs(for: events)
                }
            } catch {
                // Stream ended — no-op (view may have disappeared)
            }
        }
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    // MARK: - Expand / collapse

    func toggleExpand(eventId: String) {
        if expandedEventIds.contains(eventId) {
            expandedEventIds.remove(eventId)
        } else {
            // Load children if not cached, then expand
            if childrenCache[eventId] == nil {
                Task {
                    do {
                        let children = try await self.repo.fetchChildren(of: eventId)
                        self.childrenCache[eventId] = children
                        // Preload proxy URLs for child events so thumbnails are ready
                        self.preloadProxyURLs(for: children)
                    } catch {
                        self.childrenCache[eventId] = []
                    }
                    self.expandedEventIds.insert(eventId)
                }
            } else {
                expandedEventIds.insert(eventId)
            }
        }
    }

    // MARK: - Add notes

    /// Add a note attached to a parent event, or a standalone root note if parentEventId is nil.
    func addNote(body: String, toEvent parentEventId: String?) async throws {
        if let parentEventId {
            try await service.emitNote(body: body, parentEventId: parentEventId)
            // Invalidate cache so child list refreshes on next expand
            childrenCache.removeValue(forKey: parentEventId)
        } else {
            try await service.emitNote(body: body)
        }
    }

    /// Add a note attached to a photo.
    func addNote(body: String, toPhoto photoAssetId: String) async throws {
        try await service.emitNote(body: body, photoAssetId: photoAssetId)
    }

    // MARK: - Bulk metadata

    /// Apply quick metadata (location, gear, tags) to a set of photos.
    /// Merges into existing userMetadataJson, preserving fields not being set.
    func applyBulkMetadata(photoIDs: [String], location: String, gear: String, tags: String) async {
        guard let photoRepo else { return }
        do {
            let photos = try await photoRepo.fetchByIds(photoIDs)
            var updates: [String: String] = [:]

            let tagList = tags
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            for photo in photos {
                // Decode existing metadata or start fresh
                var existing: [String: Any] = [:]
                if let json = photo.userMetadataJson,
                   let data = json.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    existing = dict
                }

                // Merge — only overwrite fields that have values
                if !location.isEmpty {
                    existing["location"] = location
                }
                if !gear.isEmpty {
                    // Store as keywords since MetadataExtractionResult doesn't have a gear field
                    var keywords = (existing["keywords"] as? [String]) ?? []
                    let gearParts = gear.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
                    for part in gearParts where !keywords.contains(part) {
                        keywords.append(part)
                    }
                    existing["keywords"] = keywords
                }
                if !tagList.isEmpty {
                    var keywords = (existing["keywords"] as? [String]) ?? []
                    for tag in tagList where !keywords.contains(tag) {
                        keywords.append(tag)
                    }
                    existing["keywords"] = keywords
                }

                if let jsonData = try? JSONSerialization.data(withJSONObject: existing),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    updates[photo.id] = jsonString
                }
            }

            try await photoRepo.bulkUpdateUserMetadata(updates)

            // Emit metadataEnrichment events for each photo
            var fields: [String] = []
            if !location.isEmpty { fields.append("location") }
            if !gear.isEmpty { fields.append("gear") }
            if !tagList.isEmpty { fields.append("tags") }

            // Emit one event for the first photo as a representative record
            if let firstID = photoIDs.first {
                try? await service.emitMetadataEnrichment(
                    photoAssetId: firstID,
                    fields: fields
                )
            }
        } catch {
            // Best-effort — metadata application failure is non-fatal
        }
    }

    // MARK: - Display items (grouped consecutive studio renders)

    /// Extracts the medium name from a studioRender event's metadata JSON.
    private func extractMedium(from event: ActivityEvent) -> String? {
        guard let metadata = event.metadata,
              let data = metadata.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return dict["medium"] as? String
    }

    /// Extracts the photo count from an importBatch event's metadata or detail text.
    private func extractPhotoCount(from event: ActivityEvent) -> Int {
        // Try metadata first
        if let metadata = event.metadata,
           let data = metadata.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let count = dict["photo_count"] as? Int { return count }
            if let count = (dict["photo_count"] as? NSNumber)?.intValue { return count }
        }
        // Fall back to parsing detail text like "42 file(s) imported"
        if let detail = event.detail,
           let match = detail.range(of: #"^\d+"#, options: .regularExpression) {
            return Int(detail[match]) ?? 0
        }
        return 0
    }

    /// Transforms a flat list of events into display items, collapsing consecutive
    /// studioRender events with the same medium within 30 minutes into groups,
    /// and consecutive importBatch events within 30 minutes into import groups.
    func buildDisplayItems(from events: [ActivityEvent]) -> [ActivityDisplayItem] {
        guard !events.isEmpty else { return [] }

        var items: [ActivityDisplayItem] = []
        var i = 0
        let groupingWindow: TimeInterval = 30 * 60 // 30 minutes

        while i < events.count {
            let current = events[i]

            // Studio render grouping
            if current.kind == .studioRender, let currentMedium = extractMedium(from: current) {
                // Collect consecutive studioRender events with the same medium within the time window.
                // Events are ordered most-recent-first, so timestamps decrease.
                var groupEvents = [current]
                var j = i + 1
                while j < events.count {
                    let next = events[j]
                    guard next.kind == .studioRender,
                          let nextMedium = extractMedium(from: next),
                          nextMedium == currentMedium else { break }
                    let timeDelta = abs(groupEvents.last!.occurredAt.timeIntervalSince(next.occurredAt))
                    guard timeDelta <= groupingWindow else { break }
                    groupEvents.append(next)
                    j += 1
                }

                if groupEvents.count > 1 {
                    items.append(.group(events: groupEvents, medium: currentMedium))
                } else {
                    items.append(.single(current))
                }
                i = j
                continue
            }

            // Import batch grouping
            if current.kind == .importBatch {
                var groupEvents = [current]
                var j = i + 1
                while j < events.count {
                    let next = events[j]
                    guard next.kind == .importBatch else { break }
                    let timeDelta = abs(groupEvents.last!.occurredAt.timeIntervalSince(next.occurredAt))
                    guard timeDelta <= groupingWindow else { break }
                    groupEvents.append(next)
                    j += 1
                }

                if groupEvents.count > 1 {
                    let totalPhotos = groupEvents.reduce(0) { $0 + extractPhotoCount(from: $1) }
                    items.append(.importGroup(events: groupEvents, totalPhotos: totalPhotos))
                } else {
                    items.append(.single(current))
                }
                i = j
                continue
            }

            items.append(.single(current))
            i += 1
        }

        return items
    }

    // MARK: - Import batch photos

    /// Fetch all photos belonging to an import batch by extracting photoAssetIds
    /// from the batch's child frameExtraction events.
    func fetchPhotosForBatch(eventId: String) async {
        guard let photoRepo else { return }
        // Ensure children are loaded
        if childrenCache[eventId] == nil {
            do {
                let children = try await repo.fetchChildren(of: eventId)
                childrenCache[eventId] = children
            } catch {
                childrenCache[eventId] = []
            }
        }
        let children = childrenCache[eventId] ?? []
        let photoIds = children.compactMap(\.photoAssetId)
        guard !photoIds.isEmpty else {
            batchPhotos = []
            return
        }
        do {
            batchPhotos = try await photoRepo.fetchByIds(photoIds)
        } catch {
            batchPhotos = []
        }
    }
}
