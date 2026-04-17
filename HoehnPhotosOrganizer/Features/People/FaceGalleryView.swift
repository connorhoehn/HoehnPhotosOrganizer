import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - PersonDragItem

/// Transferable item for drag-and-drop person merging.
struct PersonDragItem: Codable, Transferable {
    let personId: String
    let personName: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .personDragItem)
    }
}

extension UTType {
    static let personDragItem = UTType(exportedAs: "com.hoehnphotos.person-drag-item")
}

// MARK: - ChipFramesKey

private struct ChipFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - RubberBandOverlay

/// NSView-based rubber band tracker that doesn't fight with ScrollView scrolling.
/// Intercepts mouse drag for selection and auto-scrolls when the cursor is near edges.
private struct RubberBandOverlay: NSViewRepresentable {
    /// Called when drag starts (point in the overlay's coordinate space, flipped to SwiftUI top-left origin).
    let onDragStart: (CGPoint) -> Void
    /// Called as drag continues.
    let onDragChanged: (CGPoint) -> Void
    /// Called when drag ends.
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> RubberBandNSView {
        let view = RubberBandNSView()
        view.onDragStart = onDragStart
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: RubberBandNSView, context: Context) {
        nsView.onDragStart = onDragStart
        nsView.onDragChanged = onDragChanged
        nsView.onDragEnded = onDragEnded
    }
}

private final class RubberBandNSView: NSView {
    var onDragStart: ((CGPoint) -> Void)?
    var onDragChanged: ((CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    private var isDragging = false
    private var autoScrollTimer: Timer?
    private var lastEvent: NSEvent?
    private let autoScrollEdgeMargin: CGFloat = 40
    private let autoScrollSpeed: CGFloat = 12

    override var isFlipped: Bool { true }  // Match SwiftUI's top-left origin

    /// Only claim the hit if the user drags beyond a minimum distance.
    /// For plain clicks, return nil so SwiftUI handles them (tap gestures on chips).
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Always claim hit — we decide in mouseDown whether to consume or pass through.
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = false
        mouseDownEvent = event
        lastEvent = event
        // Don't consume immediately — wait for mouseDragged to confirm it's a drag.
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        lastEvent = event

        if !isDragging {
            // Check minimum drag distance before committing to rubber-band
            if let downEvent = mouseDownEvent {
                let startLoc = convert(downEvent.locationInWindow, from: nil)
                let dx = loc.x - startLoc.x
                let dy = loc.y - startLoc.y
                guard dx * dx + dy * dy > 16 else { return } // 4pt threshold
            }
            isDragging = true
            onDragStart?(loc)
            startAutoScrollTimer()
        }

        onDragChanged?(loc)
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            isDragging = false
            stopAutoScrollTimer()
            onDragEnded?()
        } else {
            // Was a click, not a drag — synthesize click on the window so SwiftUI
            // views underneath receive it.
            if let downEvent = mouseDownEvent {
                // Temporarily remove this view from the responder chain so the
                // re-posted events reach the SwiftUI hosting view below.
                let savedHidden = isHidden
                isHidden = true
                window?.sendEvent(downEvent)
                window?.sendEvent(event)
                isHidden = savedHidden
            }
        }
        mouseDownEvent = nil
        lastEvent = nil
    }

    private var mouseDownEvent: NSEvent?

    // MARK: - Auto-scroll

    private func startAutoScrollTimer() {
        stopAutoScrollTimer()
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.performAutoScroll()
        }
    }

    private func stopAutoScrollTimer() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    private func performAutoScroll() {
        guard isDragging, let event = lastEvent,
              let scrollView = enclosingScrollView else { return }

        let locInScroll = scrollView.contentView.convert(event.locationInWindow, from: nil)
        let clipBounds = scrollView.contentView.bounds
        let docHeight = scrollView.documentView?.bounds.height ?? 0
        let maxScrollY = max(0, docHeight - clipBounds.height)

        var newOrigin = clipBounds.origin
        // NSScrollView clip view is flipped when documentView is flipped — in flipped coords:
        // locInScroll.y near 0 = top of visible area, near clipBounds.height = bottom
        let distFromTop = locInScroll.y - clipBounds.origin.y
        let distFromBottom = clipBounds.height - distFromTop

        if distFromTop < autoScrollEdgeMargin && clipBounds.origin.y > 0 {
            let factor = 1.0 - (distFromTop / autoScrollEdgeMargin)
            newOrigin.y = max(0, clipBounds.origin.y - autoScrollSpeed * factor)
        } else if distFromBottom < autoScrollEdgeMargin && clipBounds.origin.y < maxScrollY {
            let factor = 1.0 - (distFromBottom / autoScrollEdgeMargin)
            newOrigin.y = min(maxScrollY, clipBounds.origin.y + autoScrollSpeed * factor)
        } else {
            return  // Not near an edge
        }

        scrollView.contentView.scroll(to: newOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        // Update rubber band position after scroll (mouse is still in same screen position)
        let loc = convert(event.locationInWindow, from: nil)
        onDragChanged?(loc)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopAutoScrollTimer() }
    }
}

// MARK: - FaceGalleryViewModel

@MainActor
final class FaceGalleryViewModel: ObservableObject {

    static let strangerName = "Stranger"

    // MARK: - Filter

    enum FaceFilter: Hashable {
        case all
        case unlabeled
        case strangers
        case needsReview
        case person(String, String)  // (personId, personName)

        var label: String {
            switch self {
            case .all:         return "All"
            case .unlabeled:   return "Unlabeled"
            case .strangers:   return "Strangers"
            case .needsReview: return "Needs Review"
            case .person(_, let name): return name
            }
        }
    }

    // MARK: - State

    @Published var allRecords: [FaceGalleryRecord] = []
    @Published var selectedFilter: FaceFilter = .all
    @Published var selectedIds: Set<String> = []
    @Published var isLoading = false
    @Published var isRunningAutoMatch = false
    @Published var isRunningClaudeReview = false
    @Published var isClustering = false
    @Published var isRunningClusterMerge = false
    @Published var clusterMergeSuggestions: [ClusterMergeService.MergeSuggestion] = []
    @Published var showClusterMergeSheet = false
    @Published var clusters: [FaceLabelingService.FaceCluster] = []
    @Published var selectedClusterIndex: Int? = nil
    @Published var statusMessage: String? = nil

    // MARK: - Duplicate detection
    @Published var duplicatePairs: [FaceLabelingService.DuplicatePair] = []
    @Published var showDuplicateMergeSheet = false
    @Published var activeDuplicatePair: FaceLabelingService.DuplicatePair? = nil
    @Published var duplicateFaceChipsA: [FaceGalleryRecord] = []
    @Published var duplicateFaceChipsB: [FaceGalleryRecord] = []
    private var hasCheckedDuplicatesThisSession = false
    /// Person IDs the user dismissed as "keep separate" this session
    private var dismissedDuplicatePairIds: Set<String> = []

    // MARK: - Derived

    var filteredRecords: [FaceGalleryRecord] {
        switch selectedFilter {
        case .all:
            return allRecords
        case .unlabeled:
            return allRecords.filter { !$0.isLabeled && !$0.needsReview && $0.personName != Self.strangerName }
        case .strangers:
            return allRecords.filter { $0.personName == Self.strangerName }
        case .needsReview:
            return allRecords.filter { $0.needsReview }
        case .person(let personId, _):
            return allRecords.filter { $0.embedding.personId == personId && !$0.needsReview }
        }
    }

    /// Named people excluding the special "Stranger" identity.
    var people: [(id: String, name: String)] {
        var seen = Set<String>()
        var result: [(String, String)] = []
        for r in allRecords {
            guard let pid = r.embedding.personId, let name = r.personName,
                  !r.needsReview, name != Self.strangerName else { continue }
            if seen.insert(pid).inserted { result.append((pid, name)) }
        }
        return result.sorted { $0.1 < $1.1 }
    }

    var strangerPersonId: String? {
        allRecords.first(where: { $0.personName == Self.strangerName })?.embedding.personId
    }

    var needsReviewCount: Int { allRecords.filter { $0.needsReview }.count }
    var unlabeledCount: Int { allRecords.filter { !$0.isLabeled && !$0.needsReview && $0.personName != Self.strangerName }.count }
    var strangerCount: Int { allRecords.filter { $0.personName == Self.strangerName }.count }

    /// True when all faces have been assigned to a person (labeled or stranger).
    var allLabeled: Bool { unlabeledCount == 0 && needsReviewCount == 0 && !allRecords.isEmpty }

    // MARK: - Load

    private var hasAutoClusteredThisSession = false

    func load(db: AppDatabase) async {
        isLoading = true
        let repo = FaceEmbeddingRepository(db: db)
        do {
            // Show gallery immediately — don't block on clustering
            allRecords = try await repo.fetchGalleryRecords()
            isLoading = false

            // Auto-cluster in background after gallery is visible
            if !hasAutoClusteredThisSession && unlabeledCount >= 2 {
                hasAutoClusteredThisSession = true
                await autoCluster(db: db)
                allRecords = try await repo.fetchGalleryRecords()
            }

            // Check for duplicate persons once per session
            if !hasCheckedDuplicatesThisSession {
                hasCheckedDuplicatesThisSession = true
                await checkForDuplicates(db: db)
            }
        } catch {
            isLoading = false
            statusMessage = "Failed to load faces: \(error.localizedDescription)"
        }
    }

    // MARK: - Duplicate detection

    func checkForDuplicates(db: AppDatabase) async {
        let personRepo = PersonRepository(db: db)
        let faceRepo = FaceEmbeddingRepository(db: db)
        do {
            let pairs = try await FaceLabelingService.findDuplicatePersons(
                personRepo: personRepo,
                faceRepo: faceRepo
            )
            // Filter out dismissed pairs
            duplicatePairs = pairs.filter { pair in
                !dismissedDuplicatePairIds.contains(pair.id) &&
                !dismissedDuplicatePairIds.contains("\(pair.personB.id)-\(pair.personA.id)")
            }
        } catch {
            print("[FaceGalleryViewModel] Duplicate check failed: \(error)")
        }
    }

    func presentDuplicateMerge(_ pair: FaceLabelingService.DuplicatePair, db: AppDatabase) async {
        activeDuplicatePair = pair
        let faceRepo = FaceEmbeddingRepository(db: db)
        do {
            duplicateFaceChipsA = try await faceRepo.fetchConfirmedGalleryRecords(for: pair.personA.id)
            duplicateFaceChipsB = try await faceRepo.fetchConfirmedGalleryRecords(for: pair.personB.id)
        } catch {
            duplicateFaceChipsA = []
            duplicateFaceChipsB = []
        }
        showDuplicateMergeSheet = true
    }

    func mergeDuplicate(keepingPersonId: String, db: AppDatabase) async {
        guard let pair = activeDuplicatePair else { return }
        let sourceId = keepingPersonId == pair.personA.id ? pair.personB.id : pair.personA.id
        await mergePeople(sourceId: sourceId, into: keepingPersonId, db: db)
        showDuplicateMergeSheet = false
        activeDuplicatePair = nil
        duplicateFaceChipsA = []
        duplicateFaceChipsB = []
        // Remove this pair and re-check
        duplicatePairs.removeAll { $0.id == pair.id }
    }

    func dismissDuplicate() {
        guard let pair = activeDuplicatePair else { return }
        dismissedDuplicatePairIds.insert(pair.id)
        duplicatePairs.removeAll { $0.id == pair.id }
        showDuplicateMergeSheet = false
        activeDuplicatePair = nil
        duplicateFaceChipsA = []
        duplicateFaceChipsB = []
    }

    /// Cluster unlabeled faces and auto-assign placeholder names ("Person 1", "Person 2", etc.)
    /// Only assigns to clusters with 2+ faces so singletons stay unlabeled.
    private func autoCluster(db: AppDatabase) async {
        let faceRepo = FaceEmbeddingRepository(db: db)
        let personRepo = PersonRepository(db: db)
        do {
            let result = try await FaceLabelingService.clusterUnlabeled(faceRepo: faceRepo)
            clusters = result

            // Find the next available "Person N" number
            let existingPeople = try await personRepo.fetchAll()
            let existingNumbers = existingPeople.compactMap { name -> Int? in
                guard name.name.hasPrefix("Person ") else { return nil }
                return Int(name.name.dropFirst("Person ".count))
            }
            var nextNumber = (existingNumbers.max() ?? 0) + 1

            // Auto-label multi-face clusters
            var labeled = 0
            for cluster in result where cluster.faceIds.count >= 2 {
                let name = "Person \(nextNumber)"
                nextNumber += 1
                try await FaceLabelingService.label(
                    faceIds: cluster.faceIds,
                    as: name,
                    personRepo: personRepo,
                    faceRepo: faceRepo
                )
                labeled += cluster.faceIds.count
            }

            if labeled > 0 {
                let groupCount = result.filter { $0.faceIds.count >= 2 }.count
                NotificationCenter.default.post(name: .cloudSyncFacesLabeled, object: nil, userInfo: ["count": labeled])
                statusMessage = "Auto-grouped \(labeled) faces into \(groupCount) people. Rename them below."
            }
        } catch {
            print("[FaceGalleryViewModel] Auto-cluster failed: \(error)")
        }
    }

    // MARK: - Selection

    func toggleSelection(_ id: String) {
        if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
    }

    func setSelection(_ ids: Set<String>) { selectedIds = ids }

    func clearSelection() { selectedIds.removeAll() }

    func selectAll() { selectedIds = Set(filteredRecords.map(\.id)) }

    // MARK: - Label

    func labelSelected(as name: String, db: AppDatabase) async {
        let ids = Array(selectedIds)
        guard !ids.isEmpty, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let faceRepo = FaceEmbeddingRepository(db: db)
        let personRepo = PersonRepository(db: db)
        do {
            try await FaceLabelingService.label(faceIds: ids, as: name.trimmingCharacters(in: .whitespaces),
                                                personRepo: personRepo, faceRepo: faceRepo)
            clearSelection()
            await load(db: db)
            NotificationCenter.default.post(name: .cloudSyncFacesLabeled, object: nil, userInfo: ["count": ids.count])
            statusMessage = "Labeled \(ids.count) face\(ids.count == 1 ? "" : "s") as \"\(name)\"."
        } catch {
            statusMessage = "Labeling failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Rename person

    func renamePerson(personId: String, to newName: String, db: AppDatabase) async {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let personRepo = PersonRepository(db: db)
        let faceRepo = FaceEmbeddingRepository(db: db)
        do {
            // Check if target name already exists — if so, merge into it
            if let existing = try await personRepo.findByName(trimmed), existing.id != personId {
                // Merge: reassign all faces from old person to existing person
                let faces = try await faceRepo.fetchByPersonId(personId)
                let faceIds = faces.map(\.id)
                if !faceIds.isEmpty {
                    try await faceRepo.assignPerson(faceIds: faceIds, personId: existing.id, labeledBy: "user")
                }
                // Delete the old person identity
                try await personRepo.delete(personId)
                statusMessage = "Merged into \"\(trimmed)\"."
            } else {
                // Simple rename
                try await personRepo.rename(personId: personId, to: trimmed)
                statusMessage = "Renamed to \"\(trimmed)\"."
            }
            // Update filter if we were viewing the renamed person
            if case .person(let pid, _) = selectedFilter, pid == personId {
                selectedFilter = .all
            }
            await load(db: db)
        } catch {
            statusMessage = "Rename failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Merge people

    func mergePeople(sourceId: String, into targetId: String, db: AppDatabase) async {
        let faceRepo = FaceEmbeddingRepository(db: db)
        let personRepo = PersonRepository(db: db)
        do {
            let faces = try await faceRepo.fetchByPersonId(sourceId)
            let faceIds = faces.map(\.id)
            if !faceIds.isEmpty {
                try await faceRepo.assignPerson(faceIds: faceIds, personId: targetId, labeledBy: "user")
            }
            try await personRepo.delete(sourceId)
            let targetName = people.first(where: { $0.id == targetId })?.name ?? "target"
            statusMessage = "Merged \(faceIds.count) faces into \"\(targetName)\"."
            if case .person(let pid, _) = selectedFilter, pid == sourceId {
                selectedFilter = .all
            }
            await load(db: db)
        } catch {
            statusMessage = "Merge failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Mark as stranger

    func markSelectedAsStranger(db: AppDatabase) async {
        let ids = Array(selectedIds)
        guard !ids.isEmpty else { return }
        let faceRepo = FaceEmbeddingRepository(db: db)
        let personRepo = PersonRepository(db: db)
        do {
            try await FaceLabelingService.label(
                faceIds: ids, as: Self.strangerName,
                personRepo: personRepo, faceRepo: faceRepo
            )
            clearSelection()
            await load(db: db)
            statusMessage = "Marked \(ids.count) face\(ids.count == 1 ? "" : "s") as stranger."
        } catch {
            statusMessage = "Failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Auto-match

    func runAutoMatch(db: AppDatabase) async {
        isRunningAutoMatch = true
        defer { isRunningAutoMatch = false }
        let faceRepo = FaceEmbeddingRepository(db: db)
        do {
            let result = try await FaceLabelingService.runAutoMatch(faceRepo: faceRepo)
            await load(db: db)
            statusMessage = "Auto-match: \(result.matched) assigned, \(result.flagged) queued for Claude review."
        } catch {
            statusMessage = "Auto-match failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Cluster unlabeled

    func runClustering(db: AppDatabase) async {
        isClustering = true
        defer { isClustering = false }
        // Clear auto-generated "Person N" labels so they can be re-clustered
        let personRepo = PersonRepository(db: db)
        let faceRepo = FaceEmbeddingRepository(db: db)
        do {
            let allPeople = try await personRepo.fetchAll()
            for person in allPeople where person.name.hasPrefix("Person ") {
                let faces = try await faceRepo.fetchByPersonId(person.id)
                for face in faces {
                    try await faceRepo.clearPerson(faceId: face.id)
                }
                try await personRepo.delete(person.id)
            }
        } catch {
            print("[FaceGalleryViewModel] Failed to clear auto-labels: \(error)")
        }
        await autoCluster(db: db)
        await load(db: db)
        hasAutoClusteredThisSession = true
    }

    func selectCluster(at index: Int) {
        guard index >= 0, index < clusters.count else { return }
        selectedClusterIndex = index
        selectedIds = Set(clusters[index].faceIds)
        selectedFilter = .unlabeled
    }

    func nextCluster() {
        guard !clusters.isEmpty else { return }
        let next = ((selectedClusterIndex ?? -1) + 1) % clusters.count
        selectCluster(at: next)
    }

    func previousCluster() {
        guard !clusters.isEmpty else { return }
        let prev = ((selectedClusterIndex ?? 1) - 1 + clusters.count) % clusters.count
        selectCluster(at: prev)
    }

    // MARK: - Claude review

    func runClaudeReview(db: AppDatabase) async {
        isRunningClaudeReview = true
        defer { isRunningClaudeReview = false }
        let faceRepo = FaceEmbeddingRepository(db: db)
        let personRepo = PersonRepository(db: db)
        let authManager = AnthropicAuthManager()
        let service = ClaudeFaceReviewService(authManager: authManager)
        do {
            let result = try await service.processReviewQueue(faceRepo: faceRepo, personRepo: personRepo)
            await load(db: db)
            statusMessage = "Claude review: \(result.confirmed) confirmed, \(result.rejected) rejected, \(result.skipped) skipped."
        } catch {
            statusMessage = "Claude review failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Cluster merge (Claude Vision cross-check)

    func runClusterMerge(db: AppDatabase) async {
        isRunningClusterMerge = true
        defer { isRunningClusterMerge = false }
        let faceRepo = FaceEmbeddingRepository(db: db)
        let personRepo = PersonRepository(db: db)
        let authManager = AnthropicAuthManager()
        let service = ClusterMergeService(authManager: authManager)
        do {
            let result = try await service.analyzeClusters(faceRepo: faceRepo, personRepo: personRepo)
            clusterMergeSuggestions = result.suggestions
            if result.suggestions.isEmpty {
                statusMessage = "No merge suggestions — clusters look distinct."
            } else {
                showClusterMergeSheet = true
                statusMessage = "Found \(result.suggestions.count) potential merge\(result.suggestions.count == 1 ? "" : "s")."
            }
        } catch {
            statusMessage = "Cluster merge analysis failed: \(error.localizedDescription)"
        }
    }

    func confirmMergeSuggestion(_ suggestion: ClusterMergeService.MergeSuggestion, db: AppDatabase) async {
        let faceRepo = FaceEmbeddingRepository(db: db)
        let personRepo = PersonRepository(db: db)
        do {
            // Determine which person to keep: prefer known people over auto-clusters
            let sourceIsCluster = suggestion.sourceLabel.hasPrefix("Cluster ")
            let keepId = sourceIsCluster ? suggestion.targetPersonId : suggestion.sourcePersonId
            let mergeId = sourceIsCluster ? suggestion.sourcePersonId : suggestion.targetPersonId

            let faces = try await faceRepo.fetchByPersonId(mergeId)
            let faceIds = faces.map(\.id)
            if !faceIds.isEmpty {
                try await faceRepo.assignPerson(faceIds: faceIds, personId: keepId, labeledBy: "user")
            }
            try await personRepo.delete(mergeId)

            let keepName = sourceIsCluster ? suggestion.targetLabel : suggestion.sourceLabel
            print("[ClusterMerge] Merged \(faceIds.count) faces into \(keepName)")
            await load(db: db)
        } catch {
            statusMessage = "Merge failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Manual review decision

    func confirmReview(faceId: String, confirmed: Bool, db: AppDatabase) async {
        let faceRepo = FaceEmbeddingRepository(db: db)
        do {
            if confirmed {
                if let record = allRecords.first(where: { $0.id == faceId }),
                   let personId = record.embedding.personId {
                    try await faceRepo.assignPerson(faceIds: [faceId], personId: personId, labeledBy: "user")
                }
            } else {
                try await faceRepo.clearPerson(faceId: faceId)
            }
            await load(db: db)
        } catch {
            statusMessage = "Review update failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - FaceGalleryView

struct FaceGalleryView: View {
    @StateObject private var vm = FaceGalleryViewModel()
    @Environment(\.appDatabase) private var appDatabase: AppDatabase?

    // Drag-select state
    @State private var chipFrames: [String: CGRect] = [:]
    @State private var dragStartPoint: CGPoint?
    @State private var dragCurrentPoint: CGPoint?

    // Keyboard-driven assign popover
    @State private var keyboardAssignPopoverActive = false
    // Left panel people search
    @State private var personSearch = ""
    // Keyboard chip navigation (arrow keys move focus through the face grid)
    @State private var keyboardSelectedIndex: Int? = nil
    // Label wizard sheet
    @State private var showLabelWizard = false
    // Bucketed view toggles
    @State private var showUnknownFaces = false
    @State private var showClusters = false

    // Grid column count (persisted)
    @AppStorage("peopleGridColumns") private var gridColumnCount: Int = 4

    private let chipSize: CGFloat = 80
    private let columns = Array(repeating: GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 10), count: 1)

    private var selectionRect: CGRect? {
        guard let s = dragStartPoint, let c = dragCurrentPoint,
              abs(c.x - s.x) > 4 || abs(c.y - s.y) > 4 else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y),
                      width: abs(c.x - s.x), height: abs(c.y - s.y))
    }

    /// Grid columns for the people card grid, driven by the slider.
    private var peopleCardColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 16), count: gridColumnCount)
    }

    /// Named people grouped for the bucketed "All" view.
    /// Excludes auto-generated "Person N" clusters and "Stranger".
    /// Sorted by face count descending (most photos first).
    private var namedPeopleGroups: [(name: String, faces: [FaceGalleryRecord])] {
        let autoPattern = /^Person \d+$/
        let named = vm.allRecords.filter { record in
            guard let name = record.personName else { return false }
            return name.wholeMatch(of: autoPattern) == nil
                && name != FaceGalleryViewModel.strangerName
                && !record.needsReview
        }
        let grouped = Dictionary(grouping: named) { $0.personName ?? "" }
        return grouped.sorted { $0.value.count > $1.value.count }.map { (name: $0.key, faces: $0.value) }
    }

    /// True when the bucketed named-people view should be shown instead of the flat grid.
    private var shouldShowBucketedView: Bool {
        vm.selectedFilter == .all && !namedPeopleGroups.isEmpty
    }

    var body: some View {
        HStack(spacing: 0) {
            // ── Left: people list panel ──
            peopleListPanel
                .frame(width: 220)

            Divider()

            // ── Center: face grid ──
            VStack(spacing: 0) {
                toolbar
                Divider()

                if vm.isLoading {
                    Spacer()
                    ProgressView("Loading faces…")
                    Spacer()
                } else if vm.allRecords.isEmpty {
                    emptyState
                } else if vm.allLabeled && !vm.people.isEmpty && vm.selectedFilter == .all {
                    // All faces labeled — show people summary
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            statusFilterBar
                            if !vm.duplicatePairs.isEmpty { duplicateBanner }
                            peopleSummaryGrid
                        }
                        .padding(20)
                    }
                } else if shouldShowBucketedView {
                    // Card grid view: person cards in a grid + collapsible unknown section
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            statusFilterBar
                            if !vm.duplicatePairs.isEmpty { duplicateBanner }
                            if vm.needsReviewCount > 0 { reviewBanner }

                            // Person card grid (sorted by face count descending)
                            LazyVGrid(columns: peopleCardColumns, spacing: 16) {
                                ForEach(namedPeopleGroups, id: \.name) { group in
                                    if let pid = group.faces.first?.embedding.personId {
                                        PersonSummaryCard(
                                            personId: pid,
                                            name: group.name,
                                            faceCount: group.faces.count,
                                            sampleRecords: Array(group.faces.prefix(4)),
                                            chipSize: chipSize
                                        ) {
                                            vm.selectedFilter = .person(pid, group.name)
                                            vm.clearSelection()
                                        }
                                        .contextMenu {
                                            personSummaryCardContextMenu(personId: pid, name: group.name)
                                        }
                                        .draggable(PersonDragItem(personId: pid, personName: group.name))
                                        .dropDestination(for: PersonDragItem.self) { items, _ in
                                            guard let source = items.first, source.personId != pid else { return false }
                                            Task {
                                                if let db = appDatabase {
                                                    await vm.mergePeople(sourceId: source.personId, into: pid, db: db)
                                                }
                                            }
                                            return true
                                        } isTargeted: { targeted in
                                            dropTargetPersonId = targeted ? pid : nil
                                        }
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .stroke(Color.accentColor, lineWidth: 2)
                                                .opacity(dropTargetPersonId == pid ? 1 : 0)
                                        )
                                    }
                                }
                            }

                            // Unknown / unlabeled section (collapsed by default)
                            let unknownCount = vm.unlabeledCount
                            if unknownCount > 0 {
                                Divider()
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showUnknownFaces.toggle()
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: showUnknownFaces ? "chevron.down" : "chevron.right")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.tertiary)
                                            .frame(width: 12)
                                        Text("Unknown Faces (\(unknownCount))")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 16)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if showUnknownFaces {
                                    let unlabeledRecords = vm.allRecords.filter {
                                        !$0.isLabeled && !$0.needsReview && $0.personName != FaceGalleryViewModel.strangerName
                                    }
                                    LazyVGrid(columns: columns, spacing: 10) {
                                        ForEach(unlabeledRecords, id: \.id) { record in
                                            FaceChipCell(
                                                record: record,
                                                isSelected: vm.selectedIds.contains(record.id),
                                                chipSize: chipSize
                                            ) {
                                                vm.toggleSelection(record.id)
                                            } onConfirmReview: { confirmed in
                                                Task {
                                                    if let db = appDatabase {
                                                        await vm.confirmReview(faceId: record.id, confirmed: confirmed, db: db)
                                                    }
                                                }
                                            }
                                            .contextMenu { faceChipContextMenu(record: record) }
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                }
                            }
                        }
                        .padding(20)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            statusFilterBar
                            if !vm.duplicatePairs.isEmpty { duplicateBanner }
                            personFilterHeader
                            if vm.needsReviewCount > 0 { reviewBanner }
                            chipGridContent
                        }
                        .padding(20)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // ── Right: workflow panel ──
            PeopleWorkflowPanel(vm: vm, appDatabase: appDatabase)
                .frame(width: 260)
        }
        .sheet(isPresented: $vm.showClusterMergeSheet) {
            ClusterMergeReviewSheet(
                suggestions: vm.clusterMergeSuggestions,
                onConfirm: { suggestion in
                    Task {
                        if let db = appDatabase {
                            await vm.confirmMergeSuggestion(suggestion, db: db)
                        }
                    }
                },
                onReject: { _ in
                    // No action needed — just skip
                },
                onDismiss: {
                    vm.showClusterMergeSheet = false
                }
            )
        }
        .sheet(isPresented: $vm.showDuplicateMergeSheet) {
            DuplicateMergeSheet(vm: vm, appDatabase: appDatabase)
        }
        .sheet(isPresented: $showLabelWizard) {
            FaceLabelWizard {
                Task { if let db = appDatabase { await vm.load(db: db) } }
            }
        }
        .task {
            if let db = appDatabase { await vm.load(db: db) }
        }
        .onChange(of: vm.statusMessage) { _, msg in
            if msg != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { vm.statusMessage = nil }
            }
        }
        .onChange(of: vm.selectedFilter) { _, _ in
            keyboardSelectedIndex = nil
        }
        // Keyboard shortcuts for the face gallery
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) {
            guard !vm.selectedIds.isEmpty else { return .ignored }
            keyboardAssignPopoverActive = true
            return .handled
        }
        .onKeyPress(.delete) {
            guard !vm.selectedIds.isEmpty else { return .ignored }
            Task { if let db = appDatabase { await vm.markSelectedAsStranger(db: db) } }
            return .handled
        }
        .onKeyPress(.init("a"), phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            vm.selectAll()
            return .handled
        }
        // ← → navigate between clusters when clusters exist; otherwise navigate individual chips
        .onKeyPress(.leftArrow) {
            if !vm.clusters.isEmpty {
                vm.previousCluster()
                keyboardSelectedIndex = nil
                return .handled
            }
            let count = vm.filteredRecords.count
            guard count > 0 else { return .ignored }
            if let idx = keyboardSelectedIndex, idx > 0 {
                keyboardSelectedIndex = idx - 1
            } else if keyboardSelectedIndex == nil {
                keyboardSelectedIndex = 0
            }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            if !vm.clusters.isEmpty {
                vm.nextCluster()
                keyboardSelectedIndex = nil
                return .handled
            }
            let count = vm.filteredRecords.count
            guard count > 0 else { return .ignored }
            if let idx = keyboardSelectedIndex {
                keyboardSelectedIndex = min(idx + 1, count - 1)
            } else {
                keyboardSelectedIndex = 0
            }
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard vm.clusters.isEmpty else { return .ignored }
            let count = vm.filteredRecords.count
            guard count > 0 else { return .ignored }
            if let idx = keyboardSelectedIndex, idx > 0 {
                keyboardSelectedIndex = idx - 1
            } else if keyboardSelectedIndex == nil {
                keyboardSelectedIndex = 0
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard vm.clusters.isEmpty else { return .ignored }
            let count = vm.filteredRecords.count
            guard count > 0 else { return .ignored }
            if let idx = keyboardSelectedIndex {
                keyboardSelectedIndex = min(idx + 1, count - 1)
            } else {
                keyboardSelectedIndex = 0
            }
            return .handled
        }
        .onKeyPress(.space) {
            guard let idx = keyboardSelectedIndex,
                  idx < vm.filteredRecords.count else { return .ignored }
            vm.toggleSelection(vm.filteredRecords[idx].id)
            return .handled
        }
        // Popover for keyboard-driven label assignment (Return key)
        .popover(isPresented: $keyboardAssignPopoverActive) {
            KeyboardAssignPopover(vm: vm, appDatabase: appDatabase) {
                keyboardAssignPopoverActive = false
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if case .person(_, let personName) = vm.selectedFilter {
                    HStack(spacing: 4) {
                        Button {
                            vm.selectedFilter = .all
                            vm.clearSelection()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("People")
                                    .font(.system(size: 13))
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        Text("/")
                            .font(.system(size: 13))
                            .foregroundStyle(.quaternary)
                        Text(personName)
                            .font(.system(size: 17, weight: .bold))
                    }
                } else {
                    Text("People")
                        .font(.system(size: 17, weight: .bold))
                }
                Text("\(vm.allRecords.count) faces · \(vm.people.count) people · \(vm.unlabeledCount) unlabeled" + (vm.strangerCount > 0 ? " · \(vm.strangerCount) strangers" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let msg = vm.statusMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }

            // Column count slider
            HStack(spacing: 6) {
                Image(systemName: "square.grid.3x3")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(gridColumnCount) },
                    set: { gridColumnCount = Int($0) }
                ), in: 3...6, step: 1)
                .frame(width: 80)
                .help("Grid columns: \(gridColumnCount)")
                Text("\(gridColumnCount)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }

            Button {
                showLabelWizard = true
            } label: {
                Label("Label Wizard", systemImage: "wand.and.stars")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(vm.unlabeledCount == 0)
            .help("Fast keyboard-driven face labeling wizard")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - People list panel (left sidebar)

    /// Named = manually set names (not auto-generated "Person N")
    private var namedPeople: [(id: String, name: String)] {
        vm.people.filter { !$0.name.hasPrefix("Person ") }
    }
    /// Clusters = auto-generated "Person N" groups
    private var clusterPeople: [(id: String, name: String)] {
        vm.people.filter { $0.name.hasPrefix("Person ") }
            .sorted { lhs, rhs in
                // Sort numerically by the trailing number
                let ln = Int(lhs.name.dropFirst("Person ".count)) ?? 0
                let rn = Int(rhs.name.dropFirst("Person ".count)) ?? 0
                return ln < rn
            }
    }
    private var filteredNamedPeople: [(id: String, name: String)] {
        personSearch.isEmpty ? namedPeople : namedPeople.filter { $0.name.localizedCaseInsensitiveContains(personSearch) }
    }
    private var filteredClusterPeople: [(id: String, name: String)] {
        personSearch.isEmpty ? clusterPeople : clusterPeople.filter { $0.name.localizedCaseInsensitiveContains(personSearch) }
    }

    private var peopleListPanel: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary).font(.system(size: 12))
                TextField("Search people…", text: $personSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !personSearch.isEmpty {
                    Button { personSearch = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Status filters at top
                    personListRow(label: "All Faces", icon: "person.crop.circle", badge: vm.allRecords.count, isActive: vm.selectedFilter == .all) {
                        vm.selectedFilter = .all; vm.clearSelection()
                    }
                    if vm.unlabeledCount > 0 {
                        personListRow(label: "Unlabeled", icon: "questionmark.circle", badge: vm.unlabeledCount, isActive: vm.selectedFilter == .unlabeled) {
                            vm.selectedFilter = .unlabeled; vm.clearSelection()
                        }
                    }
                    if vm.needsReviewCount > 0 {
                        personListRow(label: "Needs Review", icon: "exclamationmark.circle", badge: vm.needsReviewCount, isActive: vm.selectedFilter == .needsReview) {
                            vm.selectedFilter = .needsReview; vm.clearSelection()
                        }
                    }
                    if vm.strangerCount > 0 {
                        personListRow(label: "Strangers", icon: "person.slash", badge: vm.strangerCount, isActive: vm.selectedFilter == .strangers) {
                            vm.selectedFilter = .strangers; vm.clearSelection()
                        }
                    }

                    // Named people
                    if !filteredNamedPeople.isEmpty {
                        sectionHeaderRow("Known People")
                        ForEach(filteredNamedPeople, id: \.id) { p in
                            let count = vm.allRecords.filter { $0.embedding.personId == p.id && !$0.needsReview }.count
                            let isActive = vm.selectedFilter == .person(p.id, p.name)
                            personListRow(label: p.name, icon: nil, badge: count, isActive: isActive) {
                                vm.selectedFilter = .person(p.id, p.name); vm.clearSelection()
                            }
                            .contextMenu { personContextMenu(personId: p.id, name: p.name) }
                        }
                    }

                    // Auto-clusters (collapsed by default)
                    if !filteredClusterPeople.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showClusters.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showClusters ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 10)
                                Text("CLUSTERS (\(filteredClusterPeople.count))")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if showClusters {
                            ForEach(filteredClusterPeople, id: \.id) { p in
                                let count = vm.allRecords.filter { $0.embedding.personId == p.id && !$0.needsReview }.count
                                let isActive = vm.selectedFilter == .person(p.id, p.name)
                                personListRow(label: p.name, icon: nil, badge: count, isActive: isActive) {
                                    vm.selectedFilter = .person(p.id, p.name); vm.clearSelection()
                                }
                                .contextMenu { personContextMenu(personId: p.id, name: p.name) }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .popover(isPresented: Binding(
            get: { renamingPersonId != nil },
            set: { if !$0 { renamingPersonId = nil } }
        )) { renamePopoverContent }
    }

    private func sectionHeaderRow(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func personListRow(label: String, icon: String?, badge: Int, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(isActive ? .white : .secondary)
                        .frame(width: 16)
                }
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(isActive ? .white : .primary)
                    .lineLimit(1)
                Spacer()
                Text("\(badge)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isActive ? .white.opacity(0.8) : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? Color.accentColor : Color.clear)
                    .padding(.horizontal, 4)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Face chip context menu (ungrouped faces in grid)

    @ViewBuilder
    private func faceChipContextMenu(record: FaceGalleryRecord) -> some View {
        Button("Label as Stranger") {
            Task {
                if let db = appDatabase {
                    // Select just this face then mark it
                    vm.setSelection([record.id])
                    await vm.markSelectedAsStranger(db: db)
                }
            }
        }

        if vm.selectedIds.count > 1 {
            Button("Merge with Selected") {
                Task {
                    if let db = appDatabase {
                        // Use the tapped chip's person (or create new) as the merge target
                        // If record already has a person, merge all selected into that person
                        if let targetPersonId = record.embedding.personId {
                            let sourceIds = vm.selectedIds.filter { id in
                                id != record.id &&
                                vm.allRecords.first(where: { $0.id == id })?.embedding.personId != targetPersonId
                            }
                            for sourcePersonId in Set(sourceIds.compactMap { id in
                                vm.allRecords.first(where: { $0.id == id })?.embedding.personId
                            }) {
                                await vm.mergePeople(sourceId: sourcePersonId, into: targetPersonId, db: db)
                            }
                        } else {
                            // No person yet — label all selected as a new group using this face's name
                            let selectedFaceIds = Array(vm.selectedIds)
                            let faceRepo = FaceEmbeddingRepository(db: db)
                            let personRepo = PersonRepository(db: db)
                            let newName = "Merged Group"
                            try? await FaceLabelingService.label(
                                faceIds: selectedFaceIds, as: newName,
                                personRepo: personRepo, faceRepo: faceRepo
                            )
                            await vm.load(db: db)
                        }
                    }
                }
            }
        }

        if let personId = record.embedding.personId,
           let personName = record.personName,
           personName != FaceGalleryViewModel.strangerName {
            Divider()
            Button("Open Person") {
                vm.selectedFilter = .person(personId, personName)
                vm.clearSelection()
            }
        }
    }

    // MARK: - Person summary card context menu (all-labeled grid)

    @ViewBuilder
    private func personSummaryCardContextMenu(personId: String, name: String) -> some View {
        Button("Rename \"\(name)\"…") {
            renamingPersonId = personId
            renameText = name
        }

        Button("Find Photos") {
            vm.selectedFilter = .person(personId, name)
            vm.clearSelection()
        }

        Divider()

        Button("Mark as Stranger", role: .destructive) {
            Task {
                if let db = appDatabase {
                    // Reassign all faces of this person to the stranger identity
                    let faceRepo = FaceEmbeddingRepository(db: db)
                    let personRepo = PersonRepository(db: db)
                    do {
                        let faces = try await faceRepo.fetchByPersonId(personId)
                        let faceIds = faces.map(\.id)
                        if !faceIds.isEmpty {
                            try await FaceLabelingService.label(
                                faceIds: faceIds, as: FaceGalleryViewModel.strangerName,
                                personRepo: personRepo, faceRepo: faceRepo
                            )
                        }
                        try await personRepo.delete(personId)
                        if case .person(let pid, _) = vm.selectedFilter, pid == personId {
                            vm.selectedFilter = .all
                        }
                        await vm.load(db: db)
                        vm.statusMessage = "Marked \"\(name)\" as stranger."
                    } catch {
                        vm.statusMessage = "Failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func personContextMenu(personId: String, name: String) -> some View {
        Button("Rename \"\(name)\"…") {
            renamingPersonId = personId
            renameText = name
        }
        let others = vm.people.filter { $0.id != personId }
        if !others.isEmpty {
            Menu("Merge into…") {
                ForEach(others, id: \.id) { other in
                    Button(other.name) {
                        Task {
                            if let db = appDatabase {
                                await vm.mergePeople(sourceId: personId, into: other.id, db: db)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Status filter bar (center panel, no person chips)

    private var statusFilterBar: some View {
        HStack(spacing: 8) {
            filterChip(.all, badge: vm.allRecords.count)
            if vm.unlabeledCount > 0 { filterChip(.unlabeled, badge: vm.unlabeledCount) }
            if vm.strangerCount > 0 { filterChip(.strangers, badge: vm.strangerCount) }
            if vm.needsReviewCount > 0 { filterChip(.needsReview, badge: vm.needsReviewCount) }
            Spacer()
        }
    }

    @State private var renamingPersonId: String? = nil
    @State private var renameText: String = ""
    @State private var dropTargetPersonId: String? = nil

    // filterChip is now only used for status filters (All, Unlabeled, Strangers, Needs Review).
    // Person selection moved to the left peopleListPanel.
    private func filterChip(_ filter: FaceGalleryViewModel.FaceFilter, badge: Int) -> some View {
        let isActive = vm.selectedFilter == filter
        return Button { vm.selectedFilter = filter; vm.clearSelection() } label: {
            HStack(spacing: 4) {
                Text(filter.label)
                    .font(.system(size: 12, weight: .medium))
                Text("\(badge)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isActive ? .white.opacity(0.8) : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? Color.accentColor : Color(nsColor: .quaternarySystemFill))
            )
            .foregroundStyle(isActive ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // Rename popover — still used via context menu in the people list panel
    @ViewBuilder
    private var renamePopoverContent: some View {
        if let personId = renamingPersonId {
            VStack(spacing: 8) {
                Text("Rename Person")
                    .font(.caption.weight(.semibold))
                TextField("Name", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onSubmit {
                        Task {
                            if let db = appDatabase {
                                await vm.renamePerson(personId: personId, to: renameText, db: db)
                                renamingPersonId = nil
                            }
                        }
                    }
                HStack {
                    Button("Cancel") { renamingPersonId = nil }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    Button("Save") {
                        Task {
                            if let db = appDatabase {
                                await vm.renamePerson(personId: personId, to: renameText, db: db)
                                renamingPersonId = nil
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            .padding(12)
        }
    }

    // MARK: - Duplicate people banner

    private var duplicateBanner: some View {
        let count = vm.duplicatePairs.count
        return HStack(spacing: 10) {
            Image(systemName: "person.2.fill")
                .foregroundStyle(.yellow)
            Text("\(count) possible duplicate \(count == 1 ? "person" : "people") found")
                .font(.callout)
            Spacer()
            Button("Review") {
                if let first = vm.duplicatePairs.first {
                    Task {
                        if let db = appDatabase {
                            await vm.presentDuplicateMerge(first, db: db)
                        }
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.yellow.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.yellow.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - Review banner

    private var reviewBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.orange)
            Text("\(vm.needsReviewCount) face\(vm.needsReviewCount == 1 ? "" : "s") need review — borderline embedding matches.")
                .font(.callout)
            Spacer()
            Button("Review Now") { vm.selectedFilter = .needsReview }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
        )
    }

    // MARK: - Person filter header card

    @ViewBuilder
    private var personFilterHeader: some View {
        if case .person(let personId, let personName) = vm.selectedFilter {
            let faces = vm.allRecords.filter { $0.embedding.personId == personId && !$0.needsReview }
            let coverRecord = faces.first
            PersonFilterHeaderCard(
                personId: personId,
                personName: personName,
                faceCount: faces.count,
                coverRecord: coverRecord,
                chipSize: chipSize
            ) { newName in
                Task { if let db = appDatabase {
                    await vm.renamePerson(personId: personId, to: newName, db: db)
                }}
            }
        }
    }

    // MARK: - Chip grid with drag selection

    @ViewBuilder
    private var chipGridContent: some View {
        let records = vm.filteredRecords
        if records.isEmpty {
            FilterEmptyStateView(filter: vm.selectedFilter)
        } else {
            ZStack(alignment: .topLeading) {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(records.indices, id: \.self) { index in
                        let record = records[index]
                        let isKeyboardFocused = keyboardSelectedIndex == index
                        FaceChipCell(
                            record: record,
                            isSelected: vm.selectedIds.contains(record.id),
                            chipSize: chipSize,
                            showName: {
                                if case .person = vm.selectedFilter { return false }
                                return true
                            }()
                        ) {
                            keyboardSelectedIndex = index
                            vm.toggleSelection(record.id)
                        } onConfirmReview: { confirmed in
                            Task {
                                if let db = appDatabase {
                                    await vm.confirmReview(faceId: record.id, confirmed: confirmed, db: db)
                                }
                            }
                        }
                        .overlay(
                            Circle()
                                .stroke(Color.accentColor, lineWidth: isKeyboardFocused ? 2.5 : 0)
                                .frame(width: chipSize + 6, height: chipSize + 6)
                                .opacity(isKeyboardFocused ? 1 : 0)
                        )
                        .contextMenu {
                            faceChipContextMenu(record: record)
                        }
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: ChipFramesKey.self,
                                    value: [record.id: geo.frame(in: .named("chipGrid"))]
                                )
                            }
                        )
                    }
                }

                // Drag selection rectangle
                if let rect = selectionRect, rect.width > 4, rect.height > 4 {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay(Rectangle().stroke(Color.accentColor.opacity(0.6), lineWidth: 1))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "chipGrid")
            .onPreferenceChange(ChipFramesKey.self) { chipFrames = $0 }
            .overlay(
                RubberBandOverlay(
                    onDragStart: { point in
                        dragStartPoint = point
                        dragCurrentPoint = point
                        vm.clearSelection()
                    },
                    onDragChanged: { point in
                        dragCurrentPoint = point
                        if let rect = selectionRect {
                            let hit = chipFrames.filter { $0.value.intersects(rect) }.map(\.key)
                            vm.setSelection(Set(hit))
                        }
                    },
                    onDragEnded: {
                        dragStartPoint = nil
                        dragCurrentPoint = nil
                    }
                )
            )
        }
    }

    // MARK: - People summary (all labeled)

    private var peopleSummaryGrid: some View {
        let sortedPeople = vm.people.sorted { lhs, rhs in
            let lCount = vm.allRecords.filter { $0.embedding.personId == lhs.id && !$0.needsReview }.count
            let rCount = vm.allRecords.filter { $0.embedding.personId == rhs.id && !$0.needsReview }.count
            return lCount > rCount
        }
        return LazyVGrid(columns: peopleCardColumns, spacing: 16) {
            ForEach(sortedPeople, id: \.id) { person in
                let faces = vm.allRecords.filter { $0.embedding.personId == person.id && !$0.needsReview }
                PersonSummaryCard(
                    personId: person.id,
                    name: person.name,
                    faceCount: faces.count,
                    sampleRecords: Array(faces.prefix(4)),
                    chipSize: chipSize
                ) {
                    vm.selectedFilter = .person(person.id, person.name)
                }
                .contextMenu {
                    personSummaryCardContextMenu(personId: person.id, name: person.name)
                }
                .draggable(PersonDragItem(personId: person.id, personName: person.name))
                .dropDestination(for: PersonDragItem.self) { items, _ in
                    guard let source = items.first, source.personId != person.id else { return false }
                    Task {
                        if let db = appDatabase {
                            await vm.mergePeople(sourceId: source.personId, into: person.id, db: db)
                        }
                    }
                    return true
                } isTargeted: { targeted in
                    dropTargetPersonId = targeted ? person.id : nil
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .opacity(dropTargetPersonId == person.id ? 1 : 0)
                )
            }

            // Strangers card
            if vm.strangerCount > 0 {
                let strangerFaces = vm.allRecords.filter { $0.personName == FaceGalleryViewModel.strangerName }
                PersonSummaryCard(
                    personId: vm.strangerPersonId ?? "",
                    name: "Strangers",
                    faceCount: vm.strangerCount,
                    sampleRecords: Array(strangerFaces.prefix(4)),
                    chipSize: chipSize
                ) {
                    vm.selectedFilter = .strangers
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No face embeddings yet")
                .font(.title3.weight(.semibold))
            Text("Import photos and let the face indexer run,\nthen come back here to label people.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - DuplicateMergeSheet

private struct DuplicateMergeSheet: View {
    @ObservedObject var vm: FaceGalleryViewModel
    let appDatabase: AppDatabase?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Possible Duplicate People")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button { vm.dismissDuplicate() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            if let pair = vm.activeDuplicatePair {
                ScrollView {
                    VStack(spacing: 24) {
                        Text("These two people look very similar (distance: \(String(format: "%.2f", pair.centroidDistance))). Would you like to merge them?")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)

                        // Side-by-side comparison
                        HStack(alignment: .top, spacing: 32) {
                            duplicatePersonColumn(
                                person: pair.personA,
                                chips: vm.duplicateFaceChipsA,
                                mergeLabel: "Merge into \(pair.personA.name)"
                            ) {
                                Task {
                                    if let db = appDatabase {
                                        await vm.mergeDuplicate(keepingPersonId: pair.personA.id, db: db)
                                    }
                                }
                            }

                            Divider()
                                .frame(height: 200)

                            duplicatePersonColumn(
                                person: pair.personB,
                                chips: vm.duplicateFaceChipsB,
                                mergeLabel: "Merge into \(pair.personB.name)"
                            ) {
                                Task {
                                    if let db = appDatabase {
                                        await vm.mergeDuplicate(keepingPersonId: pair.personB.id, db: db)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)

                        Divider()

                        // Dismiss / keep separate
                        Button("Keep Separate") {
                            vm.dismissDuplicate()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.callout)

                        if vm.duplicatePairs.count > 1 {
                            Text("\(vm.duplicatePairs.count - 1) more pair\(vm.duplicatePairs.count - 1 == 1 ? "" : "s") to review")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 20)
                }
            }
        }
        .frame(width: 560, height: 420)
    }

    private func duplicatePersonColumn(
        person: PersonIdentity,
        chips: [FaceGalleryRecord],
        mergeLabel: String,
        onMerge: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 12) {
            Text(person.name)
                .font(.headline)

            // Face chip grid
            let chipSize: CGFloat = 64
            LazyVGrid(columns: [GridItem(.fixed(chipSize), spacing: 6),
                                GridItem(.fixed(chipSize), spacing: 6),
                                GridItem(.fixed(chipSize), spacing: 6)], spacing: 6) {
                ForEach(chips) { record in
                    DuplicateFaceChip(record: record, size: chipSize)
                }
            }
            .frame(minHeight: 70)

            Text("\(chips.count) face\(chips.count == 1 ? "" : "s") shown")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button(mergeLabel, action: onMerge)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - DuplicateFaceChip

private struct DuplicateFaceChip: View {
    let record: FaceGalleryRecord
    let size: CGFloat
    @State private var image: NSImage? = nil

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(nsColor: .quaternarySystemFill)
                    .overlay(
                        ProgressView()
                            .controlSize(.small)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task { await loadFaceChip() }
    }

    private func loadFaceChip() async {
        image = await FaceCropCache.shared.crop(
            id: record.id,
            proxyURL: record.proxyURL,
            bbox: record.bbox
        )
    }
}

// MARK: - PeopleWorkflowPanel

private struct PeopleWorkflowPanel: View {
    @ObservedObject var vm: FaceGalleryViewModel
    let appDatabase: AppDatabase?

    @State private var labelName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(vm.selectedIds.isEmpty ? "People" : "\(vm.selectedIds.count) selected")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !vm.selectedIds.isEmpty {
                    Button("Clear") { vm.clearSelection() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if vm.selectedIds.isEmpty {
                        idleContent
                    } else {
                        labelContent
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: Idle (no selection)

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // How-to
            VStack(alignment: .leading, spacing: 10) {
                Label("How to label faces", systemImage: "hand.tap")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    tipRow(number: "1", text: "Similar faces are auto-grouped on load")
                    tipRow(number: "2", text: "Right-click a group chip to rename or merge")
                    tipRow(number: "3", text: "Run Auto-Match to catch remaining faces")
                    tipRow(number: "4", text: "Or drag-select faces to label manually")
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .quaternarySystemFill))
            )

            Divider()

            // AI tools
            VStack(alignment: .leading, spacing: 10) {
                Text("AI Tools")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Button {
                    Task { if let db = appDatabase { await vm.runClustering(db: db) } }
                } label: {
                    Label(vm.isClustering ? "Clustering…" : "Re-Cluster", systemImage: "person.3.sequence")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(vm.isClustering || vm.unlabeledCount < 2)
                .help("Re-group remaining unlabeled faces")

                Button {
                    Task { if let db = appDatabase { await vm.runAutoMatch(db: db) } }
                } label: {
                    Label(vm.isRunningAutoMatch ? "Running…" : "Auto-Match", systemImage: "wand.and.rays")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(vm.isRunningAutoMatch || vm.people.isEmpty)
                .help("Compare unlabeled faces against your labeled references")

                if vm.people.isEmpty {
                    Text("Label at least one face first to enable Auto-Match.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Button {
                    Task { if let db = appDatabase { await vm.runClaudeReview(db: db) } }
                } label: {
                    Label(vm.isRunningClaudeReview ? "Running…" : "Claude Review", systemImage: "sparkles")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(vm.isRunningClaudeReview || vm.needsReviewCount == 0)
                .help("Send borderline matches to Claude Vision for confirmation")

                if vm.needsReviewCount > 0 {
                    Text("\(vm.needsReviewCount) face\(vm.needsReviewCount == 1 ? "" : "s") queued for review.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                Button {
                    Task { if let db = appDatabase { await vm.runClusterMerge(db: db) } }
                } label: {
                    Label(vm.isRunningClusterMerge ? "Analyzing…" : "Suggest Merges", systemImage: "person.2.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(vm.isRunningClusterMerge || vm.people.count < 2)
                .help("Use Claude Vision to find clusters that look like the same person")

                if vm.people.count < 2 {
                    Text("Need at least 2 people/clusters to suggest merges.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Divider()

            // Select all
            Button {
                vm.selectAll()
            } label: {
                Label("Select All Visible", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.callout)
        }
        .padding(16)
    }

    private func tipRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(Circle().fill(Color.accentColor.opacity(0.7)))
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Label (faces selected)

    private var labelContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Quick assign to existing person
            if !vm.people.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Assign to existing person")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    VStack(spacing: 6) {
                        ForEach(vm.people, id: \.id) { person in
                            Button {
                                labelName = person.name
                                saveLabel()
                            } label: {
                                HStack {
                                    Image(systemName: "person.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(person.name)
                                        .font(.callout)
                                    Spacer()
                                    Image(systemName: "arrow.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(Color(nsColor: .quaternarySystemFill))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Divider()
            }

            // New person input
            VStack(alignment: .leading, spacing: 8) {
                Text(vm.people.isEmpty ? "Name this person" : "Or add as new person")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("e.g. Connor, Morgan…", text: $labelName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { saveLabel() }

                Button("Save") { saveLabel() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity)
                    .disabled(labelName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Divider()

            // Mark as stranger
            VStack(alignment: .leading, spacing: 8) {
                Text("Not someone you know?")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Button {
                    Task { if let db = appDatabase { await vm.markSelectedAsStranger(db: db) } }
                } label: {
                    Label("Mark as Stranger", systemImage: "person.fill.questionmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(.secondary)
            }

            Divider()

            Button("Deselect All") { vm.clearSelection() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .onAppear { nameFocused = true }
    }

    private func saveLabel() {
        let name = labelName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        labelName = ""
        Task { if let db = appDatabase { await vm.labelSelected(as: name, db: db) } }
    }
}

// MARK: - PersonSummaryCard

private struct PersonSummaryCard: View {
    let personId: String
    let name: String
    let faceCount: Int
    let sampleRecords: [FaceGalleryRecord]
    let chipSize: CGFloat
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 10) {
                // 2x2 grid of face thumbnails that fills the card width
                GeometryReader { geo in
                    let thumbSize = max(20, (geo.size.width - 4) / 2)  // 4pt gap between columns
                    let rows: [[Int]] = [[0, 1], [2, 3]]
                    VStack(spacing: 4) {
                        ForEach(rows, id: \.self) { row in
                            HStack(spacing: 4) {
                                ForEach(row, id: \.self) { i in
                                    if i < sampleRecords.count {
                                        PersonSummaryThumbnail(record: sampleRecords[i], size: thumbSize)
                                    } else {
                                        Circle()
                                            .fill(Color(nsColor: .quaternarySystemFill))
                                            .frame(width: thumbSize, height: thumbSize)
                                    }
                                }
                            }
                        }
                    }
                }
                .aspectRatio(1, contentMode: .fit)

                VStack(spacing: 2) {
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("\(faceCount) photo\(faceCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isHovered ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor), lineWidth: isHovered ? 1.5 : 0.5)
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct PersonSummaryThumbnail: View {
    let record: FaceGalleryRecord
    let size: CGFloat
    @State private var image: NSImage? = nil

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(nsColor: .quaternarySystemFill)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.tertiary)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: record.id) {
            image = await FaceCropCache.shared.crop(
                id: record.id,
                proxyURL: record.proxyURL,
                bbox: record.bbox
            )
        }
    }
}

// MARK: - FaceChipCell

private struct FaceChipCell: View {
    let record: FaceGalleryRecord
    let isSelected: Bool
    let chipSize: CGFloat
    var showName: Bool = true
    let onTap: () -> Void
    let onConfirmReview: (Bool) -> Void

    @State private var image: NSImage? = nil
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                chipImage
                    .frame(width: chipSize, height: chipSize)
                    .clipShape(Circle())
                    .overlay(
                        Circle().stroke(
                            isSelected ? Color.accentColor
                            : record.needsReview ? Color.orange
                            : record.isLabeled ? Color.green.opacity(0.6)
                            : Color(nsColor: .separatorColor),
                            lineWidth: isSelected ? 3 : 1.5
                        )
                    )
                    // Orange dot badge for needsReview (bottom-left corner)
                    .overlay(alignment: .bottomLeading) {
                        if record.needsReview {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                                .offset(x: -2, y: 2)
                        }
                    }

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white, Color.accentColor)
                        .offset(x: 4, y: -4)
                }
            }

            if showName {
                Group {
                    if record.needsReview, let name = record.personName {
                        Text("?\(name)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.orange)
                    } else if let name = record.personName {
                        Text(name)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.primary)
                    } else {
                        Text("Unlabeled")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .lineLimit(1)
                .frame(width: chipSize)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .contextMenu {
            if record.needsReview {
                Button("Confirm match") { onConfirmReview(true) }
                Button("Not a match") { onConfirmReview(false) }
            }
        }
        .task(id: record.id) {
            await loadImage()
        }
    }

    @ViewBuilder
    private var chipImage: some View {
        if let img = image {
            Image(nsImage: img)
                .resizable()
                .scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: chipSize / 2)
                .fill(Color(nsColor: .quaternarySystemFill))
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                )
        }
    }

    private func loadImage() async {
        guard !loaded else { return }
        let img = await FaceCropCache.shared.crop(
            id: record.id,
            proxyURL: record.proxyURL,
            bbox: record.bbox
        )
        loaded = true
        image = img
    }
}

// MARK: - PersonFilterHeaderCard

/// Summary header shown at the top of the grid when filtering by a specific person.
private struct PersonFilterHeaderCard: View {
    let personId: String
    let personName: String
    let faceCount: Int
    let coverRecord: FaceGalleryRecord?
    let chipSize: CGFloat
    let onRename: (String) -> Void

    @State private var isEditingName = false
    @State private var editedName: String = ""

    var body: some View {
        HStack(spacing: 16) {
            // Avatar
            PersonFilterAvatar(record: coverRecord, size: 56)

            // Name + count
            VStack(alignment: .leading, spacing: 4) {
                if isEditingName {
                    HStack(spacing: 8) {
                        TextField("Name", text: $editedName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                            .onSubmit { commitRename() }
                        Button("Save") { commitRename() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Button("Cancel") { isEditingName = false }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .controlSize(.small)
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(personName)
                            .font(.system(size: 18, weight: .semibold))
                        Button {
                            editedName = personName
                            isEditingName = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Rename \"\(personName)\"")
                    }
                }

                Text("\(faceCount) face\(faceCount == 1 ? "" : "s")")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        )
    }

    private func commitRename() {
        let trimmed = editedName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { onRename(trimmed) }
        isEditingName = false
    }
}

private struct PersonFilterAvatar: View {
    let record: FaceGalleryRecord?
    let size: CGFloat
    @State private var image: NSImage? = nil

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(nsColor: .quaternarySystemFill)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.tertiary)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .task(id: record?.id) {
            guard let rec = record else { return }
            let url = rec.proxyURL
            let bbox = rec.bbox
            image = await Task.detached(priority: .utility) {
                let opts = [kCGImageSourceShouldCache: false] as CFDictionary
                guard let src = CGImageSourceCreateWithURL(url as CFURL, opts),
                      let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil),
                      let cropped = FaceEmbeddingService.cropFace(from: cgImage, bbox: bbox) else {
                    return nil as NSImage?
                }
                return NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
            }.value
        }
    }
}

// MARK: - FilterEmptyStateView

/// Friendly empty state shown when the active filter has no matching faces.
private struct FilterEmptyStateView: View {
    let filter: FaceGalleryViewModel.FaceFilter

    private var icon: String {
        switch filter {
        case .all:         return "person.2.slash"
        case .unlabeled:   return "checkmark.circle"
        case .strangers:   return "person.fill.questionmark"
        case .needsReview: return "checkmark.seal"
        case .person:      return "person.crop.circle.badge.checkmark"
        }
    }

    private var title: String {
        switch filter {
        case .all:         return "No faces yet"
        case .unlabeled:   return "All faces labeled"
        case .strangers:   return "No strangers marked"
        case .needsReview: return "Nothing needs review"
        case .person(_, let name): return "No faces for \(name)"
        }
    }

    private var subtitle: String {
        switch filter {
        case .all:         return "Import photos and run face indexing to get started."
        case .unlabeled:   return "Every detected face has been assigned to a person."
        case .strangers:   return "Mark unrecognized faces as strangers to track them here."
        case .needsReview: return "All borderline matches have been resolved."
        case .person(_, let name): return "\(name) has no confirmed face matches in the library."
        }
    }

    private var accentColor: Color {
        switch filter {
        case .unlabeled:   return .green
        case .needsReview: return .green
        default:           return .secondary
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(accentColor.opacity(0.6))
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.horizontal, 40)
    }
}

// MARK: - KeyboardAssignPopover

/// Lightweight popover triggered by pressing Return on selected faces.
/// Lets the user quickly type a name or pick an existing person.
private struct KeyboardAssignPopover: View {
    @ObservedObject var vm: FaceGalleryViewModel
    let appDatabase: AppDatabase?
    let onDismiss: () -> Void

    @State private var labelName = ""
    @FocusState private var fieldFocused: Bool

    /// People filtered by typed text (prefix first, then contains).
    private var filteredPeople: [(id: String, name: String)] {
        let all = vm.people.filter { $0.name != "Stranger" }
        guard !labelName.isEmpty else { return all }
        let q = labelName.lowercased()
        let prefix  = all.filter { $0.name.lowercased().hasPrefix(q) }
        let contain = all.filter { !$0.name.lowercased().hasPrefix(q) && $0.name.lowercased().contains(q) }
        return prefix + contain
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Label \(vm.selectedIds.count) face\(vm.selectedIds.count == 1 ? "" : "s")")
                .font(.system(size: 13, weight: .semibold))

            TextField("Name (Return to assign)", text: $labelName)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { save() }

            if !filteredPeople.isEmpty {
                ScrollView { VStack(spacing: 3) {
                    ForEach(filteredPeople, id: \.id) { person in
                        Button {
                            labelName = person.name
                            save()
                        } label: {
                            HStack {
                                Image(systemName: "person.fill").font(.caption).foregroundStyle(.secondary)
                                Text(person.name).font(.callout)
                                Spacer()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(Color(nsColor: .quaternarySystemFill)))
                        }
                        .buttonStyle(.plain)
                    }
                }}
                .frame(maxHeight: 160)
                Divider()
            }

            HStack(spacing: 8) {
                Button("Cancel") { onDismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button("Assign →") { save() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(labelName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Assign and advance to next cluster (Return)")
            }
        }
        .padding(16)
        .frame(width: 240)
        .onAppear { fieldFocused = true }
    }

    private func save() {
        let name = labelName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            if let db = appDatabase {
                await vm.labelSelected(as: name, db: db)
                // Auto-advance to next cluster after assigning
                if !vm.clusters.isEmpty { vm.nextCluster() }
            }
        }
        onDismiss()
    }
}
