import SwiftUI
import GRDB

// MARK: - MetadataFilter

struct MetadataFilter {
    var curationStates: Set<CurationState> = []
    var sceneTypes: Set<String> = []
    var peopleOnly: Bool = false
    var grayscaleOnly: Bool = false
    var yearRange: ClosedRange<Int>? = nil

    var isActive: Bool {
        !curationStates.isEmpty || !sceneTypes.isEmpty || peopleOnly || grayscaleOnly || yearRange != nil
    }

    func matches(_ photo: PhotoAsset) -> Bool {
        if !curationStates.isEmpty,
           !curationStates.contains(where: { $0.rawValue == photo.curationState }) {
            return false
        }
        if !sceneTypes.isEmpty {
            guard let scene = photo.sceneType, sceneTypes.contains(scene) else { return false }
        }
        if peopleOnly && photo.peopleDetected != true { return false }
        if grayscaleOnly && photo.isGrayscale != true { return false }
        if let range = yearRange {
            guard let dateStr = photo.dateModified,
                  let date = ISO8601DateFormatter().date(from: dateStr),
                  let year = Calendar.current.dateComponents([.year], from: date).year,
                  range.contains(year) else { return false }
        }
        return true
    }
}

// MARK: - SearchExperienceView

/// The full search section: ChatGPT-style landing when idle, results grid (or map)
/// once the user has submitted a query. Search history lives in the left sidebar.
struct SearchExperienceView: View {

    @ObservedObject var viewModel: LibraryViewModel
    let db: AppDatabase

    @AppStorage("face.distanceThreshold") private var faceThreshold: Double = 0.65

    // MARK: - Local state

    /// Tracks whether we are showing the map view of current results.
    @State private var showMapResults = false

    /// In-flight text in the landing search field (committed on Return/button tap).
    @State private var draftQuery: String = ""

    /// Recent search queries, newest first. Persisted across launches.
    @AppStorage("search.recentQueries") private var recentQueriesRaw: String = ""

    @State private var metadataFilter = MetadataFilter()
    @State private var showFilterSheet = false

    /// Conversational search state
    @StateObject private var conversation = SearchConversation()

    /// Search events from activity feed for recent chips.
    @State private var searchActivityEvents: [ActivityEvent] = []

    /// AI-generated suggestions from SearchSuggestionService.
    @State private var aiSuggestions: [SearchSuggestion] = []
    @State private var suggestionsLoading = false
    @State private var suggestionsFetchedAt: Date? = nil
    @State private var suggestionsFailed = false
    @State private var previewRefreshTask: Task<Void, Never>? = nil

    @Environment(\.activityEventService) private var activityEventService

    private var recentQueries: [String] {
        recentQueriesRaw.isEmpty ? [] : recentQueriesRaw.components(separatedBy: "\n")
    }

    private var hasResults: Bool {
        !viewModel.searchText.isEmpty || !viewModel.searchResults.isEmpty
    }

    private var resultsLabel: String {
        viewModel.searchText.isEmpty ? "People" : viewModel.searchText
    }

    /// viewModel.filteredPhotos further narrowed by the metadata filter.
    private var displayedPhotos: [PhotoAsset] {
        guard metadataFilter.isActive else { return viewModel.filteredPhotos }
        return viewModel.filteredPhotos.filter { metadataFilter.matches($0) }
    }

    /// Human-readable summary of which filters are active, for inline display.
    private var activeFilterChipItems: [(label: String, icon: String, color: Color, remove: () -> Void)] {
        var items: [(label: String, icon: String, color: Color, remove: () -> Void)] = []
        for state in CurationState.allCases where metadataFilter.curationStates.contains(state) {
            let s = state
            items.append((s.title, s.systemIcon, s.tint, { metadataFilter.curationStates.remove(s) }))
        }
        for scene in metadataFilter.sceneTypes.sorted() {
            let sc = scene
            items.append((sc.capitalized, "photo.on.rectangle", .accentColor, { metadataFilter.sceneTypes.remove(sc) }))
        }
        if metadataFilter.peopleOnly {
            items.append(("Has People", "person.fill", .blue, { metadataFilter.peopleOnly = false }))
        }
        if metadataFilter.grayscaleOnly {
            items.append(("Grayscale", "circle.lefthalf.filled", .secondary, { metadataFilter.grayscaleOnly = false }))
        }
        if let yr = metadataFilter.yearRange {
            items.append(("\(yr.lowerBound)–\(yr.upperBound)", "calendar", .purple, { metadataFilter.yearRange = nil }))
        }
        return items
    }

    // MARK: - Body

    var body: some View {
        if hasResults {
            resultsView
        } else if !conversation.messages.isEmpty {
            conversationView
        } else {
            landingView
        }
    }

    // MARK: - Landing (idle state)

    private var landingView: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 28) {
                // Title
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        Text("Search Your Library")
                            .font(.system(size: 28, weight: .bold))
                        Button {
                            showFilterSheet = true
                        } label: {
                            Image(systemName: metadataFilter.isActive
                                  ? "line.3.horizontal.decrease.circle.fill"
                                  : "line.3.horizontal.decrease.circle")
                                .font(.system(size: 20))
                                .foregroundStyle(metadataFilter.isActive ? Color.accentColor : Color.secondary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .help("Filter results by metadata")
                    }
                    if metadataFilter.isActive {
                        HStack(spacing: 6) {
                            ForEach(activeFilterChipItems, id: \.label) { chip in
                                Button {
                                    chip.remove()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: chip.icon)
                                            .font(.system(size: 10, weight: .semibold))
                                        Text(chip.label)
                                            .font(.system(size: 11, weight: .semibold))
                                        Image(systemName: "xmark")
                                            .font(.system(size: 8, weight: .bold))
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(chip.color.opacity(0.15), in: Capsule())
                                    .overlay(Capsule().strokeBorder(chip.color.opacity(0.4), lineWidth: 1))
                                    .foregroundStyle(chip.color)
                                }
                                .buttonStyle(.plain)
                            }
                            Button("Clear all") { metadataFilter = MetadataFilter() }
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .buttonStyle(.plain)
                        }
                    } else {
                        Text("Ask anything about your photos — places, people, dates, notes, or prints.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                // Search box + chip rows
                VStack(spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 14)

                        TextField(
                            "e.g. \"rainy street shots from 2023\" or \"prints with tungsten tone\"",
                            text: $draftQuery,
                            axis: .vertical
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .lineLimit(1...4)
                        .padding(.vertical, 13)
                        .onSubmit { commitSearch() }

                        if !draftQuery.isEmpty {
                            Button { commitSearch() } label: {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 10)
                        }
                    }
                    .padding(.horizontal, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
                    )
                    .frame(maxWidth: 580)

                    // Editorial filter chips
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            chipButton("Keepers", icon: "star.fill") {
                                draftQuery = "keeper photos"
                                commitSearch()
                            }
                            chipButton("Needs Review", icon: "exclamationmark.circle") {
                                draftQuery = "needs review"
                                commitSearch()
                            }
                            chipButton("Rejects", icon: "xmark.circle") {
                                draftQuery = "rejected photos"
                                commitSearch()
                            }
                            chipButton("Prints", icon: "printer") {
                                draftQuery = "photos with prints"
                                commitSearch()
                            }
                            chipButton("Map", icon: "map") {
                                viewModel.selectedSection = .search
                                showMapResults = true
                                commitSearch()
                            }
                        }
                        // Navigation shortcuts
                        HStack(spacing: 8) {
                            chipButton("Open Jobs", icon: "checklist") {
                                viewModel.selectedSection = .jobs
                            }
                            chipButton("Staged Imports", icon: "tray.and.arrow.down") {
                                viewModel.selectedSection = .jobs
                            }
                            chipButton("Activity", icon: "clock") {
                                viewModel.selectedSection = .activity
                            }
                            chipButton("Not Developed", icon: "wand.and.stars") {
                                draftQuery = "keepers without adjustments"
                                commitSearch()
                            }
                        }
                    }

                    // Recent searches — inline chips
                    if !recentSearchChips.isEmpty {
                        recentChipsRow
                    }

                    // AI-generated suggestions
                    if suggestionsLoading || !aiSuggestions.isEmpty {
                        aiSuggestionsRow
                    }
                }
            }

            // Face browser
            FaceBrowseSection(db: db, viewModel: viewModel) { personName in
                draftQuery = ""
                sendConversationMessage("photos of \(personName)")
            }
            .padding(.bottom, 24)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await loadSearchHistory()
            let stale = suggestionsFetchedAt.map { Date().timeIntervalSince($0) > 300 } ?? true
            if aiSuggestions.isEmpty || stale { await fetchAISuggestions() }
        }
        .onAppear {
            draftQuery = ""
            if let q = viewModel.pendingSearchQuery {
                viewModel.pendingSearchQuery = nil
                sendConversationMessage(q)
            }
        }
        .onChange(of: viewModel.pendingSearchQuery) { _, newQuery in
            guard let q = newQuery else { return }
            viewModel.pendingSearchQuery = nil
            sendConversationMessage(q)
        }
        .sheet(isPresented: $showFilterSheet) {
            MetadataFilterSheet(
                filter: $metadataFilter,
                allPhotos: viewModel.photos
            )
        }
    }

    // MARK: - Recent chips

    private var recentSearchChips: [String] {
        var seen = Set<String>()
        var result: [String] = []
        // Activity events are source of truth; AppStorage fills gaps
        let candidates = searchActivityEvents.map { $0.title } + recentQueries
        for title in candidates {
            let key = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(title)
            if result.count == 6 { break }
        }
        return result
    }

    private var recentChipsRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Recent")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: 580, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(recentSearchChips, id: \.self) { query in
                        Button {
                            draftQuery = ""
                            // Resume from activity event if available
                            if let event = searchActivityEvents.first(where: { $0.title == query }) {
                                resumeSearch(from: event)
                            } else {
                                sendConversationMessage(query)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "clock")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                Text(query)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.05), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Button("Clear") {
                        clearHistory()
                        searchActivityEvents = []
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 580)
        }
    }

    // MARK: - AI suggestions

    private var aiSuggestionsRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                Image(systemName: "sparkles").font(.system(size: 10))
                Text("Suggested").font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: 580, alignment: .leading)

            if suggestionsLoading {
                HStack(spacing: 8) {
                    ForEach(0..<4, id: \.self) { _ in
                        Capsule()
                            .fill(Color.secondary.opacity(0.08))
                            .frame(width: 90, height: 28)
                    }
                }
                .frame(maxWidth: 580, alignment: .leading)
            } else if suggestionsFailed {
                Button {
                    suggestionsFailed = false
                    Task { await fetchAISuggestions() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 9))
                        Text("Couldn't load suggestions — tap to retry")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 580, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(aiSuggestions) { suggestion in
                            Button {
                                draftQuery = suggestion.query
                                commitSearch()
                            } label: {
                                HStack(spacing: 4) {
                                    Text(suggestion.label)
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(Color.purple.opacity(0.65))
                                    Text(suggestion.query)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.purple.opacity(0.07), in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.purple.opacity(0.2), lineWidth: 1))
                                .foregroundStyle(.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: 580)
            }
        }
    }

    private func fetchAISuggestions() async {
        guard !suggestionsLoading else { return }
        suggestionsLoading = true
        defer { suggestionsLoading = false }

        let photos = viewModel.photos
        let needsReview = photos.filter { $0.curationState == CurationState.needsReview.rawValue }.count
        let keepers = photos.filter { $0.curationState == CurationState.keeper.rawValue }.count

        var sceneCounts: [String: Int] = [:]
        for photo in photos {
            if let scene = photo.sceneType { sceneCounts[scene, default: 0] += 1 }
        }
        let topScenes = sceneCounts.sorted { $0.value > $1.value }.prefix(5).map { ($0.key, $0.value) }

        let knownPeople: [String]
        do {
            knownPeople = try await db.dbPool.read { d in
                try String.fetchAll(d, sql: """
                    SELECT name FROM person_identities
                    WHERE name IS NOT NULL AND name != ''
                    ORDER BY name LIMIT 20
                """)
            }
        } catch { knownPeople = [] }

        let context = SearchSuggestionService.LibraryContext(
            totalPhotos: photos.count,
            dateRange: nil,
            topScenes: Array(topScenes),
            knownPeople: knownPeople,
            needsReviewCount: needsReview,
            keeperCount: keepers
        )

        do {
            let service = SearchSuggestionService()
            aiSuggestions = try await service.fetchSuggestions(
                recentSearches: recentQueries,
                libraryStats: context
            )
            suggestionsFetchedAt = Date()
            suggestionsFailed = false
        } catch {
            print("[SearchExperienceView] AI suggestions: \(error)")
            if aiSuggestions.isEmpty { suggestionsFailed = true }
        }
    }

    // MARK: - Results view

    private var resultsView: some View {
        VStack(spacing: 0) {
            // Results toolbar
            resultsToolbar

            // Fuzzy match / unresolved / fallback feedback bar
            if let intent = viewModel.lastIntent,
               (!intent.resolvedPeople.isEmpty || !intent.unresolvedNames.isEmpty || intent.usedUnionFallback || !intent.emptyPeople.isEmpty) {
                intentFeedbackBar(intent)
            }

            Divider()

            if showMapResults {
                mapResultsArea
            } else {
                gridResultsArea
            }
        }
        .onChange(of: viewModel.lastIntent?.preferMapView) {
            if viewModel.lastIntent?.preferMapView == true {
                showMapResults = true
            }
        }
    }

    private var resultsToolbar: some View {
        HStack(spacing: 10) {
            // New Search — clears everything and returns to landing
            Button {
                resetConversation()
                viewModel.faceQueryImage = nil
                showMapResults = false
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                Text("New Search")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Divider().frame(height: 18)

            // Face chip — shown when search was triggered by a face tap
            if let faceImg = viewModel.faceQueryImage {
                Image(nsImage: faceImg)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
            }

            // Resolved people chips from routed search
            if let intent = viewModel.lastIntent {
                ForEach(intent.resolvedPeople) { person in
                    Text(person.personName)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
            }

            // Active query
            Text(resultsLabel)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)

            if viewModel.isSearching {
                ProgressView().scaleEffect(0.7)
            } else {
                Text("· \(displayedPhotos.count) results")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Active filter chips (inline in toolbar)
            if metadataFilter.isActive {
                ForEach(activeFilterChipItems, id: \.label) { chip in
                    Button {
                        chip.remove()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: chip.icon)
                                .font(.system(size: 9, weight: .semibold))
                            Text(chip.label)
                                .font(.system(size: 11, weight: .medium))
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(chip.color.opacity(0.14), in: Capsule())
                        .overlay(Capsule().strokeBorder(chip.color.opacity(0.35), lineWidth: 1))
                        .foregroundStyle(chip.color)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Metadata filter button
            Button {
                showFilterSheet = true
            } label: {
                Image(systemName: metadataFilter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(metadataFilter.isActive ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(metadataFilter.isActive ? "Metadata filters active — click to edit" : "Filter by metadata")

            // Grid / Map toggle
            Picker("View", selection: $showMapResults) {
                Label("Grid", systemImage: "square.grid.2x2").tag(false)
                Label("Map",  systemImage: "map").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .help("Toggle between grid and map view of results")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var gridResultsArea: some View {
        ScrollView {
            if displayedPhotos.isEmpty && !viewModel.isSearching {
                VStack(spacing: 14) {
                    Image(systemName: metadataFilter.isActive ? "line.3.horizontal.decrease.circle" : "person.slash")
                        .font(.system(size: 40)).foregroundStyle(.tertiary)
                    Text(metadataFilter.isActive
                         ? "No photos match the active filters"
                         : "No matching photos for \"\(resultsLabel)\"")
                        .font(.title3.weight(.semibold))
                    if metadataFilter.isActive {
                        Button("Clear Filters") { metadataFilter = MetadataFilter() }
                            .buttonStyle(.bordered)
                    } else {
                        Text("Try running Re-index Faces in Settings > Machine Learning, or browse by map.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Search by Map") { showMapResults = true }
                            .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: 460).padding(.top, 80)
                .frame(maxWidth: .infinity)
            } else {
                SearchResultsGrid(photos: displayedPhotos, viewModel: viewModel)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 24)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var mapResultsArea: some View {
        MapPhotoView(
            photos: displayedPhotos,
            photoRepo: viewModel.photoRepo,
            selectedLocationFilter: .constant(nil)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func commitSearch() {
        let q = draftQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            // Empty submit on active conversation → execute the search
            if conversation.canExecute {
                executeConversationSearch()
            }
            return
        }
        draftQuery = ""
        // Short-circuit navigation intents — no AI round-trip needed
        if routeNavigationIntent(q) { return }
        addToHistory(q)
        sendConversationMessage(q)
    }

    /// Returns true and navigates if the query is clearly a section-navigation request.
    /// Only matches explicit navigation phrases to avoid interfering with real searches
    /// like "import jobs from 2023" or "activity by location".
    @discardableResult
    private func routeNavigationIntent(_ query: String) -> Bool {
        let lower = query.lowercased().trimmingCharacters(in: .whitespaces)

        let jobsPhrases  = ["open jobs", "show jobs", "go to jobs", "view jobs", "jobs page",
                            "staged imports", "import queue", "pending imports", "triage queue"]
        let activityPhrases = ["open activity", "show activity", "activity feed", "go to activity",
                               "recent activity", "view activity", "activity log"]

        if jobsPhrases.contains(where: { lower.hasPrefix($0) || lower == $0 }) {
            viewModel.selectedSection = .jobs
            return true
        }
        if activityPhrases.contains(where: { lower.hasPrefix($0) || lower == $0 }) {
            viewModel.selectedSection = .activity
            return true
        }
        return false
    }

    /// Send a message in the conversational search flow.
    private func sendConversationMessage(_ text: String) {
        guard !conversation.isThinking else { return }
        conversation.addUserMessage(text)
        conversation.isThinking = true

        Task {
            // Get approximate count for context
            let count: Int? = conversation.canExecute
                ? (try? await viewModel.photoRepo.searchCount(filter: conversation.currentFilter))
                : nil

            let response = await viewModel.refineSearchQuery(
                messages: conversation.apiMessages(),
                currentFilter: conversation.currentFilter,
                photoCount: count
            )

            conversation.addAssistantResponse(response, resultCount: nil)

            // Fetch count + limited preview thumbnails using full search (filter + person intersection)
            let hasFilter = !conversation.currentFilter.isEmpty
            let hasPersons = !conversation.currentPersonNames.isEmpty
            if hasFilter || hasPersons {
                let preview = await viewModel.previewConversationSearch(
                    filter: conversation.currentFilter,
                    personNames: conversation.currentPersonNames,
                    limit: 8
                )

                if let idx = conversation.messages.indices.last,
                   conversation.messages[idx].role == .assistant {
                    conversation.messages[idx].resultCount = preview.count
                    if !preview.photos.isEmpty {
                        conversation.messages[idx].previewPhotoNames = preview.photos.map(\.canonicalName)
                    }
                    conversation.messages[idx].nearbyHint = preview.nearbyHint
                }
            }

            conversation.isThinking = false

            // Auto-set map view preference
            if response.preferMapView == true {
                showMapResults = true
            }
        }
    }

    /// Execute the final accumulated search from the conversation.
    private func executeConversationSearch() {
        conversation.state = .executing

        // Build a summary query string for display
        let summaryParts: [String] = {
            var parts: [String] = []
            let f = conversation.currentFilter
            if let loc = f.location { parts.append(loc) }
            if let cs = f.curationState { parts.append(cs) }
            if let y = f.yearFrom { parts.append("\(y)") }
            parts.append(contentsOf: conversation.currentPersonNames)
            if let kw = f.keywords { parts.append(contentsOf: kw) }
            return parts
        }()
        let queryText = summaryParts.isEmpty
            ? conversation.messages.first(where: { $0.role == .user })?.content ?? "search"
            : summaryParts.joined(separator: " ")

        viewModel.searchText = queryText
        addToHistory(queryText)

        // Execute using the accumulated filter directly
        Task {
            await viewModel.executeConversationSearch(
                filter: conversation.currentFilter,
                personNames: conversation.currentPersonNames
            )
            conversation.state = .done

            // Log to activity feed
            let filterJSON = (try? JSONEncoder().encode(conversation.currentFilter))
                .flatMap { String(data: $0, encoding: .utf8) }
            let resultCount = viewModel.searchResults.count
            try? await activityEventService?.emitSearch(
                query: queryText,
                filterJSON: filterJSON,
                personNames: conversation.currentPersonNames,
                resultCount: resultCount,
                conversationJSON: conversation.snapshotJSON()
            )
            await loadSearchHistory()
        }
    }

    /// Load recent search events from the activity feed.
    private func loadSearchHistory() async {
        do {
            let repo = ActivityEventRepository(db: db)
            let events = try await repo.fetchRecent(kind: .search, limit: 20)
            searchActivityEvents = events
        } catch {
            // Silently fail — history is non-critical
        }
    }

    /// Resume a previous search conversation from an activity event.
    private func resumeSearch(from event: ActivityEvent) {
        // Clear all stale state before restoring the saved conversation
        resetConversation()

        guard let metadata = event.metadata,
              let data = metadata.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let conversationJSON = json["conversation_json"] as? String else {
            print("[SearchExperienceView] resumeSearch: no conversation_json in event '\(event.title)', falling back to fresh search")
            draftQuery = event.title
            sendConversationMessage(event.title)
            return
        }

        if conversation.restoreFromJSON(conversationJSON) {
            // Conversation restored — user is back in the builder
        } else {
            print("[SearchExperienceView] resumeSearch: restoreFromJSON failed for '\(event.title)', falling back to fresh search")
            draftQuery = event.title
            sendConversationMessage(event.title)
        }
    }

    /// Start a fresh conversation.
    private func resetConversation() {
        conversation.reset()
        viewModel.searchText = ""
        viewModel.searchResults = []
        viewModel.lastFilter = nil
        viewModel.lastIntent = nil
        draftQuery = ""
    }

    // MARK: - Conversation View (multi-turn search builder)

    private var conversationView: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                // Top bar with back button and "Show Results"
                HStack(spacing: 12) {
                    Button {
                        resetConversation()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .semibold))
                            Text("New Search")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if conversation.canExecute {
                        Button {
                            executeConversationSearch()
                        } label: {
                            Label("Show Results", systemImage: "magnifyingglass")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

                Divider()

                // Chat thread
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(conversation.messages) { message in
                                SearchChatBubble(
                                    message: message,
                                    onSuggestionTap: { suggestion in
                                        sendConversationMessage(suggestion)
                                    },
                                    onShowResults: conversation.canExecute ? {
                                        executeConversationSearch()
                                    } : nil
                                )
                                .id(message.id)
                            }

                            // Typing indicator
                            if conversation.isThinking {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.purple)
                                        .frame(width: 28, height: 28)
                                        .background(Circle().fill(Color.purple.opacity(0.12)))

                                    TypingDotsView()
                                }
                                .padding(14)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(Color(nsColor: .controlBackgroundColor))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                                        )
                                )
                                .id("thinking")
                            }
                        }
                        .padding(20)
                    }
                    .onChange(of: conversation.messages.count) { _ in
                        withAnimation {
                            if let lastId = conversation.messages.last?.id {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: conversation.isThinking) { _, thinking in
                        if thinking {
                            withAnimation { proxy.scrollTo("thinking", anchor: .bottom) }
                        }
                    }
                }

                Divider()

                // Live removable filter chips — show as soon as any filter exists
                if !conversation.currentFilter.isEmpty || !conversation.currentPersonNames.isEmpty {
                    activeFilterChips
                }

                // Input bar
                conversationInputBar
            }
            .frame(maxWidth: 760)
        }
        .frame(maxWidth: .infinity)
    }

    /// Live removable chips showing the current accumulated filter + person names.
    private var activeFilterChips: some View {
        let chips = buildActiveChips()
        return Group {
            if !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chips, id: \.label) { chip in
                            Button {
                                chip.remove()
                                refreshPreviewForLastMessage()
                            } label: {
                                HStack(spacing: 4) {
                                    Text(chip.label)
                                        .font(.system(size: 10, weight: .semibold))
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.purple.opacity(0.15)))
                                .foregroundStyle(.purple)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private struct FilterChipItem: Identifiable {
        let label: String
        let remove: () -> Void
        var id: String { label }
    }

    private func buildActiveChips() -> [FilterChipItem] {
        var chips: [FilterChipItem] = []
        let f = conversation.currentFilter
        if let loc = f.location {
            chips.append(FilterChipItem(label: loc) { conversation.currentFilter.location = nil })
        }
        if let y = f.yearFrom {
            chips.append(FilterChipItem(label: "from \(y)") { conversation.currentFilter.yearFrom = nil })
        }
        if let y = f.yearTo {
            chips.append(FilterChipItem(label: "to \(y)") { conversation.currentFilter.yearTo = nil })
        }
        if let cs = f.curationState {
            chips.append(FilterChipItem(label: cs.replacingOccurrences(of: "_", with: " ")) { conversation.currentFilter.curationState = nil })
        }
        if let sc = f.sceneType {
            chips.append(FilterChipItem(label: sc) { conversation.currentFilter.sceneType = nil })
        }
        if let tod = f.timeOfDay {
            chips.append(FilterChipItem(label: tod.replacingOccurrences(of: "_", with: " ")) { conversation.currentFilter.timeOfDay = nil })
        }
        if let cm = f.cameraModel {
            chips.append(FilterChipItem(label: cm) { conversation.currentFilter.cameraModel = nil })
        }
        if let ft = f.fileType {
            chips.append(FilterChipItem(label: ft.uppercased()) { conversation.currentFilter.fileType = nil })
        }
        if f.printAttempted == true {
            chips.append(FilterChipItem(label: "printed") { conversation.currentFilter.printAttempted = nil })
        }
        if f.peopleDetected == true {
            chips.append(FilterChipItem(label: "with people") { conversation.currentFilter.peopleDetected = nil })
        }
        if let kws = f.keywords {
            for kw in kws {
                let keyword = kw
                chips.append(FilterChipItem(label: kw) {
                    conversation.currentFilter.keywords?.removeAll { $0 == keyword }
                    if conversation.currentFilter.keywords?.isEmpty == true { conversation.currentFilter.keywords = nil }
                })
            }
        }
        for name in conversation.currentPersonNames {
            let personName = name
            chips.append(FilterChipItem(label: name) {
                conversation.currentPersonNames.removeAll { $0 == personName }
            })
        }
        return chips
    }

    /// Re-run the preview for the last assistant message after a filter chip is removed.
    private func refreshPreviewForLastMessage() {
        previewRefreshTask?.cancel()
        previewRefreshTask = Task {
            let preview = await viewModel.previewConversationSearch(
                filter: conversation.currentFilter,
                personNames: conversation.currentPersonNames,
                limit: 8
            )
            guard !Task.isCancelled else { return }
            if let idx = conversation.messages.indices.last,
               conversation.messages[idx].role == .assistant {
                conversation.messages[idx].resultCount = preview.count
                conversation.messages[idx].previewPhotoNames = preview.photos.isEmpty ? nil : preview.photos.map(\.canonicalName)
                conversation.messages[idx].nearbyHint = preview.nearbyHint
                conversation.messages[idx].parsedFilter = conversation.currentFilter
                conversation.messages[idx].personNames = conversation.currentPersonNames.isEmpty ? nil : conversation.currentPersonNames
            }
        }
    }

    private var conversationInputBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(
                conversation.canExecute ? "Refine your search or press Return to show results..." : "Describe what you're looking for...",
                text: $draftQuery,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .lineLimit(1...3)
            .onSubmit { commitSearch() }

            if !draftQuery.isEmpty {
                Button { commitSearch() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            } else if conversation.canExecute {
                Button { executeConversationSearch() } label: {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help("Execute search with current filters")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
        .opacity(conversation.isThinking ? 0.5 : 1.0)
        .disabled(conversation.isThinking)
        .animation(.easeInOut(duration: 0.15), value: conversation.isThinking)
    }

    private func addToHistory(_ query: String) {
        var queries = recentQueries.filter { $0 != query }
        queries.insert(query, at: 0)
        recentQueriesRaw = queries.prefix(20).joined(separator: "\n")
    }

    private func clearHistory() {
        recentQueriesRaw = ""
    }

    @ViewBuilder
    private func intentFeedbackBar(_ intent: SearchIntent) -> some View {
        HStack(spacing: 8) {
            // Fuzzy match notes
            ForEach(intent.resolvedPeople.filter { $0.confidence < 1.0 }) { person in
                Label(
                    "Matched \"\(person.queryName)\" → \(person.personName)",
                    systemImage: "person.fill.checkmark"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            // Unresolved names
            ForEach(intent.unresolvedNames, id: \.self) { name in
                Label(
                    "Could not find \"\(name)\"",
                    systemImage: "person.fill.questionmark"
                )
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            }

            // People with no tagged photos
            ForEach(intent.emptyPeople, id: \.self) { name in
                Label(
                    "\(name) has no tagged photos yet",
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            // Union fallback note
            if intent.usedUnionFallback {
                Label(
                    "No photos match all criteria — showing individual matches",
                    systemImage: "arrow.triangle.branch"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func chipButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SearchResultsGrid
// Thin wrapper that reuses LibraryWorkspaceView's photo grid logic.

private struct SearchResultsGrid: View {
    let photos: [PhotoAsset]
    @ObservedObject var viewModel: LibraryViewModel

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 150, maximum: 220), spacing: 16),
            count: max(2, Int(viewModel.gridColumns.rounded()))
        )
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(photos) { photo in
                PhotoCardAsset(
                    photo: photo,
                    isSelected: viewModel.selectedPhotoIDs.contains(photo.id)
                        || viewModel.selectedPhotoID == photo.id
                )
                .onTapGesture {
                    let isCmd = NSEvent.modifierFlags.contains(.command)
                    if isCmd {
                        if viewModel.selectedPhotoIDs.contains(photo.id) {
                            viewModel.selectedPhotoIDs.remove(photo.id)
                        } else {
                            viewModel.selectedPhotoIDs.insert(photo.id)
                        }
                    } else {
                        viewModel.selectedPhotoIDs = []
                        viewModel.selectedPhotoID = photo.id
                    }
                }
            }
        }
    }
}

// MARK: - FaceBrowseSection

/// Shows one chip per labeled person so the user can tap to find all their photos.
private struct FaceBrowseSection: View {
    let db: AppDatabase
    @ObservedObject var viewModel: LibraryViewModel
    var onPersonTapped: ((String) -> Void)? = nil

    @State private var representatives: [FaceGalleryRecord] = []
    @State private var hasAnyEmbeddings = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !representatives.isEmpty {
                HStack {
                    Text("People")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("· \(representatives.count)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 24)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(representatives) { record in
                            PersonBrowseChip(record: record, viewModel: viewModel, db: db, onPersonTapped: onPersonTapped)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 4)
                }
                .frame(height: 100)
            } else if loaded {
                HStack(spacing: 8) {
                    Image(systemName: hasAnyEmbeddings ? "person.badge.key" : "person.slash")
                        .foregroundStyle(.secondary)
                    Text(hasAnyEmbeddings
                         ? "Label people in the People tab to browse here."
                         : "No faces indexed — go to Settings › Machine Learning › Re-index Faces.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            let faceRepo = FaceEmbeddingRepository(db: db)
            hasAnyEmbeddings = (try? await faceRepo.fetchHasAnyEmbeddings()) ?? false
            if let reps = try? await faceRepo.fetchLabeledPersonRepresentatives() {
                representatives = reps
            }
        }
    }
}

// MARK: - PersonBrowseChip

/// One chip per labeled person — tapping finds all photos of that person.
private struct PersonBrowseChip: View {
    let record: FaceGalleryRecord
    @ObservedObject var viewModel: LibraryViewModel
    let db: AppDatabase
    var onPersonTapped: ((String) -> Void)? = nil

    @State private var faceImage: NSImage? = nil

    var body: some View {
        Button {
            guard let personName = record.personName else { return }
            if let handler = onPersonTapped {
                handler(personName)
            } else {
                // Fallback: direct search (shouldn't normally be reached)
                guard let personId = record.embedding.personId else { return }
                Task {
                    await viewModel.searchByPerson(
                        personId: personId, personName: personName, faceImage: faceImage, db: db
                    )
                }
            }
        } label: {
            VStack(spacing: 5) {
                Group {
                    if let img = faceImage {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color(nsColor: .controlBackgroundColor)
                            .overlay(ProgressView().scaleEffect(0.6))
                    }
                }
                .frame(width: 62, height: 62)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))

                Text(record.personName ?? "")
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 72)
            }
        }
        .buttonStyle(.plain)
        .help("Find all photos of \(record.personName ?? "this person")")
        .task(id: record.id) {
            guard faceImage == nil else { return }
            let url = record.proxyURL
            let bbox = record.bbox
            faceImage = await Task.detached(priority: .utility) {
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

// MARK: - MetadataFilterSheet

private struct MetadataFilterSheet: View {
    @Binding var filter: MetadataFilter
    let allPhotos: [PhotoAsset]
    @Environment(\.dismiss) private var dismiss

    // Available scene types derived from what's actually indexed
    private var availableSceneTypes: [String] {
        let raw = Set(allPhotos.compactMap { $0.sceneType })
        return raw.sorted()
    }

    private var yearRange: ClosedRange<Int>? {
        let isoFmt = ISO8601DateFormatter()
        let cal = Calendar.current
        let years = allPhotos.compactMap { photo -> Int? in
            guard let s = photo.dateModified, let d = isoFmt.date(from: s) else { return nil }
            return cal.component(.year, from: d)
        }
        guard let lo = years.min(), let hi = years.max(), lo <= hi else { return nil }
        return lo...hi
    }

    @State private var yearLow: Double = 2000
    @State private var yearHigh: Double = 2025

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Filter by Metadata")
                    .font(.title2.bold())
                Spacer()
                if filter.isActive {
                    Button("Clear All") { filter = MetadataFilter() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // MARK: Curation
                    filterSection("Curation State") {
                        flowPills(CurationState.allCases) { state in
                            toggleWithIcon(
                                label: state.title,
                                icon: state.systemIcon,
                                color: state.tint,
                                active: filter.curationStates.contains(state)
                            ) {
                                if filter.curationStates.contains(state) {
                                    filter.curationStates.remove(state)
                                } else {
                                    filter.curationStates.insert(state)
                                }
                            }
                        }
                    }

                    // MARK: Scene Type (only if any are indexed)
                    if !availableSceneTypes.isEmpty {
                        filterSection("Scene Type") {
                            flowPills(availableSceneTypes) { scene in
                                toggle(
                                    label: scene.capitalized,
                                    color: .accentColor,
                                    active: filter.sceneTypes.contains(scene)
                                ) {
                                    if filter.sceneTypes.contains(scene) {
                                        filter.sceneTypes.remove(scene)
                                    } else {
                                        filter.sceneTypes.insert(scene)
                                    }
                                }
                            }
                        }
                    }

                    // MARK: Flags
                    filterSection("Flags") {
                        HStack(spacing: 12) {
                            toggle(label: "Has People", color: .blue, active: filter.peopleOnly) {
                                filter.peopleOnly.toggle()
                            }
                            toggle(label: "Grayscale", color: .gray, active: filter.grayscaleOnly) {
                                filter.grayscaleOnly.toggle()
                            }
                        }
                    }

                    // MARK: Year range
                    if let yr = yearRange {
                        filterSection("Year") {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(filter.yearRange != nil ? "\(filter.yearRange!.lowerBound)" : "\(yr.lowerBound)")
                                        .font(.system(.body, design: .monospaced))
                                    Text("–")
                                    Text(filter.yearRange != nil ? "\(filter.yearRange!.upperBound)" : "\(yr.upperBound)")
                                        .font(.system(.body, design: .monospaced))
                                    Spacer()
                                    if filter.yearRange != nil {
                                        Button("Any Year") { filter.yearRange = nil }
                                            .font(.caption)
                                            .buttonStyle(.plain)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                HStack(spacing: 8) {
                                    Text("\(yr.lowerBound)")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Slider(
                                        value: $yearLow,
                                        in: Double(yr.lowerBound)...Double(yr.upperBound),
                                        step: 1
                                    ) { _ in applyYearRange(yr) }
                                    .frame(maxWidth: .infinity)

                                    Slider(
                                        value: $yearHigh,
                                        in: Double(yr.lowerBound)...Double(yr.upperBound),
                                        step: 1
                                    ) { _ in applyYearRange(yr) }
                                    .frame(maxWidth: .infinity)
                                    Text("\(yr.upperBound)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if let yr = yearRange {
                yearLow = Double(filter.yearRange?.lowerBound ?? yr.lowerBound)
                yearHigh = Double(filter.yearRange?.upperBound ?? yr.upperBound)
            }
        }
    }

    private func applyYearRange(_ available: ClosedRange<Int>) {
        let lo = Int(yearLow.rounded())
        let hi = max(lo, Int(yearHigh.rounded()))
        let isFullRange = lo == available.lowerBound && hi == available.upperBound
        filter.yearRange = isFullRange ? nil : lo...hi
    }

    @ViewBuilder
    private func filterSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    @ViewBuilder
    private func flowPills<T: Hashable>(_ items: [T], @ViewBuilder pill: @escaping (T) -> some View) -> some View {
        WrappingHStack(items: items, pill: pill)
    }

    private func toggle(label: String, color: Color, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(active ? color.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
                .overlay(Capsule().stroke(active ? color : Color.clear, lineWidth: 1.5))
                .foregroundStyle(active ? color : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func toggleWithIcon(label: String, icon: String, color: Color, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(active ? color : Color.secondary)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(active ? color.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().stroke(active ? color : Color.clear, lineWidth: 1.5))
            .foregroundStyle(active ? color : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - WrappingHStack

/// Simple left-to-right wrapping layout for pill rows.
private struct WrappingHStack<T: Hashable, Pill: View>: View {
    let items: [T]
    let pill: (T) -> Pill

    var body: some View {
        // SwiftUI doesn't ship a wrapping flow layout until iOS 16 / macOS 13 Layout protocol.
        // For simplicity use a fixed 3-column grid that works for small pill sets.
        let cols = [GridItem(.adaptive(minimum: 110), spacing: 8)]
        LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                pill(item)
            }
        }
    }
}
