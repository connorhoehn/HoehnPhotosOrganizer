import CoreGraphics
import Foundation
import Combine
import ImageIO
import GRDB
import SwiftUI
import UniformTypeIdentifiers

// MARK: - LibrarySortOrder

enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case dateAddedNewest  = "date_added_newest"
    case dateAddedOldest  = "date_added_oldest"
    case pictureDateNewest = "picture_date_newest"
    case pictureDateOldest = "picture_date_oldest"
    case nameAscending    = "name_asc"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dateAddedNewest:   return "Date Added: Newest First"
        case .dateAddedOldest:   return "Date Added: Oldest First"
        case .pictureDateNewest: return "Picture Date: Newest First"
        case .pictureDateOldest: return "Picture Date: Oldest First"
        case .nameAscending:     return "Name (A → Z)"
        }
    }

    var shortLabel: String {
        switch self {
        case .dateAddedNewest:   return "Added ↓"
        case .dateAddedOldest:   return "Added ↑"
        case .pictureDateNewest: return "Date ↓"
        case .pictureDateOldest: return "Date ↑"
        case .nameAscending:     return "Name"
        }
    }
}

// MARK: - LibraryViewModel

/// @MainActor ObservableObject that bridges async GRDB streams to @Published properties
/// consumed by the SwiftUI view layer. This is the production data source for ContentView.
///
/// MockDataStore is preserved for #Preview use only — not used in the production app path.
@MainActor
final class LibraryViewModel: ObservableObject {
    // MARK: - Published state

    @Published var photos: [PhotoAsset] = []
    @Published var sortOrder: LibrarySortOrder = .dateAddedNewest
    @Published var drives: [DriveDB] = []
    @Published var selectedPhotoID: String?
    @Published var searchText = ""
    @Published var selectedSection: AppSection = .library
    @Published var selectedImportStage: ImportStage = .detectDrive
    @Published var isShowingImportWizard = false
    @Published var isDragOverWindow = false
    @Published var gridColumns = 4.0
    @Published var faceQueryImage: NSImage? = nil   // face chip shown in search toolbar
    @Published var cloudAIConfigured = false
    /// Set by SearchCommandPalette before routing to .search — picked up by SearchExperienceView.
    @Published var pendingSearchQuery: String? = nil
    /// Set by Activity feed "Open in Jobs" before routing to .jobs — picked up by JobsView.
    @Published var pendingJobSelection: String? = nil
    @Published var studioViewModel = StudioViewModel()

    /// Photos sorted per `sortOrder`. Use this in the library grid instead of `photos` directly.
    var displayedPhotos: [PhotoAsset] {
        switch sortOrder {
        case .dateAddedNewest:
            return photos.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt }
        case .dateAddedOldest:
            return photos.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
        case .pictureDateNewest:
            return photos.sorted { lhs, rhs in
                let l = lhs.dateModified ?? lhs.createdAt
                let r = rhs.dateModified ?? rhs.createdAt
                return l == r ? lhs.id < rhs.id : l > r
            }
        case .pictureDateOldest:
            return photos.sorted { lhs, rhs in
                let l = lhs.dateModified ?? lhs.createdAt
                let r = rhs.dateModified ?? rhs.createdAt
                return l == r ? lhs.id < rhs.id : l < r
            }
        case .nameAscending:
            return photos.sorted {
                let cmp = $0.canonicalName.localizedStandardCompare($1.canonicalName)
                return cmp == .orderedSame ? $0.id < $1.id : cmp == .orderedAscending
            }
        }
    }

    // MARK: - Curation state (Phase 2)

    @Published var curationFilter: CurationState? = nil
    @Published var selectedPhotoIDs: Set<String> = []
    @Published var workflowPhotoIDs: [String] = []
    @Published var showReviewMode = false
    @Published var showDevelopMode = false
    @Published var developPhoto: PhotoAsset? = nil
    /// When set, DevelopView uses this sequence for prev/next navigation instead of filteredPhotos.
    /// Used by job task buttons so staged (pre-commit) photos are navigable in Develop.
    /// Cleared automatically when DevelopView closes.
    @Published var developSequence: [PhotoAsset]? = nil
    @Published var curationCounts = CurationCounts(keeper: 0, archive: 0, needsReview: 0, rejected: 0)

    // MARK: - Search state

    @Published var searchResults: [PhotoAsset] = []
    @Published var isSearching: Bool = false
    @Published var lastFilter: SearchFilter?
    @Published var lastIntent: SearchIntent?

    /// Cached library context for search prompts — computed lazily when search opens.
    var libraryContext: LibraryContext?

    // MARK: - Editorial feedback state (Phase 7 M7.2/M7.3)

    /// Most recent editorial feedback received from Claude.
    @Published var editorialFeedback: EditorialFeedback?
    /// The photo ID that `editorialFeedback` was generated for. Used to detect stale results.
    @Published var editorialFeedbackPhotoId: String?
    /// True while an editorial feedback request is in flight.
    @Published var editorialFeedbackLoading: Bool = false
    /// Human-readable error from the last feedback request, if any.
    @Published var editorialFeedbackError: String?
    /// Token usage from the last editorial critique request.
    @Published var editorialTokenUsage: EditorialTokenUsage?

    // MARK: - Smart albums state (Phase 7 SRCH-7)

    /// All saved search rules (smart albums), updated by savedSearchesStream observation.
    @Published var smartAlbums: [SavedSearchRule] = []
    /// ID of the currently active smart album (nil = no smart album selected).
    @Published var selectedSmartAlbumId: String?
    /// True while creating a new smart album.
    @Published var isCreatingSmartAlbum: Bool = false
    /// True while the SmartAlbumView creation sheet is presented.
    @Published var showSmartAlbumCreator: Bool = false

    private var smartAlbumStreamTask: Task<Void, Never>?

    // MARK: - Similarity search state (Phase 7 SRCH-9)

    /// True while a similarity search is running.
    @Published var similarPhotosSearching: Bool = false
    /// Set to a human-readable error message if the last similarity search failed.
    @Published var similarPhotosError: String?

    // MARK: - Ingestion progress

    /// Current ingestion progress. Nil when no ingestion is running.
    @Published var ingestionProgress: IngestionProgress?
    /// True while ingestion is in progress.
    @Published var isIngesting: Bool = false

    // MARK: - Proxy generation progress

    /// Current proxy generation progress. Nil when no generation is running.
    @Published var proxyProgress: ProxyGenerationProgress?
    /// True while proxy generation is in progress.
    @Published var isGeneratingProxies: Bool = false

    // MARK: - Print Lab

    /// Shared PrintLabViewModel — persists across navigation so canvas state is not lost.
    @Published var printLabViewModel: PrintLabViewModel = PrintLabViewModel()

    // MARK: - Search

    /// Breadcrumb subtitle set by SearchHostView for toolbar display.
    @Published var searchBreadcrumbSubtitle: String = "Search"

    // MARK: - Private

    let photoRepo: PhotoRepository
    var activityService: ActivityEventService? = nil
    var outboxProcessor: EventOutboxProcessor? = nil
    private let driveRepo: DriveRepository
    private let proxyRepo: ProxyAssetRepository
    private let embeddingRepo: EmbeddingRepository
    private let db: AppDatabase
    private let searchClient = SearchClient()
    private let personRepo: PersonRepository
    /// Observes NSWorkspace mount/unmount notifications and publishes connected volumes.
    private var driveDetector = DriveDetector()
    private var photoStreamTask: Task<Void, Never>?
    private var driveStreamTask: Task<Void, Never>?
    private var ingestionTask: Task<Void, Never>?
    private var proxyGenerationTask: Task<Void, Never>?
    private var searchDebounceTask: Task<Void, Never>?
    private var searchGeneration: Int = 0
    private var printLabBreadcrumbCancellable: AnyCancellable?

    // MARK: - Init

    init(db: AppDatabase) {
        self.db = db
        self.photoRepo = PhotoRepository(db: db)
        self.driveRepo = DriveRepository(db: db)
        self.proxyRepo = ProxyAssetRepository(db: db)
        self.embeddingRepo = EmbeddingRepository(db: db)
        self.personRepo = PersonRepository(db: db)

        // Forward breadcrumb changes from PrintLabViewModel so the toolbar re-renders
        printLabBreadcrumbCancellable = printLabViewModel.$breadcrumbSubtitle
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: - Observation lifecycle

    func startObserving() {
        photoStreamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await batch in await photoRepo.allPhotosStream() {
                    self.photos = batch
                    // Invalidate cached library context when photo set changes
                    self.libraryContext = nil
                }
            } catch {
                // Observation ended (e.g. db closed). Non-fatal in normal operation.
            }
        }
        driveStreamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await batch in await driveRepo.allDrivesStream() {
                    self.drives = batch
                }
            } catch {
                // Observation ended.
            }
        }
        // Load initial curation counts
        Task { await refreshCurationCounts() }
        // Check Cloud AI availability
        Task {
            let configured = await AnthropicAuthManager().isConfigured()
            await MainActor.run { self.cloudAIConfigured = configured }
        }
    }

    func stopObserving() {
        photoStreamTask?.cancel()
        driveStreamTask?.cancel()
        ingestionTask?.cancel()
        proxyGenerationTask?.cancel()
        searchDebounceTask?.cancel()
        smartAlbumStreamTask?.cancel()
        photoStreamTask = nil
        driveStreamTask = nil
        ingestionTask = nil
        proxyGenerationTask = nil
        searchDebounceTask = nil
        smartAlbumStreamTask = nil
    }

    // MARK: - Derived state

    var selectedPhoto: PhotoAsset? {
        if let id = selectedPhotoID {
            return photos.first(where: { $0.id == id })
        }
        return photos.first
    }

    var filteredPhotos: [PhotoAsset] {
        // Smart album overrides text search (smart albums are explicit selections)
        // If search results are populated, use them; otherwise show all photos
        var result = !searchResults.isEmpty ? searchResults : displayedPhotos

        if let filter = curationFilter {
            // Explicit filter selected — show only that state (including deleted)
            result = result.filter { $0.curationState == filter.rawValue }
        } else {
            // "All" view hides soft-deleted photos
            result = result.filter { $0.curationState != CurationState.deleted.rawValue }
        }

        return result
    }

    /// Header text shown when a smart album is active.
    var smartAlbumHeader: String? {
        guard let albumId = selectedSmartAlbumId,
              let album = smartAlbums.first(where: { $0.id == albumId }) else {
            return nil
        }
        return "Smart Album: \(album.name)"
    }

    // MARK: - Actions

    func select(_ photo: PhotoAsset) {
        selectedPhotoID = photo.id
    }

    /// Filter the library grid to show only photos with the given IDs.
    /// Pass an empty array to clear the filter.
    func filterToPhotoIds(_ ids: [String]) {
        let idSet = Set(ids)
        searchResults = photos.filter { idSet.contains($0.id) }
    }

    /// Navigate to Print Lab and add a photo to the canvas.
    /// Loads the proxy image from disk and appends a CanvasImage to PrintLabViewModel.
    /// If no proxy exists, the image is still added (with an empty NSImage placeholder).
    func sendToPrintLab(_ photo: PhotoAsset) {
        selectedSection = .printLab

        // Load proxy image and add to PrintLabViewModel canvas
        let baseName = (photo.canonicalName as NSString).deletingPathExtension
        let proxyURL = ProxyGenerationActor.proxiesDirectory()
            .appendingPathComponent(baseName + ".jpg")
        let img: NSImage = NSImage(contentsOf: proxyURL) ?? NSImage()
        let canvasImg = CanvasImage(
            photoAsset: photo,
            sourceImage: img,
            position: CGPoint(
                x: printLabViewModel.marginLeft,
                y: printLabViewModel.marginTop
            ),
            size: CGSize(
                width:  printLabViewModel.paperWidth  - printLabViewModel.marginLeft - printLabViewModel.marginRight,
                height: printLabViewModel.paperHeight - printLabViewModel.marginTop  - printLabViewModel.marginBottom
            )
        )
        printLabViewModel.addCanvasImage(canvasImg)
    }

    /// Receive an NSImage from Studio and send it to Print Lab, carrying provenance metadata.
    func receiveStudioImage(_ image: NSImage, sourcePhotoId: String? = nil, medium: String? = nil, renderDate: Date? = nil) {
        selectedSection = .printLab

        // Try to find the source photo for the layer name
        var layerPhoto: PhotoAsset? = nil
        if let photoId = sourcePhotoId {
            layerPhoto = photos.first(where: { $0.id == photoId })
        }

        var canvasImg = CanvasImage(
            sourceImage: image,
            position: CGPoint(
                x: printLabViewModel.marginLeft,
                y: printLabViewModel.marginTop
            ),
            size: CGSize(
                width:  printLabViewModel.paperWidth  - printLabViewModel.marginLeft - printLabViewModel.marginRight,
                height: printLabViewModel.paperHeight - printLabViewModel.marginTop  - printLabViewModel.marginBottom
            )
        )
        canvasImg.photoAsset = layerPhoto
        printLabViewModel.addCanvasImage(canvasImg)
    }

    /// Navigate to Library and select the given photo.
    func navigateToPhoto(id: String) {
        selectedSection = .library
        selectedPhotoID = id
    }

    /// Navigate to Studio and load the given photo by ID.
    /// Uses a short delay to ensure the Studio view is mounted before posting the load notification.
    func openInStudio(photoId: String) {
        if let photo = photos.first(where: { $0.id == photoId }) {
            selectedSection = .studio
            // Delay to let the Studio view mount before posting
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NotificationCenter.default.post(
                    name: .openInStudio,
                    object: nil,
                    userInfo: ["photo": photo]
                )
            }
        }
    }

    /// Permanently delete photos from the DB and move their files to the Finder Trash.
    func permanentlyDelete(ids: Set<String>) async {
        do {
            try await photoRepo.permanentlyDelete(ids: ids)
            selectedPhotoIDs = selectedPhotoIDs.subtracting(ids)
            await refreshCurationCounts()
        } catch {
            print("Error permanently deleting photos: \(error)")
        }
    }

    /// Navigate to Workflow with a single photo queued for processing.
    func sendToWorkflow(_ photo: PhotoAsset) {
        workflowPhotoIDs = [photo.id]
        selectedSection = .workflows
    }

    /// Refresh curation state counts from the database.
    /// Called once in startObserving() and after any curation state mutation.
    /// Errors are silently logged to console.
    func refreshCurationCounts() async {
        do {
            curationCounts = try await photoRepo.curationCounts()
        } catch {
            print("Error refreshing curation counts: \(error)")
        }
    }

    /// Apply a curation state to a set of photos, then refresh counts and clear selection.
    /// Errors are silently logged to console.
    func applyCuration(_ state: CurationState, to ids: Set<String>) async {
        do {
            try await photoRepo.bulkUpdateCurationState(ids: ids, state: state)
            await refreshCurationCounts()
            selectedPhotoIDs = []
        } catch {
            print("Error applying curation state: \(error)")
        }
    }

    /// Restore a heterogeneous set of per-photo curation states (used by undo toast).
    /// Groups photos by their previous state and applies each group in a single batch.
    func restoreCurationStates(_ states: [(id: String, state: CurationState)]) async {
        // Group by target state to minimize round-trips
        var grouped: [CurationState: Set<String>] = [:]
        for entry in states {
            grouped[entry.state, default: []].insert(entry.id)
        }
        do {
            for (state, ids) in grouped {
                try await photoRepo.bulkUpdateCurationState(ids: ids, state: state)
            }
            await refreshCurationCounts()
        } catch {
            print("Error restoring curation states: \(error)")
        }
    }

    /// Curate the currently-focused single photo (P / X / U shortcuts).
    /// When `autoAdvance` is true, moves focus to the next photo after applying the state
    /// (mirrors Lightroom's P and X behaviour — U clears without advancing).
    func curateSelected(_ state: CurationState, autoAdvance: Bool = false) async {
        guard let id = selectedPhotoID else { return }
        do {
            try await photoRepo.bulkUpdateCurationState(ids: [id], state: state)
            await refreshCurationCounts()
        } catch {
            print("Error curating selected photo: \(error)")
            return
        }
        guard autoAdvance else { return }
        let photos = filteredPhotos
        guard let idx = photos.firstIndex(where: { $0.id == id }), idx + 1 < photos.count else { return }
        selectedPhotoID = photos[idx + 1].id
    }

    // MARK: - Search

    /// Schedule a debounced search execution.
    /// Cancels any pending search and waits 400ms before executing.
    /// Skipped when a face/similarity search is in progress to avoid overwriting those results.
    func scheduleSearch() {
        // Don't schedule NL search when a face/person/similarity search is running
        guard !similarPhotosSearching else { return }

        searchDebounceTask?.cancel()
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)  // 400ms
            guard !Task.isCancelled else { return }
            await self?.executeSearch()
        }
    }

    /// Execute the search immediately using the current searchText.
    /// Parses query into a SearchIntent (filter + people + view hints),
    /// then intersects filter results with per-person photo IDs.
    func executeSearch() async {
        // Cancel any pending debounced search to avoid duplicate API calls
        searchDebounceTask?.cancel()

        // If search text is empty, clear results
        if searchText.isEmpty {
            searchResults = []
            lastFilter = nil
            lastIntent = nil
            return
        }

        isSearching = true
        searchGeneration += 1
        let thisGeneration = searchGeneration

        do {
            // 1. Fetch known people for name injection
            let knownPeople = (try? await personRepo.fetchAll()) ?? []
            let knownNames = knownPeople.map(\.name)

            // 2. Parse query → SearchIntentRaw
            let raw = await searchClient.searchChain(query: searchText, knownPeople: knownNames)

            // 3. Resolve person names via fuzzy matching
            let queryNames = raw.personNames ?? []
            let (resolved, unresolved) = PersonNameResolver.resolve(
                queryNames: queryNames,
                knownPeople: knownPeople
            )

            var intent = SearchIntent(
                filter: raw.filter,
                resolvedPeople: resolved,
                unresolvedNames: unresolved,
                preferMapView: raw.preferMapView ?? false
            )

            // 4. Run filter-based search
            var resultSets: [Set<String>] = []

            if !raw.filter.isEmpty {
                let filterResults = try await photoRepo.search(filter: raw.filter)
                resultSets.append(Set(filterResults.map(\.id)))
            }

            // 5. For each resolved person, get their photo IDs
            let faceRepo = FaceEmbeddingRepository(db: db)
            for person in resolved {
                let photoIds = try await faceRepo.fetchPhotoIds(forPersonId: person.personId)
                if photoIds.isEmpty {
                    intent.emptyPeople.append(person.personName)
                } else {
                    resultSets.append(Set(photoIds))
                }
            }

            // 6. Intersect all sets (AND logic)
            let finalIds: Set<String>
            if resultSets.isEmpty {
                finalIds = []
            } else if resultSets.count == 1 {
                finalIds = resultSets[0]
            } else {
                var intersection = resultSets[0]
                for set in resultSets.dropFirst() {
                    intersection = intersection.intersection(set)
                }
                // If intersection is empty but individual sets are non-empty, fall back to union
                if intersection.isEmpty {
                    intersection = resultSets.reduce(into: Set<String>()) { $0.formUnion($1) }
                    intent.usedUnionFallback = true
                }
                finalIds = intersection
            }

            // Guard against stale response from a superseded query
            guard thisGeneration == searchGeneration else { return }

            let results = finalIds.isEmpty ? [] : try await photoRepo.fetchByIds(Array(finalIds))
            // Sort results by picture date (newest first) for consistent display order
            searchResults = results.sorted {
                ($0.dateModified ?? $0.createdAt) > ($1.dateModified ?? $1.createdAt)
            }
            lastFilter = intent.filter
            lastIntent = intent
            isSearching = false
        } catch {
            guard thisGeneration == searchGeneration else { return }
            isSearching = false
        }
    }

    // MARK: - Search helpers (conversational search access)

    /// Fetch known person names for search context.
    func fetchKnownPersonNames() async -> [String] {
        ((try? await personRepo.fetchAll()) ?? []).map(\.name)
    }

    /// Refine a conversational search query through Claude.
    func refineSearchQuery(
        messages: [(role: String, content: String)],
        currentFilter: SearchFilter,
        photoCount: Int? = nil
    ) async -> ConversationResponse {
        let knownNames = await fetchKnownPersonNames()
        let context = await ensureLibraryContext()
        return await searchClient.refineChain(
            messages: messages,
            currentFilter: currentFilter,
            knownPeople: knownNames,
            photoCount: photoCount,
            libraryContext: context?.promptSnippet()
        )
    }

    /// Compute and cache library context for search prompts.
    func ensureLibraryContext() async -> LibraryContext? {
        if let cached = libraryContext { return cached }
        do {
            let stats = try await photoRepo.libraryStats()
            let people = try await personRepo.fetchPeopleWithPhotoCounts()
            let context = LibraryContext(
                totalPhotos: stats.totalPhotos,
                curationBreakdown: stats.curationBreakdown,
                dateRange: stats.dateRange,
                sceneDistribution: stats.sceneDistribution,
                peopleWithCounts: people,
                printJobCount: stats.printJobCount
            )
            libraryContext = context
            return context
        } catch {
            print("[LibraryViewModel] Failed to compute library context: \(error)")
            return nil
        }
    }

    /// Resolve person names to photo IDs.
    /// Multiple people = intersect (photos where ALL appear). Returns empty set (not nil) when
    /// intersection is empty so callers can distinguish "no people requested" from "no overlap".
    private func resolvePersonPhotoIds(_ personNames: [String]) async throws -> Set<String>? {
        guard !personNames.isEmpty else { return nil }
        let knownPeople = (try? await personRepo.fetchAll()) ?? []
        let (resolved, _) = PersonNameResolver.resolve(
            queryNames: personNames,
            knownPeople: knownPeople
        )
        guard !resolved.isEmpty else { return nil }
        let faceRepo = FaceEmbeddingRepository(db: db)
        var perPersonSets: [Set<String>] = []
        for person in resolved {
            let photoIds = try await faceRepo.fetchPhotoIds(forPersonId: person.personId)
            perPersonSets.append(Set(photoIds))
        }
        guard !perPersonSets.isEmpty else { return nil }
        // Intersect: photos where all mentioned people appear
        var result = perPersonSets[0]
        for set in perPersonSets.dropFirst() {
            result = result.intersection(set)
        }
        return result
    }

    /// Combine filter results and person results: strict intersection when both present.
    /// Empty intersection = no photos match both criteria = 0 results (not a fallback to union).
    private func combineSearchSets(filterIds: Set<String>?, personIds: Set<String>?) -> Set<String> {
        switch (filterIds, personIds) {
        case let (f?, p?):   return f.intersection(p)
        case let (f?, nil):  return f
        case let (nil, p?):  return p
        case (nil, nil):     return []
        }
    }

    /// Result from a preview search including nearby-match hints when results are empty.
    struct PreviewResult {
        let photos: [PhotoAsset]
        let count: Int
        /// When count is 0, describes what each individual criterion would match.
        /// e.g. "8 Mike photos · 6 Lewes photos — but none overlap"
        let nearbyHint: String?
    }

    /// Preview search that respects both filter and person names — returns limited results for thumbnails.
    func previewConversationSearch(filter: SearchFilter, personNames: [String], limit: Int = 8) async -> PreviewResult {
        do {
            let filterIds: Set<String>? = filter.isEmpty ? nil : Set(try await photoRepo.search(filter: filter).map(\.id))
            let personIds = try await resolvePersonPhotoIds(personNames)
            let finalIds = combineSearchSets(filterIds: filterIds, personIds: personIds)

            if !finalIds.isEmpty {
                let allResults = try await photoRepo.fetchByIds(Array(finalIds))
                let sorted = allResults.sorted {
                    ($0.dateModified ?? $0.createdAt) > ($1.dateModified ?? $1.createdAt)
                }
                return PreviewResult(photos: Array(sorted.prefix(limit)), count: sorted.count, nearbyHint: nil)
            }

            // 0 results — build a hint showing what each criterion matches individually
            var parts: [String] = []
            if let fIds = filterIds {
                let filterDesc = [filter.location, filter.cameraModel, filter.sceneType, filter.curationState]
                    .compactMap { $0 }.joined(separator: " ")
                let label = filterDesc.isEmpty ? "filter" : filterDesc
                parts.append("\(fIds.count) \(label) photo\(fIds.count == 1 ? "" : "s")")
            }
            if let pIds = personIds, !personNames.isEmpty {
                if pIds.isEmpty && personNames.count > 1 {
                    // Show per-person counts so the user knows each person exists but they're never together
                    let faceRepo = FaceEmbeddingRepository(db: db)
                    let knownPeople = (try? await personRepo.fetchAll()) ?? []
                    let (resolved, _) = PersonNameResolver.resolve(queryNames: personNames, knownPeople: knownPeople)
                    for person in resolved {
                        let count = (try? await faceRepo.fetchPhotoIds(forPersonId: person.personId).count) ?? 0
                        if count > 0 {
                            parts.append("\(count) \(person.personName) photo\(count == 1 ? "" : "s")")
                        }
                    }
                } else {
                    parts.append("\(pIds.count) \(personNames.joined(separator: "/")) photo\(pIds.count == 1 ? "" : "s")")
                }
            }
            let hint: String?
            if personIds?.isEmpty == true && personNames.count > 1 && !parts.isEmpty {
                hint = "\(parts.joined(separator: " · ")) — but they never appear together"
            } else if parts.count >= 2 {
                hint = "\(parts.joined(separator: " · ")) — but none overlap"
            } else {
                hint = parts.first.map { "Only \($0) found, but they don't match the other criteria" }
            }

            return PreviewResult(photos: [], count: 0, nearbyHint: hint)
        } catch {
            return PreviewResult(photos: [], count: 0, nearbyHint: nil)
        }
    }

    // MARK: - Conversational search execution

    /// Execute a search using an accumulated filter and person names from the conversation.
    func executeConversationSearch(filter: SearchFilter, personNames: [String]) async {
        isSearching = true
        searchGeneration += 1
        let thisGeneration = searchGeneration

        do {
            let filterIds: Set<String>? = filter.isEmpty ? nil : Set(try await photoRepo.search(filter: filter).map(\.id))
            let personIds = try await resolvePersonPhotoIds(personNames)
            let finalIds = combineSearchSets(filterIds: filterIds, personIds: personIds)

            guard thisGeneration == searchGeneration else { return }

            let results = finalIds.isEmpty ? [] : try await photoRepo.fetchByIds(Array(finalIds))
            searchResults = results.sorted {
                ($0.dateModified ?? $0.createdAt) > ($1.dateModified ?? $1.createdAt)
            }
            lastFilter = filter
            isSearching = false
        } catch {
            guard thisGeneration == searchGeneration else { return }
            isSearching = false
        }
    }

    // MARK: - Editorial feedback (M7.2 / M7.3)

    /// Request Claude editorial critique for the given photo.
    ///
    /// - Checks Anthropic auth first — if key missing, sets `editorialFeedbackError` with instructions.
    /// - Loads prior thread entries and photo metadata for context.
    /// - Calls `EditorialCritiqueService.requestEditorialFeedback()`.
    /// - Updates `editorialFeedback` on success or `editorialFeedbackError` on failure.
    ///
    /// - Parameters:
    ///   - photoId: The canonical ID of the photo to critique.
    ///   - db: Live AppDatabase instance; if nil, shows an auth/setup error.
    func requestEditorialFeedback(for photoId: String, scope: ReviewScope = .full, db: AppDatabase?) async {
        guard let db else {
            editorialFeedbackError = "Database not available."
            return
        }

        let authManager = AnthropicAuthManager()

        // Check auth before showing loading state
        let isConfigured = await authManager.isConfigured()
        guard isConfigured else {
            editorialFeedbackError = "Anthropic API key not configured. Go to Settings > Cloud AI to add your key."
            return
        }

        editorialFeedbackLoading = true
        editorialFeedbackError = nil
        editorialFeedback = nil
        editorialFeedbackPhotoId = photoId
        editorialTokenUsage = nil

        do {
            // Load thread history for context
            let threadRepo = ThreadRepository(db: db)
            let threadHistory = try await threadRepo.thread(for: photoId)

            // Resolve proxy URL
            let fm = FileManager.default
            let appSupport = (try? fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            let proxyDirectory = appSupport
                .appendingPathComponent("HoehnPhotosOrganizer")
                .appendingPathComponent("proxies")

            let photo = photos.first(where: { $0.id == photoId })
            let baseName = ((photo?.canonicalName ?? photoId) as NSString).deletingPathExtension
            let proxyURL = proxyDirectory.appendingPathComponent(baseName + ".jpg")

            // Build metadata context string for enrichment
            let photoMetadata = buildEditorialMetadata(for: photo)

            let service = EditorialCritiqueService(authManager: authManager)
            let result = try await service.requestEditorialFeedback(
                photoAssetId: photoId,
                proxyImageURL: proxyURL,
                threadHistory: threadHistory,
                photoMetadata: photoMetadata,
                printAttemptHistory: nil,
                threadRepo: threadRepo,
                scope: scope
            )

            editorialFeedback = result.feedback
            editorialTokenUsage = result.tokenUsage

            // Enqueue durable activity event (outbox guarantees delivery)
            let feedback = result.feedback
            let usage    = result.tokenUsage
            let scoreText   = "\(feedback.compositionScore)/10"
            let readiness   = " · \(feedback.printReadiness)"
            let summary     = String(feedback.analysis.prefix(120))
            let costUSD     = usage.estimatedCostUSD
            let metaDict: [String: Any] = [
                "score": feedback.compositionScore,
                "print_readiness": feedback.printReadiness,
                "input_tokens": usage.inputTokens,
                "output_tokens": usage.outputTokens,
                "estimated_cost_usd": costUSD
            ]
            let metaJson = (try? JSONSerialization.data(withJSONObject: metaDict))
                .flatMap { String(data: $0, encoding: .utf8) }
            outboxProcessor?.enqueue(
                kind: .editorialReview,
                photoAssetId: photoId,
                title: "Editorial review — \(scoreText)\(readiness)",
                detail: summary,
                metadata: metaJson
            )
        } catch {
            editorialFeedbackError = error.localizedDescription
        }

        editorialFeedbackLoading = false
    }

    // MARK: - Background batch editorial review

    @Published var batchEditorialRunning: Bool = false
    @Published var batchEditorialProgress: (completed: Int, total: Int)? = nil

    /// Run editorial reviews in the background for multiple photos using Haiku for speed.
    /// Processes up to 4 photos concurrently. Results are written to the thread DB and
    /// surfaced via activity events — the user can keep working in the meantime.
    func runBatchEditorialReview(photoIds: [String], db: AppDatabase) async {
        guard !batchEditorialRunning else { return }

        let authManager = AnthropicAuthManager()
        guard await authManager.isConfigured() else {
            editorialFeedbackError = "Anthropic API key not configured. Go to Settings > Cloud AI to add your key."
            return
        }

        batchEditorialRunning = true
        let total = photoIds.count
        batchEditorialProgress = (0, total)

        let service = EditorialCritiqueService(authManager: authManager)
        let threadRepo = ThreadRepository(db: db)
        let proxyDir = ProxyGenerationActor.proxiesDirectory()

        var completed = 0

        await withTaskGroup(of: Void.self) { group in
            var pending = photoIds.makeIterator()
            let maxConcurrency = 4

            // Seed the group with initial tasks
            for _ in 0..<min(maxConcurrency, total) {
                guard let photoId = pending.next() else { break }
                group.addTask { [weak self] in
                    await self?.runSingleBatchReview(
                        photoId: photoId, service: service,
                        threadRepo: threadRepo, proxyDir: proxyDir, db: db
                    )
                }
            }

            // As each finishes, start the next
            for await _ in group {
                completed += 1
                batchEditorialProgress = (completed, total)
                if let photoId = pending.next() {
                    group.addTask { [weak self] in
                        await self?.runSingleBatchReview(
                            photoId: photoId, service: service,
                            threadRepo: threadRepo, proxyDir: proxyDir, db: db
                        )
                    }
                }
            }
        }

        batchEditorialRunning = false
        batchEditorialProgress = nil
    }

    private func runSingleBatchReview(
        photoId: String,
        service: EditorialCritiqueService,
        threadRepo: ThreadRepository,
        proxyDir: URL,
        db: AppDatabase
    ) async {
        let photo = photos.first(where: { $0.id == photoId })
        let baseName = ((photo?.canonicalName ?? photoId) as NSString).deletingPathExtension
        let proxyURL = proxyDir.appendingPathComponent(baseName + ".jpg")

        do {
            let result = try await service.requestBatchFeedback(
                photoAssetId: photoId,
                proxyImageURL: proxyURL,
                threadRepo: threadRepo
            )

            let feedback = result.feedback
            let usage = result.tokenUsage
            let scoreText = "\(feedback.compositionScore ?? 0)/10"
            let readiness = " · \(feedback.printReadiness ?? "unknown")"
            let summary = String((feedback.analysis ?? "").prefix(120))
            let metaDict: [String: Any] = [
                "score": feedback.compositionScore,
                "print_readiness": feedback.printReadiness,
                "input_tokens": usage.inputTokens,
                "output_tokens": usage.outputTokens,
                "estimated_cost_usd": usage.estimatedCostUSD
            ]
            let metaJson = (try? JSONSerialization.data(withJSONObject: metaDict))
                .flatMap { String(data: $0, encoding: .utf8) }
            outboxProcessor?.enqueue(
                kind: .editorialReview,
                photoAssetId: photoId,
                title: "Editorial review — \(scoreText)\(readiness)",
                detail: summary,
                metadata: metaJson
            )
            print("[BatchEditorial] \(baseName): \(scoreText)\(readiness) ($\(String(format: "%.4f", usage.estimatedCostUSD)))")
        } catch {
            print("[BatchEditorial] \(baseName): failed — \(error.localizedDescription)")
        }
    }

    /// Applies Claude's suggested numeric adjustments to the photo's stored adjustments_json.
    func applyEditorialAdjustments(to photoId: String, adjustments: SuggestedAdjustments, db: AppDatabase?) async {
        guard let db else { return }

        let existingJson = try? await db.dbPool.read { d -> String? in
            try String.fetchOne(d, sql: "SELECT adjustments_json FROM photo_assets WHERE id = ?", arguments: [photoId])
        }
        var photoAdj = existingJson.flatMap { PhotoAdjustments.decode(from: $0) } ?? PhotoAdjustments()

        if let v = adjustments.exposure   { photoAdj.exposure   = v }
        if let v = adjustments.contrast   { photoAdj.contrast   = v }
        if let v = adjustments.highlights { photoAdj.highlights = v }
        if let v = adjustments.shadows    { photoAdj.shadows    = v }
        if let v = adjustments.whites     { photoAdj.whites     = v }
        if let v = adjustments.blacks     { photoAdj.blacks     = v }
        if let v = adjustments.saturation { photoAdj.saturation = v }
        if let v = adjustments.vibrance   { photoAdj.vibrance   = v }

        guard let json = photoAdj.encodeToJSON() else { return }
        let now = ISO8601DateFormatter().string(from: Date())

        try? await db.dbPool.write { d in
            try d.execute(
                sql: "UPDATE photo_assets SET adjustments_json = ?, updated_at = ? WHERE id = ?",
                arguments: [json, now, photoId]
            )
        }

        // Enqueue durable adjustment event
        let rationale = adjustments.rationale ?? "Applied editorial adjustments"
        outboxProcessor?.enqueue(
            kind: .adjustment,
            photoAssetId: photoId,
            title: "Adjustment",
            detail: "Editorial · \(rationale)"
        )
    }

    /// Merges Claude's metadata enrichment into the photo's userMetadataJson.
    /// Never overwrites GPS coordinates that already exist in rawExifJson.
    func applyEditorialEnrichment(to photoId: String, enrichment: MetadataEnrichment, db: AppDatabase?) async {
        guard let db else { return }

        var existingUserMeta: String? = nil
        var existingExif: String? = nil
        do {
            let pair = try await db.dbPool.read { d -> (String?, String?) in
                guard let row = try Row.fetchOne(d, sql: "SELECT user_metadata_json, raw_exif_json FROM photo_assets WHERE id = ?", arguments: [photoId]) else {
                    return (nil, nil)
                }
                let userMeta: String? = row["user_metadata_json"]
                let exif: String? = row["raw_exif_json"]
                return (userMeta, exif)
            }
            existingUserMeta = pair.0
            existingExif = pair.1
        } catch {}

        var meta: [String: Any] = [:]
        if let existing = existingUserMeta,
           let data = existing.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            meta = dict
        }

        if let locationName = enrichment.locationName, meta["location_name"] == nil {
            meta["location_name"] = locationName
        }
        if let venue = enrichment.venue, meta["venue"] == nil {
            meta["venue"] = venue
        }
        if let mood = enrichment.mood, meta["mood"] == nil {
            meta["mood"] = mood
        }
        if let subjects = enrichment.subjects, !subjects.isEmpty {
            var existing = meta["subjects"] as? [String] ?? []
            for s in subjects where !existing.contains(s) { existing.append(s) }
            meta["subjects"] = existing
        }

        // Only apply GPS if raw EXIF doesn't already have it
        let exifHasGPS: Bool = {
            guard let exifStr = existingExif,
                  let data = exifStr.data(using: .utf8),
                  let exif = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return exif["GPSLatitude"] != nil || exif["gps_latitude"] != nil
        }()

        if !exifHasGPS, let coords = enrichment.coordinates {
            meta["latitude"] = coords.lat
            meta["longitude"] = coords.lon
        }

        guard let data = try? JSONSerialization.data(withJSONObject: meta),
              let json = String(data: data, encoding: .utf8) else { return }

        let now = ISO8601DateFormatter().string(from: Date())
        try? await db.dbPool.write { d in
            try d.execute(
                sql: "UPDATE photo_assets SET user_metadata_json = ?, updated_at = ? WHERE id = ?",
                arguments: [json, now, photoId]
            )
        }
    }

    /// Builds a plain-text metadata context string for Claude to use in enrichment.
    private func buildEditorialMetadata(for photo: PhotoAsset?) -> String? {
        guard let photo else { return nil }
        var lines: [String] = []

        if let exifJson = photo.rawExifJson,
           let data = exifJson.data(using: .utf8),
           let exif = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let keys = ["DateTimeOriginal", "Make", "Model", "FocalLength", "FocalLengthIn35mmFormat",
                        "ISO", "ExposureTime", "FNumber", "GPSLatitude", "GPSLongitude",
                        "GPSLatitudeRef", "GPSLongitudeRef"]
            for key in keys {
                if let val = exif[key] { lines.append("\(key): \(val)") }
            }
        }

        if let userJson = photo.userMetadataJson,
           let data = userJson.data(using: .utf8),
           let user = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let keys = ["location_name", "venue", "tags", "notes", "subjects"]
            for key in keys {
                if let val = user[key] { lines.append("\(key): \(val)") }
            }
        }

        if let scene = photo.sceneType { lines.append("scene_type: \(scene)") }
        if let people = photo.peopleDetected { lines.append("people_detected: \(people)") }

        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: - Auto-Orient

    /// True while the auto-orient pass is running.
    @Published var isAutoOrienting: Bool = false
    /// (completed, total) progress snapshot, nil when not running.
    @Published var autoOrientProgress: (completed: Int, total: Int)? = nil

    /// Classify and physically rotate proxy + thumbnail files for all proxyReady photos.
    ///
    /// Uses Vision face detection (primary) and a luminance gravity heuristic (fallback)
    /// to determine the correct upright orientation. Stale face embeddings are deleted for
    /// any image that was rotated; they will be re-detected on the next face-detection pass.
    ///
    /// - Parameters:
    ///   - targetPhotos: Photos to orient. Defaults to all photos in the library.
    ///   - db: Live AppDatabase for face embedding cleanup.
    func runAutoOrient(targetPhotos: [PhotoAsset]? = nil, db: AppDatabase) async {
        guard !isAutoOrienting else { return }
        isAutoOrienting = true

        let classifier = OrientationClassificationService()
        let faceRepo   = FaceEmbeddingRepository(db: db)

        let candidates = (targetPhotos ?? photos).filter {
            $0.processingState == ProcessingState.proxyReady.rawValue
        }
        let total = candidates.count
        autoOrientProgress = (0, total)

        let proxiesDir = ProxyGenerationActor.proxiesDirectory()
        let thumbsDir  = ProxyGenerationActor.thumbsDirectory()

        for (index, photo) in candidates.enumerated() {
            let baseName = (photo.canonicalName as NSString).deletingPathExtension
            let proxyURL = proxiesDir.appendingPathComponent(baseName + ".jpg")
            let thumbURL = thumbsDir.appendingPathComponent(baseName + ".jpg")

            guard FileManager.default.fileExists(atPath: proxyURL.path) else {
                autoOrientProgress = (index + 1, total)
                continue
            }

            let result = await classifier.classify(proxyURL: proxyURL)

            if result.rotationDegrees != 0 {
                await applyRotation(result.rotationDegrees, to: proxyURL)
                await applyRotation(result.rotationDegrees, to: thumbURL)
                try? await faceRepo.deleteByPhotoId(photo.id)
                // Touch updatedAt so the grid tile reloads the rotated proxy image
                let now = ISO8601DateFormatter().string(from: .now)
                try? await db.dbPool.write { conn in
                    try conn.execute(
                        sql: "UPDATE photo_assets SET updated_at = ? WHERE id = ?",
                        arguments: [now, photo.id]
                    )
                }
                print("[AutoOrient] \(photo.canonicalName): \(result.rotationDegrees)°CW via \(result.method) (conf \(String(format: "%.2f", result.confidence)))")
            }

            autoOrientProgress = (index + 1, total)
        }

        isAutoOrienting = false
        autoOrientProgress = nil
    }

    /// Physically rotate a JPEG file by `degrees` clockwise in place.
    private func applyRotation(_ degrees: Int, to url: URL) async {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg  = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }

            let srcW = cg.width, srcH = cg.height
            let (dstW, dstH) = degrees == 180 ? (srcW, srcH) : (srcH, srcW)

            guard let cs  = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(
                      data: nil, width: dstW, height: dstH,
                      bitsPerComponent: 8, bytesPerRow: 0,
                      space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                  ) else { return }

            switch degrees {
            case 90:   // CW
                ctx.translateBy(x: 0, y: CGFloat(dstH))
                ctx.rotate(by: -.pi / 2)
            case 180:
                ctx.translateBy(x: CGFloat(dstW), y: CGFloat(dstH))
                ctx.rotate(by: .pi)
            case 270:  // CCW
                ctx.translateBy(x: CGFloat(dstW), y: 0)
                ctx.rotate(by: .pi / 2)
            default:
                return
            }

            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(srcW), height: CGFloat(srcH)))

            guard let rotated = ctx.makeImage(),
                  let dest = CGImageDestinationCreateWithURL(
                      url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
                  ) else { return }
            CGImageDestinationAddImage(dest, rotated,
                [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }.value
    }

    // MARK: - Image adjustments (XMP sidecar)

    /// True while adjustments are being written to disk.
    @Published var isApplyingAdjustments: Bool = false
    /// Human-readable result from the last adjustment save, or nil.
    @Published var adjustmentResult: String?

    /// Apply adjustments to the current multi-selection (or single photo if no selection).
    ///
    /// Writes XMP sidecars next to each source file and logs to activity_log.
    func applyAdjustments(_ adjustments: [ImageAdjustment], db: AppDatabase) async {
        // Resolve targets: use multi-selection if active, else single selected photo
        let targetIDs: Set<String> = selectedPhotoIDs.isEmpty
            ? selectedPhotoID.map { [$0] }.map(Set.init) ?? []
            : selectedPhotoIDs

        guard !targetIDs.isEmpty else {
            adjustmentResult = "No photos selected."
            return
        }

        let targetPhotos = photos.filter { targetIDs.contains($0.id) }
        isApplyingAdjustments = true
        adjustmentResult = nil

        do {
            let service = ImageAdjustmentService()
            let count = try await service.applyAdjustments(to: targetPhotos, adjustments: adjustments, db: db)
            adjustmentResult = "Adjustments saved to \(count) photo\(count == 1 ? "" : "s")."
        } catch {
            adjustmentResult = error.localizedDescription
        }

        isApplyingAdjustments = false
    }

    // MARK: - Photoshop integration (M7.5 / EXT-3)

    /// True while a curve is being applied to Photoshop.
    @Published var isApplyingCurveToPhotoshop: Bool = false
    /// Human-readable result message from the last curve application attempt.
    @Published var curveApplicationResult: String?
    /// True if the last curve application resulted in an error.
    @Published var curveApplicationIsError: Bool = false

    /// Apply an editorial feedback curve to the active Photoshop document in one click.
    ///
    /// Workflow:
    /// 1. Check Photoshop is running via PhotoshopAutomationService.detectPhotoshop()
    /// 2. Generate JSX from curve data via PhotoshopJSXGenerator.generateJSX(_:)
    /// 3. Send JSX to Photoshop via PhotoshopAutomationService.applyJSX(_:)
    /// 4. Update published state with success or error result
    ///
    /// - Parameter curveData: The CurveData to apply (from CurveGenerationService).
    func applyCurveToPhotoshop(_ curveData: CurveData) async {
        isApplyingCurveToPhotoshop = true
        curveApplicationResult = nil
        curveApplicationIsError = false

        do {
            let automationService = PhotoshopAutomationService()

            // Check Photoshop is running before generating JSX
            let isRunning = try await automationService.detectPhotoshop()
            guard isRunning else {
                throw PhotoshopError.notRunning
            }

            // Generate JSX from curve data
            let jsxGenerator = PhotoshopJSXGenerator()
            let jsx = try await jsxGenerator.generateJSX(from: curveData)

            // Send to Photoshop
            _ = try await automationService.applyJSX(jsx: jsx)

            curveApplicationResult = "Curve applied to Photoshop"
            curveApplicationIsError = false
        } catch {
            curveApplicationResult = error.localizedDescription
            curveApplicationIsError = true
        }

        isApplyingCurveToPhotoshop = false
    }

    // MARK: - Smart Albums (SRCH-7)

    /// Load all smart album rules from the database and set up live stream observation.
    ///
    /// - Parameter db: The live AppDatabase instance.
    func loadSmartAlbums(db: AppDatabase) async {
        do {
            let repo = SavedSearchRepository(db: db)
            smartAlbums = try await repo.fetchAllSavedSearches()

            // Set up live observation so smart albums refresh when new ones are created/deleted
            smartAlbumStreamTask?.cancel()
            smartAlbumStreamTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await albums in repo.savedSearchesStream() {
                        self.smartAlbums = albums
                    }
                } catch {
                    // Stream ended non-fatally (e.g. db closed during shutdown)
                }
            }
        } catch {
            print("Error loading smart albums: \(error)")
        }
    }

    /// Create a new smart album from a name and SearchFilter.
    ///
    /// Calls SavedSearchRepository.createSavedSearch(), reloads smartAlbums.
    ///
    /// - Parameters:
    ///   - name: Display name for the smart album.
    ///   - filters: Filter criteria to persist as SQL predicate.
    ///   - db: Live AppDatabase instance (nil treated as no-op with logged error).
    func createSavedSearch(name: String, filters: SearchFilter, db: AppDatabase?) async {
        guard let db else {
            print("createSavedSearch: database not available")
            return
        }
        do {
            isCreatingSmartAlbum = true
            let repo = SavedSearchRepository(db: db)
            _ = try await repo.createSavedSearch(name: name, filters: filters)
            // Smart albums stream will auto-refresh via savedSearchesStream observation.
            // Explicit reload as fallback in case stream hasn't fired yet.
            smartAlbums = try await repo.fetchAllSavedSearches()
            isCreatingSmartAlbum = false
        } catch {
            isCreatingSmartAlbum = false
            print("Error creating smart album: \(error)")
        }
    }

    /// Select a smart album and populate searchResults with matching photos.
    ///
    /// Clears any active text search and executes the smart album's SQL predicate.
    ///
    /// - Parameters:
    ///   - albumId: The `id` of the `SavedSearchRule` to select.
    ///   - db: Live AppDatabase instance.
    func selectSmartAlbum(albumId: String, db: AppDatabase) async {
        selectedSmartAlbumId = albumId
        searchText = ""
        lastIntent = nil

        do {
            let repo = SavedSearchRepository(db: db)
            searchResults = try await repo.executeSavedSearch(ruleId: albumId)
        } catch {
            print("Error executing smart album \(albumId): \(error)")
            searchResults = []
        }
    }

    /// Clear the active smart album selection and restore the full library view.
    func clearSmartAlbumSelection() {
        selectedSmartAlbumId = nil
        searchResults = []
    }

    /// Delete a smart album by ID.
    ///
    /// If the deleted album was selected, clears the selection.
    ///
    /// - Parameters:
    ///   - albumId: The `id` of the `SavedSearchRule` to delete.
    ///   - db: Live AppDatabase instance.
    func deleteSavedSearch(albumId: String, db: AppDatabase) async {
        do {
            let repo = SavedSearchRepository(db: db)
            try await repo.deleteSavedSearch(ruleId: albumId)
            if selectedSmartAlbumId == albumId {
                clearSmartAlbumSelection()
            }
        } catch {
            print("Error deleting smart album \(albumId): \(error)")
        }
    }

    // MARK: - Similarity search (SRCH-9)

    /// Runs ANN similarity search for the given photo ID and updates `filteredPhotos` with results.
    ///
    /// Call from SimilaritySearchView or any view that wants to populate the main grid
    /// with visually similar photos.  Errors are published via `similarPhotosError`.
    ///
    /// - Parameter photoId: The `id` of the reference `PhotoAsset`.
    /// - Parameter db: The live AppDatabase instance (injected from @Environment).
    func findSimilarPhotos(to photoId: String, db: AppDatabase) async {
        similarPhotosSearching = true
        similarPhotosError = nil
        lastIntent = nil

        do {
            let embeddingRepo = EmbeddingRepository(db: db)
            let photoRepo = PhotoRepository(db: db)
            let service = SimilaritySearchService(embeddingRepo: embeddingRepo, photoRepo: photoRepo)
            let results = try await service.findSimilarPhotos(to: photoId, limit: 20)
            searchResults = results
            similarPhotosSearching = false
        } catch {
            similarPhotosError = error.localizedDescription
            similarPhotosSearching = false
        }
    }

    /// Find photos containing the same person as the face at `faceIndex` in the given photo.
    /// Looks up the stored feature print for that face and runs similarity search across all embeddings.
    func searchByFace(photoId: String, faceIndex: Int, faceImage: NSImage?, db: AppDatabase) async {
        similarPhotosSearching = true
        similarPhotosError = nil
        lastIntent = nil

        // Store the face chip so the search toolbar can display who was searched
        faceQueryImage = faceImage

        do {
            let faceRepo = FaceEmbeddingRepository(db: db)
            let embeddings = try await faceRepo.fetchByPhotoId(photoId)
            print("[FaceSearch] embeddings stored for photo \(photoId): \(embeddings.count)")

            // Resolve the person name for this face (if labeled)
            let target = embeddings.first(where: { $0.faceIndex == faceIndex })
            var personName: String? = nil
            if let personId = target?.personId {
                let personRepo = PersonRepository(db: db)
                let people = try await personRepo.fetchAll()
                personName = people.first(where: { $0.id == personId })?.name
            }

            // If the face has a known person, use searchByPerson for accurate results
            if let personId = target?.personId, let name = personName {
                searchText = name
                let photoIds = try await faceRepo.fetchPhotoIds(forPersonId: personId)
                let results = try await photoRepo.fetchByIds(photoIds)
                searchResults = results
                selectedSection = .search
                similarPhotosSearching = false
                return
            }

            // Fall back to embedding similarity search
            guard let target, let featureData = target.featureData else {
                print("[FaceSearch] No stored embedding for face \(faceIndex) — run Re-index Faces in Settings › Machine Learning")
                searchText = "Unknown face"
                searchResults = []
                selectedSection = .search
                similarPhotosSearching = false
                return
            }

            searchText = personName ?? "Similar faces"
            let matchingIds = try await faceRepo.findSimilarPhotoIds(to: featureData, excludingPhotoId: photoId)
            let results = try await photoRepo.fetchByIds(matchingIds)
            searchResults = results
            selectedSection = .search
            similarPhotosSearching = false
        } catch {
            searchText = ""
            faceQueryImage = nil
            similarPhotosError = error.localizedDescription
            similarPhotosSearching = false
        }
    }

    func searchByPerson(personId: String, personName: String, faceImage: NSImage?, db: AppDatabase) async {
        similarPhotosSearching = true
        similarPhotosError = nil
        lastIntent = nil
        faceQueryImage = faceImage
        searchText = personName
        do {
            let faceRepo = FaceEmbeddingRepository(db: db)
            let photoIds = try await faceRepo.fetchPhotoIds(forPersonId: personId)
            let results = try await photoRepo.fetchByIds(photoIds)
            searchResults = results
            selectedSection = .search
            similarPhotosSearching = false
        } catch {
            searchText = ""
            faceQueryImage = nil
            similarPhotosError = error.localizedDescription
            similarPhotosSearching = false
        }
    }

    // MARK: - Proxy URL resolution (shared helper)

    /// Resolve the JPEG proxy URL for a given photo ID.
    ///
    /// Looks up the photo in the current `photos` array to find the canonical name,
    /// then constructs the expected path in the proxies directory.
    ///
    /// - Parameter photoId: The `id` of the `PhotoAsset`.
    /// - Returns: Expected URL for the proxy JPEG (may not exist on disk if not yet generated).
    func resolveProxyURL(for photoId: String) -> URL {
        let photo = photos.first(where: { $0.id == photoId })
        // Prefer stored proxyPath (set during drive import)
        if let stored = photo?.proxyPath {
            return URL(fileURLWithPath: stored)
        }
        // Fallback: derive from canonicalName (local imports, pre-Phase-14 records)
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let proxyDirectory = appSupport
            .appendingPathComponent("HoehnPhotosOrganizer")
            .appendingPathComponent("proxies")

        let baseName = ((photo?.canonicalName ?? photoId) as NSString).deletingPathExtension
        return proxyDirectory.appendingPathComponent(baseName + ".jpg")
    }

    /// Returns true if the drive with the given volume UUID is currently mounted.
    func isDriveConnected(uuid: String) -> Bool {
        driveDetector.mountedDrives.contains { $0.volumeUUID == uuid }
    }

    // MARK: - Generative rendering (M7.4)

    /// Generate a line-art or watercolor rendering of the given photo proxy.
    ///
    /// Resolves the proxy JPEG URL from Application Support, then calls the appropriate
    /// rendering service. Returns a rendered NSImage for immediate preview in
    /// GenerativeRenderingView.
    ///
    /// - Parameters:
    ///   - photoId: The canonical photo ID (used to find the proxy file).
    ///   - style: "lineArt" or "watercolor"
    ///   - intensity: Watercolor blend intensity (0.0–1.0). Used only when style == "watercolor".
    ///   - highContrast: If true, use high-contrast edge detection. Used only when style == "lineArt".
    ///   - db: Live AppDatabase (not used for rendering, kept for future enrichment).
    /// - Returns: NSImage containing the rendered result.
    /// - Throws: RenderingError if the proxy cannot be loaded or filter application fails.
    func generateRendering(
        photoId: String,
        style: String,
        intensity: Float? = nil,
        highContrast: Bool? = nil,
        db: AppDatabase
    ) async throws -> NSImage {
        let proxyURL = resolveProxyURL(for: photoId)

        let cgImage: CGImage
        if style == "lineArt" {
            let service = LineArtGenerationService()
            cgImage = try await service.generateLineArt(
                proxyImageURL: proxyURL,
                highContrast: highContrast ?? false
            )
        } else {
            let service = WatercolorRenderService()
            cgImage = try await service.generateWatercolor(
                proxyImageURL: proxyURL,
                intensity: intensity ?? 0.5
            )
        }

        let size = NSSize(width: cgImage.width, height: cgImage.height)
        return NSImage(cgImage: cgImage, size: size)
    }

    /// Save a rendered NSImage to the pipeline outputs directory and create an AssetLineage entry.
    ///
    /// Output filename pattern: {photoId}_{style}.jpg
    /// Operation recorded in asset_lineage: "generative_rendering"
    ///
    /// - Parameters:
    ///   - image: The rendered NSImage to save.
    ///   - photoId: Source photo's canonical ID.
    ///   - style: Rendering style ("lineArt" or "watercolor").
    ///   - db: Live AppDatabase for AssetLineage insertion.
    /// - Returns: Absolute path string of the saved output file.
    /// - Throws: RenderingError or file-system errors if save fails.
    func saveRenderingToOutputs(_ image: NSImage, photoId: String, style: String, db: AppDatabase) async throws -> String {
        // 1. Resolve output directory
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let outputDirectory = appSupport
            .appendingPathComponent("HoehnPhotosOrganizer")
            .appendingPathComponent("pipeline_outputs")
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // 2. Build output filename
        let safePhotoId = photoId.replacingOccurrences(of: "/", with: "_")
        let outputName = "\(safePhotoId)_\(style).jpg"
        let outputURL = outputDirectory.appendingPathComponent(outputName)

        // 3. Convert NSImage to JPEG data and write to disk
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else {
            throw RenderingError.filterFailed("Could not convert NSImage to JPEG data")
        }
        try jpegData.write(to: outputURL)

        // 4. Create PhotoAsset (role=workflowOutput) + AssetLineage (operation=generative_rendering)
        let fileSize = jpegData.count
        let outputAsset = PhotoAsset.new(
            canonicalName: outputName,
            role: .workflowOutput,
            filePath: outputURL.path,
            fileSize: fileSize
        )
        let now = ISO8601DateFormatter().string(from: Date())
        let lineage = AssetLineage(
            id: UUID().uuidString,
            parentPhotoId: photoId,
            childPhotoId: outputAsset.id,
            operation: "generative_rendering",
            frameIndex: nil,
            sourceFileName: outputName,
            createdAt: now,
            metadataJson: "{\"style\":\"\(style)\"}"
        )

        // Non-fatal DB write: image file is the source of truth; DB enrichment can retry later
        var mutableAsset = outputAsset
        do {
            try await db.dbPool.write { db in
                try mutableAsset.insert(db)
                try lineage.insert(db)
            }
        } catch {
            print("saveRenderingToOutputs: DB write failed (non-fatal): \(error)")
        }

        return outputURL.path
    }

    // MARK: - Direct file import

    /// AI job bucketing threshold: imports with more than this many photos
    /// use temporal/GPS clustering + Claude naming instead of simple folder/day grouping.
    /// User-configurable via @AppStorage; default ON for imports > 50 photos.
    @AppStorage("import.aiBucketingThreshold") private var aiBucketingThreshold: Int = 50

    /// Import one or more image files directly from disk (digital photos, DNGs, etc.).
    /// Creates a PhotoAsset row for each file not already in the catalog, then kicks off
    /// proxy generation so thumbnails appear without a separate ingestion step.
    ///
    /// For large imports (>= `aiBucketingThreshold` photos), uses AI job bucketing:
    /// temporal gap clustering + GPS reinforcement + Claude naming to create focused sub-jobs.
    func importDigitalPhotos(_ urls: [URL], db: AppDatabase, onEach: ((Int) -> Void)? = nil) async {
        // Deduplicate RAW+JPG pairs: prefer RAW, skip matching JPG
        let deduped = IngestionActor.deduplicateRawJpgPairs(urls)
        print("[Import] Starting import of \(deduped.count) photo(s) (from \(urls.count) files, \(urls.count - deduped.count) JPG duplicates removed)")

        // Phase 1: Insert all photos into DB first, collecting assets + EXIF
        var totalProcessed = 0
        var insertedAssets: [(id: String, url: URL, rawExifJson: String?)] = []

        for entry in deduped {
            let url = entry.url
            let canonicalName = url.lastPathComponent
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            var asset = PhotoAsset.new(
                canonicalName: canonicalName,
                role: .original,
                filePath: url.path,
                fileSize: fileSize
            )
            asset.processingState = ProcessingState.proxyPending.rawValue
            // importStatus defaults to "staged"

            // Extract EXIF — try RAW first, fall back to JPG companion if RAW has no date
            var exif = EXIFExtractor.extract(url: url)
            if exif.captureDate == nil, let jpgURL = entry.jpgCompanion {
                let jpgExif = EXIFExtractor.extract(url: jpgURL)
                if jpgExif.captureDate != nil {
                    exif = jpgExif
                    print("[Import] EXIF fallback to JPG companion for \(canonicalName)")
                }
            }
            let exifJson = exif.asCodable()
            if let data = try? JSONEncoder().encode(exifJson),
               let str = String(data: data, encoding: .utf8) {
                asset.rawExifJson = str
            }

            do {
                let wasInserted: Bool = try await db.dbPool.write { dbConn in
                    let exists = try PhotoAsset
                        .filter(Column("file_path") == url.path || Column("canonical_name") == canonicalName)
                        .fetchCount(dbConn) > 0
                    if exists {
                        print("[Import] Skipping duplicate: \(canonicalName)")
                        return false
                    }
                    try asset.insert(dbConn)
                    return true
                }
                if wasInserted {
                    insertedAssets.append((id: asset.id, url: url, rawExifJson: asset.rawExifJson))
                }
            } catch {
                print("[Import] Failed to insert \(canonicalName): \(error)")
            }
            totalProcessed += 1
            onEach?(totalProcessed)
        }

        guard !insertedAssets.isEmpty else {
            print("[Import] No new photos to import")
            return
        }

        // Diagnostic: EXIF extraction stats
        let exifSuccessCount = insertedAssets.filter({ $0.rawExifJson != nil }).count
        let exifFailCount = insertedAssets.count - exifSuccessCount
        print("[Import] EXIF extraction: \(exifSuccessCount) succeeded, \(exifFailCount) failed out of \(insertedAssets.count) photos")

        // Phase 2: Create a single import job (user can split via SplitJobSheet on-demand)
        let jobRepo = TriageJobRepository(db: db)
        let importTitle = "Import — \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none))"
        let allImportIds = insertedAssets.map(\.id)
        let importJob = try? await jobRepo.createImportJob(title: importTitle, photoIds: allImportIds, activityService: activityService)
        print("[Import] Created job: \(importTitle) (\(allImportIds.count) photos)")

        let totalInserted = insertedAssets.count
        print("[Import] Done — \(totalInserted) new asset(s)")
        if totalInserted > 0 {
            let batchMeta: String? = importJob.flatMap { job in
                (try? JSONSerialization.data(withJSONObject: ["job_id": job.id])).flatMap { String(data: $0, encoding: .utf8) }
            }
            outboxProcessor?.enqueue(
                kind: .importBatch,
                title: "Imported \(totalInserted) photo(s)",
                detail: "\(totalInserted) file(s) staged for review",
                metadata: batchMeta
            )
            startProxyGeneration(driveMount: URL(fileURLWithPath: "/"))
            selectedSection = .jobs
        }
    }

    /// Import photos with a pre-determined job name (from drive scan preview).
    /// Unlike `importDigitalPhotos`, this creates a single triage job with the given title
    /// instead of auto-clustering by folder/date. Used after the pre-import drive scan
    /// so the user's chosen job name is honored and no double-clustering occurs.
    func importDigitalPhotosWithJobName(
        _ urls: [URL], db: AppDatabase, jobName: String,
        onEach: ((Int) -> Void)? = nil
    ) async {
        print("[Import] Starting named import of \(urls.count) photo(s) as '\(jobName)'")

        var processed = 0
        var insertedPhotoIds: [String] = []

        for url in urls {
            let canonicalName = url.lastPathComponent
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            var asset = PhotoAsset.new(
                canonicalName: canonicalName,
                role: .original,
                filePath: url.path,
                fileSize: fileSize
            )
            asset.processingState = ProcessingState.proxyPending.rawValue

            // Extract EXIF before insert so rawExifJson is populated for later
            // clustering (Split Job) and metadata display.
            let exif = EXIFExtractor.extract(url: url)
            let exifJson = exif.asCodable()
            if let data = try? JSONEncoder().encode(exifJson),
               let str = String(data: data, encoding: .utf8) {
                asset.rawExifJson = str
            }

            do {
                let wasInserted: Bool = try await db.dbPool.write { dbConn in
                    let exists = try PhotoAsset
                        .filter(Column("file_path") == url.path || Column("canonical_name") == canonicalName)
                        .fetchCount(dbConn) > 0
                    if exists {
                        print("[Import] Skipping duplicate: \(canonicalName)")
                        return false
                    }
                    try asset.insert(dbConn)
                    return true
                }
                if wasInserted {
                    insertedPhotoIds.append(asset.id)
                }
            } catch {
                print("[Import] Failed to insert \(canonicalName): \(error)")
            }
            processed += 1
            onEach?(processed)
        }

        var createdJobId: String?
        if !insertedPhotoIds.isEmpty {
            let jobRepo = TriageJobRepository(db: db)
            do {
                let job = try await jobRepo.createImportJob(title: jobName, photoIds: insertedPhotoIds, activityService: activityService)
                createdJobId = job.id
                print("[Import] Created job: \(job.title) — \(insertedPhotoIds.count) photos")
            } catch {
                print("[Import] Failed to create triage job '\(jobName)': \(error)")
            }
        }

        print("[Import] Named import done — \(insertedPhotoIds.count) new asset(s)")
        if !insertedPhotoIds.isEmpty {
            let batchMeta: String? = createdJobId.flatMap { jobId in
                (try? JSONSerialization.data(withJSONObject: ["job_id": jobId])).flatMap { String(data: $0, encoding: .utf8) }
            }
            outboxProcessor?.enqueue(
                kind: .importBatch,
                title: "Imported \(insertedPhotoIds.count) photo(s)",
                detail: "\(insertedPhotoIds.count) file(s) staged for review",
                metadata: batchMeta
            )
            startProxyGeneration(driveMount: URL(fileURLWithPath: "/"))
            selectedSection = .jobs
        }
    }

    /// Groups URLs into named clusters for job creation.
    /// - Multiple parent folders -> one cluster per folder (folder name as title)
    /// - Single parent folder -> one cluster per calendar day (date as title)
    private func clusterURLsForImport(_ urls: [URL]) -> [(title: String, urls: [URL])] {
        guard !urls.isEmpty else { return [] }

        let byParent = Dictionary(grouping: urls) { $0.deletingLastPathComponent() }

        if byParent.count > 1 {
            return byParent
                .sorted { $0.key.path < $1.key.path }
                .map { (folder, folderURLs) in
                    (title: folder.lastPathComponent, urls: folderURLs.sorted { $0.path < $1.path })
                }
        }

        let cal = Calendar.current
        let byDay = Dictionary(grouping: urls) { url -> Date in
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            return cal.startOfDay(for: mod)
        }

        if byDay.count > 1 {
            return byDay
                .sorted { $0.key < $1.key }
                .map { (day, dayURLs) in
                    let title = day.formatted(Date.FormatStyle().month(.abbreviated).day().year())
                    return (title: title, urls: dayURLs.sorted { $0.path < $1.path })
                }
        }

        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        return [(title: "Import \(dateStr) — \(urls.count) photos", urls: urls)]
    }

    // MARK: - Clear library

    func clearLibrary(db: AppDatabase) async {
        do {
            try await db.dbPool.write { db in
                try db.execute(sql: "DELETE FROM photo_assets")
                try db.execute(sql: "DELETE FROM proxy_assets")
                try db.execute(sql: "DELETE FROM drives")
                try db.execute(sql: "DELETE FROM activity_log")
                try db.execute(sql: "DELETE FROM activity_events")
                try db.execute(sql: "DELETE FROM extraction_events")
                try db.execute(sql: "DELETE FROM extraction_tool_logs")
                try db.execute(sql: "DELETE FROM saved_searches")
                try db.execute(sql: "DELETE FROM asset_lineage")
                try db.execute(sql: "DELETE FROM collections")
                try db.execute(sql: "DELETE FROM collection_members")
                try db.execute(sql: "DELETE FROM thread_entries")
                try db.execute(sql: "DELETE FROM pipeline_runs")
                try db.execute(sql: "DELETE FROM pipeline_run_steps")
                try db.execute(sql: "DELETE FROM embeddings")
                try db.execute(sql: "DELETE FROM background_jobs")
                try db.execute(sql: "DELETE FROM adjustment_snapshots")
                try db.execute(sql: "DELETE FROM face_embeddings")
                try db.execute(sql: "DELETE FROM person_identities")
                try db.execute(sql: "DELETE FROM event_outbox")
                try db.execute(sql: "DELETE FROM todo_items")
                try db.execute(sql: "DELETE FROM triage_jobs")
                try db.execute(sql: "DELETE FROM triage_job_photos")
            }
            // Clear search history (stored in UserDefaults, not the database)
            UserDefaults.standard.removeObject(forKey: "search.recentQueries")
            await MainActor.run {
                photos = []
                drives = []
                selectedPhotoID = nil
                searchResults = []
                curationCounts = CurationCounts(keeper: 0, archive: 0, needsReview: 0, rejected: 0)
            }
            // Also clear all drive preview indexes so the Drives tab doesn't show stale state
            NotificationCenter.default.post(name: .didClearLibrary, object: nil)
        } catch {
            print("clearLibrary error: \(error)")
        }
    }

    // MARK: - Drive detection

    /// Live list of currently mounted external volumes, as reported by DriveDetector.
    /// Bound to NSWorkspace notifications — updates automatically on mount/unmount.
    var detectedDrives: [DriveInfo] {
        driveDetector.mountedDrives
    }

    // MARK: - Ingestion

    /// Starts a full ingestion run for the given drive.
    ///
    /// Progress is published via `ingestionProgress` and `isIngesting`.
    /// Once ingestion finishes, proxy generation is kicked off automatically.
    /// Unified import action: ingestion + proxy generation in one user-facing call.
    func startImport(drive: DriveInfo) {
        startIngestion(drive: drive)
    }

    func startIngestion(drive: DriveInfo) {
        guard !isIngesting else { return }
        isIngesting = true
        ingestionProgress = nil

        let photoRepo = self.photoRepo
        let driveRepo = self.driveRepo
        let driveMount = drive.mountPoint
        let driveUUID = drive.volumeUUID

        ingestionTask = Task { [weak self] in
            let actor = IngestionActor(photoRepo: photoRepo, driveRepo: driveRepo)
            for await progress in actor.startIngestion(drive: drive) {
                guard let self else { return }
                self.ingestionProgress = progress
            }
            guard let self else { return }
            self.isIngesting = false
            // Kick off proxy generation for newly indexed assets, passing driveUUID for stamping.
            self.startProxyGeneration(driveMount: driveMount, driveUUID: driveUUID)
        }
    }

    /// Cancels any in-progress ingestion run.
    func cancelIngestion() {
        ingestionTask?.cancel()
        ingestionTask = nil
        isIngesting = false
    }

    // MARK: - Proxy generation

    /// Starts background proxy generation for all proxyPending assets.
    ///
    /// Called automatically after ingestion completes, passing the same drive mount URL
    /// that was used during ingestion. Progress is published via `proxyProgress`.
    ///
    /// Multiple concurrent calls are no-ops — only one generation run at a time.
    func startProxyGeneration(driveMount: URL, driveUUID: String? = nil) {
        guard !isGeneratingProxies else { return }
        isGeneratingProxies = true
        proxyProgress = nil

        let photoRepo = self.photoRepo
        let proxyRepo = self.proxyRepo
        let embeddingRepo = self.embeddingRepo

        proxyGenerationTask = Task { [weak self] in
            let actor = ProxyGenerationActor(photoRepo: photoRepo, proxyRepo: proxyRepo, embeddingRepo: embeddingRepo)
            // Collect IDs of photos processed in this batch for face indexing
            var processedPhotoIds: [String] = []
            let pending = (try? await photoRepo.fetchByProcessingState(.proxyPending)) ?? []
            processedPhotoIds = pending.map(\.id)

            for await progress in actor.processQueue(driveMount: driveMount, driveUUID: driveUUID) {
                guard let self else { return }
                self.proxyProgress = progress
            }
            guard let self else { return }
            self.isGeneratingProxies = false

            // Background face indexing for newly imported photos
            if !processedPhotoIds.isEmpty {
                self.startBackgroundFaceIndexing(photoIds: processedPhotoIds)
            }
        }
    }

    /// Index faces for photos that haven't been face-indexed yet.
    /// Called automatically after proxy generation. Skips photos where `faceIndexedAt` is already set.
    @Published var isFaceIndexing = false

    func startBackgroundFaceIndexing(photoIds: [String]? = nil) {
        guard !isFaceIndexing else { return }
        isFaceIndexing = true
        faceIndexingProgress = "Detecting faces…"

        let photoRepo = self.photoRepo
        let capturedDb = self.db

        Task { [weak self] in
            let faceRepo = FaceEmbeddingRepository(db: capturedDb)

            // If specific IDs given, filter to those that haven't been indexed.
            // Otherwise, pick up all proxyReady photos missing faceIndexedAt.
            let photosToIndex: [PhotoAsset]
            if let ids = photoIds {
                let fetched = (try? await photoRepo.fetchByIds(ids)) ?? []
                photosToIndex = fetched.filter { $0.faceIndexedAt == nil }
            } else {
                photosToIndex = (try? await photoRepo.fetchNeedingFaceIndex()) ?? []
            }

            guard !photosToIndex.isEmpty else {
                await MainActor.run {
                    self?.faceIndexingProgress = ""
                    self?.isFaceIndexing = false
                }
                return
            }

            var indexed = 0
            let total = photosToIndex.count

            for photo in photosToIndex {
                let baseName = (photo.canonicalName as NSString).deletingPathExtension
                let proxyURL = ProxyGenerationActor.proxiesDirectory()
                    .appendingPathComponent(baseName + ".jpg")
                guard FileManager.default.fileExists(atPath: proxyURL.path) else {
                    // Mark as indexed even if proxy missing — avoids retrying forever
                    try? await photoRepo.markFaceIndexed(id: photo.id)
                    continue
                }

                let crops = await Task.detached(priority: .utility) {
                    FaceChipGrid.detectAndCropWithBounds(from: proxyURL)
                }.value

                let now = ISO8601DateFormatter().string(from: Date())
                for (index, pair) in crops.enumerated() {
                    let (cropImage, bbox) = pair
                    guard let cgImage = cropImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
                          let featureData = FaceEmbeddingService.generateFeaturePrint(for: cgImage) else { continue }
                    let record = FaceEmbedding(
                        id: UUID().uuidString,
                        photoId: photo.id,
                        faceIndex: index,
                        bboxX: bbox.minX, bboxY: bbox.minY, bboxWidth: bbox.width, bboxHeight: bbox.height,
                        featureData: featureData,
                        createdAt: now,
                        personId: nil,
                        labeledBy: nil,
                        needsReview: false
                    )
                    try? await faceRepo.upsert(record)
                }

                // Stamp faceIndexedAt so this photo is skipped on future runs
                try? await photoRepo.markFaceIndexed(id: photo.id)

                // Emit activity event for face detection results
                if !crops.isEmpty, let svc = await self?.activityService {
                    try? await svc.emitFaceDetection(
                        photoAssetId: photo.id,
                        faceCount: crops.count,
                        identifiedNames: []   // Names assigned later during clustering/labeling
                    )
                }

                indexed += 1
                await MainActor.run {
                    self?.faceIndexingProgress = "Detecting faces… \(indexed)/\(total)"
                }
            }

            await MainActor.run {
                self?.faceIndexingProgress = indexed > 0 ? "Face detection complete — \(indexed) photos scanned" : ""
                self?.isFaceIndexing = false
            }
            print("[FaceIndex] Background indexing complete — \(indexed)/\(total) photos scanned")
        }
    }

    /// Cancels any in-progress proxy generation.
    func cancelProxyGeneration() {
        proxyGenerationTask?.cancel()
        proxyGenerationTask = nil
        isGeneratingProxies = false
    }

    // MARK: - Face re-indexing

    @Published var faceIndexingProgress: String = ""

    // MARK: - Metrics (computed from real DB counts)

    var metrics: [DashboardMetric] {
        let total = photos.count
        let keepers = photos.filter { $0.curationState == CurationState.keeper.rawValue }.count
        let proxyQueue = photos.filter { $0.processingState == ProcessingState.indexed.rawValue }.count
        let syncFailed = photos.filter { $0.syncState == SyncState.failed.rawValue }.count
        return [
            DashboardMetric(
                title: "Catalogued",
                value: total > 0 ? "\(total)" : "0",
                detail: "Total photo assets in the library",
                tint: .blue
            ),
            DashboardMetric(
                title: "Keepers",
                value: "\(keepers)",
                detail: "Assets marked as keepers in curation",
                tint: .green
            ),
            DashboardMetric(
                title: "Proxy Queue",
                value: "\(proxyQueue)",
                detail: "Files indexed but not yet proxy-generated",
                tint: .orange
            ),
            DashboardMetric(
                title: "Sync Issues",
                value: "\(syncFailed)",
                detail: "Assets with failed sync state",
                tint: .red
            )
        ]
    }
}

// MARK: - PhotoAsset display helpers

extension PhotoAsset {
    /// Deterministic gradient derived from canonicalName hash.
    /// Used as a placeholder until proxy images are generated.
    var placeholderGradient: [Color] {
        let gradients: [[Color]] = [
            [.indigo, .cyan],
            [.purple, .pink],
            [.orange, .brown],
            [.teal, .mint],
            [.blue, .indigo],
            [.red, .orange],
            [.green, .teal],
            [.yellow, .orange],
            [.pink, .red],
            [.cyan, .blue]
        ]
        let index = abs(canonicalName.hashValue) % gradients.count
        return gradients[index]
    }

    /// Display-friendly role name.
    var roleDisplayName: String {
        PhotoRole(rawValue: role)?.displayName ?? role
    }

    /// Curation state enum from raw value.
    var curationStateEnum: CurationState {
        CurationState(rawValue: curationState) ?? .needsReview
    }

    /// Processing state enum from raw value.
    var processingStateEnum: ProcessingState {
        ProcessingState(rawValue: processingState) ?? .indexed
    }

    /// Sync state enum from raw value.
    var syncStateEnum: SyncState {
        SyncState(rawValue: syncState) ?? .localOnly
    }

    /// File extension extracted from canonicalName, uppercased.
    var fileExtension: String {
        (canonicalName as NSString).pathExtension.uppercased()
    }

    /// Metadata gaps — fields that are missing and can be enriched.
    var metadataGaps: [MetadataGap] {
        var gaps: [MetadataGap] = []
        if rawExifJson == nil { gaps.append(.noExif) }
        if userMetadataJson == nil { gaps.append(.noCaption) }
        if peopleDetected == nil { gaps.append(.noFaces) }
        if sceneType == nil { gaps.append(.noScene) }
        return gaps
    }
}

enum MetadataGap: String, Identifiable, CaseIterable {
    case noExif = "No EXIF"
    case noCaption = "No Caption"
    case noFaces = "Faces Unscanned"
    case noScene = "No Scene Tag"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .noExif: "doc.text"
        case .noCaption: "text.bubble"
        case .noFaces: "person.2"
        case .noScene: "tag"
        }
    }

    var tint: Color {
        switch self {
        case .noExif: .orange
        case .noCaption: .blue
        case .noFaces: .purple
        case .noScene: .teal
        }
    }
}
