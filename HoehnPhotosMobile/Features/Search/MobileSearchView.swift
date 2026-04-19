import SwiftUI
import UIKit
import HoehnPhotosCore

// MARK: - MobileSearchFilter

struct MobileSearchFilter {
    var curationStates: Set<CurationState> = []
    var grayscaleOnly: Bool = false
    var yearRange: ClosedRange<Int>? = nil

    var isActive: Bool {
        !curationStates.isEmpty || grayscaleOnly || yearRange != nil
    }
}

// MARK: - PlacesDisplayMode

private enum PlacesDisplayMode: String, CaseIterable, Identifiable {
    case grid, map
    var id: String { rawValue }
    var icon: String { self == .grid ? "square.grid.2x2" : "map" }
    var label: String { self == .grid ? "Grid" : "Map" }
}

// MARK: - MobileSearchView

struct MobileSearchView: View {

    @Environment(\.appDatabase) private var appDatabase
    @EnvironmentObject private var syncService: PeerSyncService

    // Scope + query state
    @AppStorage("searchScope") private var scopeRaw: String = SearchScope.all.rawValue
    private var scope: SearchScope {
        get { SearchScope(rawValue: scopeRaw) ?? .all }
    }
    private func setScope(_ new: SearchScope) {
        scopeRaw = new.rawValue
    }

    @State private var query = ""
    @State private var isSearching = false
    @State private var selectedPhotoIndex: Int?
    @State private var resultLimit: Int = 100
    @State private var placesMode: PlacesDisplayMode = .grid

    // Per-scope result caches
    @State private var allResults: [PhotoAsset] = []
    @State private var peopleMatches: [MobilePhotoRepository.PersonMatch] = []
    @State private var peopleFaceCrops: [String: UIImage] = [:]
    @State private var placesResults: [PhotoAsset] = []
    @State private var cameraMatches: [MobilePhotoRepository.CameraMatch] = []
    @State private var dateBuckets: [MobilePhotoRepository.DateBucket] = []
    @State private var currentGridResults: [PhotoAsset] = []  // drives tap -> detail sheet

    @State private var filter = MobileSearchFilter()
    @State private var showFilterSheet = false
    @State private var sortNewestFirst = true
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var toast: ToastMessage?
    @AppStorage("searchCompactGrid") private var useCompactGrid = false

    @AppStorage("recentSearches") private var recentSearchesJSON: String = "[]"

    @Namespace private var scopeNamespace
    @Namespace private var heroNamespace

    private var recentSearches: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(recentSearchesJSON.utf8))) ?? []
    }

    private func addRecentSearch(_ q: String) {
        guard !q.isEmpty else { return }
        var recents = recentSearches.filter { $0 != q }
        recents.insert(q, at: 0)
        if recents.count > 5 { recents = Array(recents.prefix(5)) }
        recentSearchesJSON = (try? String(data: JSONEncoder().encode(recents), encoding: .utf8)) ?? "[]"
    }

    private func clearRecentSearches() {
        recentSearchesJSON = "[]"
    }

    private func debouncedSearch() {
        searchDebounceTask?.cancel()
        resultLimit = 100
        searchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await runScopedSearch()
        }
    }

    private var columns: [GridItem] {
        let count = useCompactGrid ? HPGrid.compactColumns : HPGrid.defaultColumns
        return Array(repeating: GridItem(.flexible(), spacing: HPGrid.photoGutter), count: count)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SearchScopeBar(
                    selection: Binding(
                        get: { scope },
                        set: { newScope in
                            setScope(newScope)
                            debouncedSearch()
                        }
                    ),
                    namespaceID: scopeNamespace
                )

                Divider().opacity(0.3)

                // Scope-switched body
                Group {
                    switch scope {
                    case .all:     allBody
                    case .people:  peopleBody
                    case .places:  placesBody
                    case .cameras: camerasBody
                    case .dates:   datesBody
                    }
                }
                .animation(HPMotion.smooth, value: scopeRaw)
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: searchPrompt)
            .onSubmit(of: .search) {
                resultLimit = 100
                Task { await runScopedSearch() }
            }
            .onChange(of: query) { _, _ in debouncedSearch() }
            .onChange(of: filter.curationStates) { _, _ in debouncedSearch() }
            .onChange(of: filter.grayscaleOnly) { _, _ in debouncedSearch() }
            .onChange(of: filter.yearRange) { _, _ in debouncedSearch() }
            .onChange(of: sortNewestFirst) { _, _ in debouncedSearch() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: HPSpacing.md) {
                        Button {
                            showFilterSheet = true
                        } label: {
                            Image(systemName: filter.isActive
                                ? "line.3.horizontal.decrease.circle.fill"
                                : "line.3.horizontal.decrease.circle")
                        }
                        .accessibilityLabel(filter.isActive ? "Filters active" : "Filters")

                        if scope == .all || scope == .places {
                            Button {
                                withAnimation(HPAnimation.cardSpring) {
                                    useCompactGrid.toggle()
                                }
                            } label: {
                                Image(systemName: useCompactGrid
                                    ? "square.grid.3x3"
                                    : "square.grid.4x3.fill")
                            }
                            .accessibilityLabel(useCompactGrid ? "Standard grid" : "Compact grid")
                        }
                    }
                }
            }
            .sheet(isPresented: $showFilterSheet) {
                SearchFilterSheet(filter: $filter)
            }
            .sheet(isPresented: Binding(
                get: { selectedPhotoIndex != nil },
                set: { if !$0 { selectedPhotoIndex = nil } }
            )) {
                MobilePhotoDetailView(
                    photos: currentGridResults,
                    initialIndex: selectedPhotoIndex ?? 0,
                    heroNamespace: heroNamespace
                )
                .environmentObject(syncService)
            }
            .hapticToast($toast)
            .task(id: scopeRaw) {
                await runScopedSearch()
            }
        }
    }

    private var searchPrompt: String {
        switch scope {
        case .all:     return "Photos, places, cameras..."
        case .people:  return "Search named people"
        case .places:  return "Search places or EXIF"
        case .cameras: return "Search camera make/model"
        case .dates:   return "Year, month, or \"last week\""
        }
    }

    // MARK: - ALL scope

    @ViewBuilder
    private var allBody: some View {
        if allResults.isEmpty && !isSearching && query.isEmpty && !filter.isActive {
            VStack(spacing: 0) {
                recentChips
                Spacer()
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "Search your library",
                    message: "Search by name, location, camera, or date.\nUse filters to narrow by curation state, year, or color."
                )
                Spacer()
            }
        } else if allResults.isEmpty && isSearching {
            shimmerGrid
        } else if allResults.isEmpty {
            noResultsEmptyState
        } else {
            VStack(spacing: 0) {
                activeFilterChips
                resultHeader(count: allResults.count)
                searchGrid(photos: allResults)
            }
        }
    }

    // MARK: - PEOPLE scope

    @ViewBuilder
    private var peopleBody: some View {
        if peopleMatches.isEmpty && isSearching {
            SkeletonPeopleGrid(count: 6)
        } else if peopleMatches.isEmpty {
            EmptyStateView(
                icon: "person.2",
                title: "No people match",
                message: query.isEmpty
                    ? "Run face indexing on your Mac to identify people."
                    : "No named people match \"\(query)\"."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: HPSpacing.md),
                              GridItem(.flexible(), spacing: HPSpacing.md)],
                    spacing: HPSpacing.md
                ) {
                    ForEach(peopleMatches) { person in
                        NavigationLink {
                            PersonResultsView(
                                personId: person.id,
                                personName: person.name
                            )
                            .environmentObject(syncService)
                        } label: {
                            VStack(spacing: HPSpacing.sm) {
                                FaceChip(
                                    image: peopleFaceCrops[person.id],
                                    name: person.name,
                                    size: .large
                                )
                                FilterPill(
                                    label: "\(person.faceCount) photo\(person.faceCount == 1 ? "" : "s")",
                                    systemImage: "photo.on.rectangle.angled",
                                    action: {}
                                )
                            }
                            .padding(.vertical, HPSpacing.sm)
                            .frame(maxWidth: .infinity)
                            .allowsHitTesting(false)  // Let the NavigationLink own taps
                        }
                        .buttonStyle(.plain)
                        .task { await loadFaceCrop(for: person) }
                    }
                }
                .padding(HPSpacing.md)
            }
        }
    }

    // MARK: - PLACES scope

    @ViewBuilder
    private var placesBody: some View {
        VStack(spacing: 0) {
            placesModeToggle
            Group {
                if placesResults.isEmpty && isSearching {
                    shimmerGrid
                } else if placesResults.isEmpty {
                    EmptyStateView(
                        icon: "mappin.slash",
                        title: "No geotagged photos",
                        message: query.isEmpty
                            ? "Photos with GPS coordinates will appear here."
                            : "No geotagged photos match \"\(query)\"."
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch placesMode {
                    case .grid:
                        VStack(spacing: 0) {
                            resultHeader(count: placesResults.count)
                            searchGrid(photos: placesResults)
                        }
                    case .map:
                        MapResultsView(photos: placesResults) { idx in
                            currentGridResults = placesResults
                            selectedPhotoIndex = idx
                        }
                    }
                }
            }
        }
    }

    private var placesModeToggle: some View {
        HStack(spacing: HPSpacing.sm) {
            ForEach(PlacesDisplayMode.allCases) { mode in
                FilterPill(
                    label: mode.label,
                    systemImage: mode.icon,
                    isActive: placesMode == mode
                ) {
                    withAnimation(HPMotion.smooth) { placesMode = mode }
                }
            }
            Spacer()
        }
        .padding(.horizontal, HPSpacing.base)
        .padding(.vertical, HPSpacing.sm)
    }

    // MARK: - CAMERAS scope

    @ViewBuilder
    private var camerasBody: some View {
        if cameraMatches.isEmpty && isSearching {
            VStack(spacing: HPSpacing.sm) {
                ForEach(0..<6, id: \.self) { _ in
                    SkeletonRow()
                }
            }
            .padding(.top, HPSpacing.sm)
        } else if cameraMatches.isEmpty {
            EmptyStateView(
                icon: "camera",
                title: "No cameras indexed",
                message: query.isEmpty
                    ? "Camera make/model will appear once EXIF is parsed."
                    : "No cameras match \"\(query)\"."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(cameraMatches) { cam in
                    NavigationLink {
                        CameraResultsView(model: cam.model, make: cam.make)
                            .environmentObject(syncService)
                    } label: {
                        HStack(spacing: HPSpacing.md) {
                            Image(systemName: "camera.fill")
                                .font(.title3)
                                .foregroundStyle(SearchScope.cameras.accent)
                                .frame(width: 36, height: 36)
                                .background(
                                    Circle().fill(SearchScope.cameras.accent.opacity(0.15))
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cam.model)
                                    .font(HPFont.cardTitle)
                                if let make = cam.make, !make.isEmpty,
                                   !cam.model.lowercased().contains(make.lowercased()) {
                                    Text(make)
                                        .font(HPFont.cardSubtitle)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text("\(cam.photoCount)")
                                .font(HPFont.metaValue.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, HPSpacing.sm)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(HPColor.chipInactive))
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - DATES scope

    @ViewBuilder
    private var datesBody: some View {
        if dateBuckets.isEmpty && isSearching {
            VStack(spacing: HPSpacing.sm) {
                ForEach(0..<6, id: \.self) { _ in SkeletonRow() }
            }
            .padding(.top, HPSpacing.sm)
        } else if dateBuckets.isEmpty {
            EmptyStateView(
                icon: "calendar",
                title: "No dates match",
                message: query.isEmpty
                    ? "Photos will be grouped by month here."
                    : "Try \"2024\", \"summer 2023\", \"last week\", or \"april\"."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(datesGroupedByYear, id: \.year) { yearGroup in
                    Section(header: Text(String(yearGroup.year)).font(HPFont.sectionHeader)) {
                        ForEach(yearGroup.buckets) { bucket in
                            NavigationLink {
                                DateBucketResultsView(bucket: bucket)
                                    .environmentObject(syncService)
                            } label: {
                                HStack(spacing: HPSpacing.md) {
                                    Image(systemName: "calendar")
                                        .font(.title3)
                                        .foregroundStyle(SearchScope.dates.accent)
                                        .frame(width: 36, height: 36)
                                        .background(
                                            Circle().fill(SearchScope.dates.accent.opacity(0.15))
                                        )
                                    Text(monthName(bucket.month))
                                        .font(HPFont.cardTitle)
                                    Spacer()
                                    Text("\(bucket.photoCount)")
                                        .font(HPFont.metaValue.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, HPSpacing.sm)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(HPColor.chipInactive))
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private struct YearGroup { let year: Int; let buckets: [MobilePhotoRepository.DateBucket] }

    private var datesGroupedByYear: [YearGroup] {
        let grouped = Dictionary(grouping: dateBuckets) { $0.year }
        return grouped
            .map { YearGroup(year: $0.key, buckets: $0.value.sorted { $0.month > $1.month }) }
            .sorted { $0.year > $1.year }
    }

    private func monthName(_ m: Int) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        return df.monthSymbols[max(0, min(11, m - 1))]
    }

    // MARK: - Recent Chips

    private var recentChips: some View {
        Group {
            if !recentSearches.isEmpty {
                VStack(alignment: .leading, spacing: HPSpacing.sm) {
                    HStack {
                        Text("Recent")
                            .font(HPFont.metaValue)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") {
                            withAnimation(HPAnimation.fadeIn) {
                                clearRecentSearches()
                            }
                        }
                        .font(HPFont.metaLabel)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, HPSpacing.base)

                    FilterChipBar(
                        chips: recentSearches.map { FilterChip(id: $0, label: $0, icon: "clock") },
                        selectedId: nil,
                        onSelect: { id in
                            if let id {
                                query = id
                                Task { await runScopedSearch() }
                            }
                        }
                    )
                }
                .padding(.top, HPSpacing.sm)
            }
        }
    }

    // MARK: - Active Filter Chips

    @ViewBuilder
    private func singleCurationChip(_ state: CurationState) -> some View {
        chipView(
            label: state.title,
            icon: state.systemIcon,
            tint: state.tint
        ) {
            withAnimation(HPAnimation.chipSpring) {
                _ = filter.curationStates.remove(state)
            }
        }
    }

    @ViewBuilder
    private func curationStateChips(_ states: [CurationState]) -> some View {
        ForEach(states, id: \.rawValue) { state in
            singleCurationChip(state)
        }
    }

    @ViewBuilder
    private var activeFilterChips: some View {
        if filter.isActive {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HPSpacing.sm) {
                    curationStateChips(Array(filter.curationStates))
                    if filter.grayscaleOnly {
                        chipView(
                            label: "B&W",
                            icon: "circle.lefthalf.filled",
                            tint: .secondary
                        ) {
                            withAnimation(HPAnimation.chipSpring) {
                                filter.grayscaleOnly = false
                            }
                        }
                    }
                    if let yr = filter.yearRange {
                        chipView(
                            label: yr.lowerBound == yr.upperBound
                                ? "\(yr.lowerBound)"
                                : "\(yr.lowerBound)-\(yr.upperBound)",
                            icon: "calendar",
                            tint: .purple
                        ) {
                            withAnimation(HPAnimation.chipSpring) {
                                filter.yearRange = nil
                            }
                        }
                    }
                }
                .padding(.horizontal, HPSpacing.base)
            }
            .padding(.vertical, HPSpacing.xs)
        }
    }

    private func chipView(label: String, icon: String, tint: Color, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: HPSpacing.xs) {
            Image(systemName: icon)
                .font(HPFont.metaLabel)
            Text(label)
                .font(HPFont.chipLabel)
            Button { onRemove() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(HPFont.metaLabel)
            }
        }
        .padding(.horizontal, HPSpacing.md)
        .padding(.vertical, 10)
        .background(Capsule().fill(tint.opacity(0.2)))
        .foregroundStyle(tint)
    }

    // MARK: - Result Header

    @ViewBuilder
    private func resultHeader(count: Int) -> some View {
        if count > 0 {
            HStack {
                Text("\(count) result\(count == 1 ? "" : "s")")
                    .font(HPFont.metaValue)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    sortNewestFirst.toggle()
                } label: {
                    HStack(spacing: HPSpacing.xxs + 1) {
                        Image(systemName: sortNewestFirst ? "arrow.down" : "arrow.up")
                        Text(sortNewestFirst ? "Newest" : "Oldest")
                    }
                    .font(HPFont.metaValue)
                    .foregroundStyle(.secondary)
                }
                .accessibilityLabel(sortNewestFirst ? "Sort newest first" : "Sort oldest first")
            }
            .padding(.horizontal, HPSpacing.base)
            .padding(.vertical, HPSpacing.xs)
        }
    }

    // MARK: - Empty / Shimmer

    private var shimmerGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: HPGrid.photoGutter) {
                ForEach(0..<12, id: \.self) { _ in
                    ShimmerPlaceholder()
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            .padding(.top, HPSpacing.sm)
        }
    }

    private var noResultsEmptyState: some View {
        VStack(spacing: HPSpacing.base) {
            Image(systemName: "photo.slash")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            if !query.isEmpty {
                Text("No results for \"\(query)\"")
                    .font(HPFont.sectionHeader)
            } else {
                Text("No matching photos")
                    .font(HPFont.sectionHeader)
            }
            if filter.isActive {
                Text("Try removing some filters")
                    .font(HPFont.body)
                    .foregroundStyle(.secondary)
                Button("Clear Filters") {
                    filter = MobileSearchFilter()
                }
                .font(HPFont.body)
                .buttonStyle(.bordered)
            } else {
                Text("Try searching for camera names, locations, or dates")
                    .font(HPFont.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, HPSpacing.xxxl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    // MARK: - Shared grid

    private func searchGrid(photos: [PhotoAsset]) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: HPGrid.photoGutter) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                    MobilePhotoCell(photo: photo)
                        .aspectRatio(1, contentMode: .fill)
                        .onTapGesture {
                            HPHaptic.light()
                            currentGridResults = photos
                            selectedPhotoIndex = index
                        }
                        .photoContextMenu(photo: photo, onCurate: { state in
                            Task {
                                guard let db = appDatabase else { return }
                                await applyCuration(photo: photo, state: state, db: db, syncService: syncService)
                                await runScopedSearch()
                            }
                        }, onViewDetails: {
                            currentGridResults = photos
                            selectedPhotoIndex = index
                        })
                }
            }
            .animation(HPAnimation.cardSpring, value: useCompactGrid)

            if photos.count >= resultLimit {
                Button("Load more results") {
                    resultLimit += 100
                    Task { await runScopedSearch() }
                }
                .font(HPFont.body)
                .foregroundStyle(Color.accentColor)
                .padding(HPSpacing.base)
            }
        }
    }

    // MARK: - Search dispatch

    private func runScopedSearch() async {
        guard let db = appDatabase else { return }
        isSearching = true
        defer { isSearching = false }

        let repo = MobilePhotoRepository(db: db)
        do {
            switch scope {
            case .all:
                allResults = try await repo.search(
                    query: query,
                    curationStates: filter.curationStates,
                    grayscaleOnly: filter.grayscaleOnly,
                    yearRange: filter.yearRange,
                    sortNewestFirst: sortNewestFirst,
                    limit: resultLimit
                )
                if !query.isEmpty { addRecentSearch(query) }

            case .people:
                peopleMatches = try await repo.searchPeopleGrouped(query: query, limit: resultLimit)
                if !query.isEmpty { addRecentSearch(query) }

            case .places:
                placesResults = try await repo.searchPlaces(query: query, limit: max(resultLimit, 500))
                if !query.isEmpty { addRecentSearch(query) }

            case .cameras:
                cameraMatches = try await repo.searchCameras(query: query)
                if !query.isEmpty { addRecentSearch(query) }

            case .dates:
                // Try natural-language parse first; fall back to all buckets
                if let range = DateQueryParser.range(for: query) {
                    dateBuckets = try await repo.dateBuckets(
                        startISO: range.startISO,
                        endISO: range.endISO,
                        limit: 240
                    )
                } else {
                    dateBuckets = try await repo.dateBuckets(limit: 240)
                }
                if !query.isEmpty { addRecentSearch(query) }
            }
        } catch {
            toast = ToastMessage(.error, "Search failed", subtitle: error.localizedDescription)
        }
    }

    // MARK: - Face crops for People scope

    private func loadFaceCrop(for person: MobilePhotoRepository.PersonMatch) async {
        guard let db = appDatabase,
              peopleFaceCrops[person.id] == nil else { return }
        do {
            let face = try await MobilePeopleRepository(db: db).fetchFaceForPerson(personId: person.id)
            guard let face else { return }
            guard let photoAsset = try? await MobilePhotoRepository(db: db).fetchById(face.photoId) else { return }
            let baseName = (photoAsset.canonicalName as NSString).deletingPathExtension
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let proxyURL = appSupport
                .appendingPathComponent("HoehnPhotos")
                .appendingPathComponent("proxies")
                .appendingPathComponent(baseName + ".jpg")
            let crop = await FaceCropCache.shared.crop(
                id: face.id,
                proxyURL: proxyURL,
                bbox: face.bboxRect
            )
            if let crop { peopleFaceCrops[person.id] = crop }
        } catch {
            // Non-fatal: thumbnail just won't render.
        }
    }
}

// MARK: - PersonResultsView

/// Grid of photos for one named person, reached from the People scope.
private struct PersonResultsView: View {
    let personId: String
    let personName: String

    @Environment(\.appDatabase) private var appDatabase
    @EnvironmentObject private var syncService: PeerSyncService
    @State private var photos: [PhotoAsset] = []
    @State private var isLoading = true
    @State private var selectedPhotoIndex: Int?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: HPGrid.photoGutter), count: HPGrid.defaultColumns)

    var body: some View {
        Group {
            if isLoading {
                SkeletonPhotoGrid(rows: 4, columns: 3)
            } else if photos.isEmpty {
                EmptyStateView(
                    icon: "person.crop.square.badge.camera",
                    title: "No photos",
                    message: "No photos of \(personName) found."
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: HPGrid.photoGutter) {
                        ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                            MobilePhotoCell(photo: photo)
                                .aspectRatio(1, contentMode: .fill)
                                .onTapGesture { selectedPhotoIndex = index }
                                .photoContextMenu(photo: photo, onCurate: { state in
                                    Task {
                                        guard let db = appDatabase else { return }
                                        await applyCuration(photo: photo, state: state, db: db, syncService: syncService)
                                        await load()
                                    }
                                }, onViewDetails: { selectedPhotoIndex = index })
                        }
                    }
                }
            }
        }
        .navigationTitle(personName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: Binding(
            get: { selectedPhotoIndex != nil },
            set: { if !$0 { selectedPhotoIndex = nil } }
        )) {
            if let idx = selectedPhotoIndex {
                MobilePhotoDetailView(photos: photos, initialIndex: idx)
                    .environmentObject(syncService)
            }
        }
    }

    private func load() async {
        guard let db = appDatabase else { isLoading = false; return }
        photos = (try? await MobilePeopleRepository(db: db).fetchPhotosForPerson(personId: personId)) ?? []
        isLoading = false
    }
}

// MARK: - CameraResultsView

private struct CameraResultsView: View {
    let model: String
    let make: String?

    @Environment(\.appDatabase) private var appDatabase
    @EnvironmentObject private var syncService: PeerSyncService
    @State private var photos: [PhotoAsset] = []
    @State private var isLoading = true
    @State private var selectedPhotoIndex: Int?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: HPGrid.photoGutter), count: HPGrid.defaultColumns)

    var body: some View {
        Group {
            if isLoading {
                SkeletonPhotoGrid(rows: 4, columns: 3)
            } else if photos.isEmpty {
                EmptyStateView(icon: "camera", title: "No photos", message: "No photos from \(model).")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: HPGrid.photoGutter) {
                        ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                            MobilePhotoCell(photo: photo)
                                .aspectRatio(1, contentMode: .fill)
                                .onTapGesture { selectedPhotoIndex = index }
                                .photoContextMenu(photo: photo, onCurate: { state in
                                    Task {
                                        guard let db = appDatabase else { return }
                                        await applyCuration(photo: photo, state: state, db: db, syncService: syncService)
                                        await load()
                                    }
                                }, onViewDetails: { selectedPhotoIndex = index })
                        }
                    }
                }
            }
        }
        .navigationTitle(model)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: Binding(
            get: { selectedPhotoIndex != nil },
            set: { if !$0 { selectedPhotoIndex = nil } }
        )) {
            if let idx = selectedPhotoIndex {
                MobilePhotoDetailView(photos: photos, initialIndex: idx)
                    .environmentObject(syncService)
            }
        }
    }

    private func load() async {
        guard let db = appDatabase else { isLoading = false; return }
        photos = (try? await MobilePhotoRepository(db: db).photosForCameraModel(model)) ?? []
        isLoading = false
    }
}

// MARK: - DateBucketResultsView

private struct DateBucketResultsView: View {
    let bucket: MobilePhotoRepository.DateBucket

    @Environment(\.appDatabase) private var appDatabase
    @EnvironmentObject private var syncService: PeerSyncService
    @State private var photos: [PhotoAsset] = []
    @State private var isLoading = true
    @State private var selectedPhotoIndex: Int?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: HPGrid.photoGutter), count: HPGrid.defaultColumns)

    private var title: String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        let months = df.monthSymbols ?? []
        let idx = max(0, min(months.count - 1, bucket.month - 1))
        let monthName = months.indices.contains(idx) ? months[idx] : "\(bucket.month)"
        return "\(monthName) \(bucket.year)"
    }

    var body: some View {
        Group {
            if isLoading {
                SkeletonPhotoGrid(rows: 4, columns: 3)
            } else if photos.isEmpty {
                EmptyStateView(icon: "calendar", title: "No photos", message: "No photos for \(title).")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: HPGrid.photoGutter) {
                        ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                            MobilePhotoCell(photo: photo)
                                .aspectRatio(1, contentMode: .fill)
                                .onTapGesture { selectedPhotoIndex = index }
                                .photoContextMenu(photo: photo, onCurate: { state in
                                    Task {
                                        guard let db = appDatabase else { return }
                                        await applyCuration(photo: photo, state: state, db: db, syncService: syncService)
                                        await load()
                                    }
                                }, onViewDetails: { selectedPhotoIndex = index })
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: Binding(
            get: { selectedPhotoIndex != nil },
            set: { if !$0 { selectedPhotoIndex = nil } }
        )) {
            if let idx = selectedPhotoIndex {
                MobilePhotoDetailView(photos: photos, initialIndex: idx)
                    .environmentObject(syncService)
            }
        }
    }

    private func load() async {
        guard let db = appDatabase else { isLoading = false; return }
        // Build first-of-month and last-of-month ISO strings for the bucket.
        var comps = DateComponents()
        comps.year = bucket.year
        comps.month = bucket.month
        comps.day = 1
        let cal = Calendar(identifier: .gregorian)
        guard let start = cal.date(from: comps) else { isLoading = false; return }
        guard let rangeEnd = cal.date(byAdding: DateComponents(month: 1, second: -1), to: start) else {
            isLoading = false; return
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let startStr = iso.string(from: start)
        let endStr = iso.string(from: rangeEnd)

        photos = (try? await MobilePhotoRepository(db: db).searchDates(startISO: startStr, endISO: endStr, limit: 500)) ?? []
        isLoading = false
    }
}

// MARK: - DateQueryParser

/// Lightweight natural-date parser for the Dates scope.
/// Recognizes: explicit 4-digit years, month names ("april"), "last week",
/// season + year ("summer 2023"), and year ranges ("2020-2024").
enum DateQueryParser {
    struct Range { let startISO: String; let endISO: String }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func range(for rawQuery: String) -> Range? {
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        let cal = Calendar(identifier: .gregorian)
        let now = Date()

        // "last week"
        if q.contains("last week") {
            guard let end = cal.date(byAdding: .day, value: 0, to: now),
                  let start = cal.date(byAdding: .day, value: -7, to: end)
            else { return nil }
            return iso(start, end)
        }
        // "this week"
        if q.contains("this week") {
            let interval = cal.dateInterval(of: .weekOfYear, for: now)
            if let i = interval {
                return iso(i.start, i.end.addingTimeInterval(-1))
            }
        }
        // "last month"
        if q.contains("last month") {
            guard let cur = cal.dateInterval(of: .month, for: now),
                  let prev = cal.date(byAdding: .month, value: -1, to: cur.start),
                  let prevInt = cal.dateInterval(of: .month, for: prev)
            else { return nil }
            return iso(prevInt.start, prevInt.end.addingTimeInterval(-1))
        }
        // "this year" / "last year"
        if q.contains("this year") {
            if let yr = cal.dateInterval(of: .year, for: now) {
                return iso(yr.start, yr.end.addingTimeInterval(-1))
            }
        }
        if q.contains("last year") {
            guard let cur = cal.dateInterval(of: .year, for: now),
                  let prev = cal.date(byAdding: .year, value: -1, to: cur.start),
                  let prevInt = cal.dateInterval(of: .year, for: prev)
            else { return nil }
            return iso(prevInt.start, prevInt.end.addingTimeInterval(-1))
        }

        // Season + year: "summer 2023", "winter 2021"
        let seasons: [(String, ClosedRange<Int>)] = [
            ("winter", 1...2), ("spring", 3...5), ("summer", 6...8), ("fall", 9...11),
            ("autumn", 9...11)
        ]
        for (name, months) in seasons {
            if q.contains(name), let y = firstYear(in: q) {
                return monthRange(year: y, months: months)
            }
        }

        // Year range: "2020-2024" or "2020 to 2024"
        if let match = q.range(of: #"(\d{4})\s*(?:-|to)\s*(\d{4})"#, options: .regularExpression) {
            let sub = String(q[match])
            let nums = sub.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if nums.count == 2 {
                let y1 = min(nums[0], nums[1])
                let y2 = max(nums[0], nums[1])
                return monthRange(year: y1, firstMonth: 1, endYear: y2, lastMonth: 12)
            }
        }

        // Month + year: "april 2024"
        if let month = monthIndex(in: q), let y = firstYear(in: q) {
            return monthRange(year: y, months: month...month)
        }

        // Just a month: current year
        if let month = monthIndex(in: q) {
            let y = cal.component(.year, from: now)
            return monthRange(year: y, months: month...month)
        }

        // Just a year
        if let y = firstYear(in: q), firstYear(in: q.replacingOccurrences(of: "\(y)", with: "")) == nil {
            return monthRange(year: y, months: 1...12)
        }

        return nil
    }

    private static func iso(_ start: Date, _ end: Date) -> Range {
        Range(startISO: isoFormatter.string(from: start), endISO: isoFormatter.string(from: end))
    }

    private static func firstYear(in s: String) -> Int? {
        guard let m = s.range(of: #"(19|20)\d{2}"#, options: .regularExpression) else { return nil }
        return Int(s[m])
    }

    private static let monthNames: [String] = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december"
    ]
    private static let monthAbbr: [String] = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"
    ]

    private static func monthIndex(in s: String) -> Int? {
        for (i, name) in monthNames.enumerated() { if s.contains(name) { return i + 1 } }
        for (i, name) in monthAbbr.enumerated() { if s.contains(" " + name) || s.hasPrefix(name) { return i + 1 } }
        return nil
    }

    private static func monthRange(year: Int, months: ClosedRange<Int>) -> Range? {
        monthRange(year: year, firstMonth: months.lowerBound, endYear: year, lastMonth: months.upperBound)
    }

    private static func monthRange(year: Int, firstMonth: Int, endYear: Int, lastMonth: Int) -> Range? {
        let cal = Calendar(identifier: .gregorian)
        var s = DateComponents(); s.year = year; s.month = firstMonth; s.day = 1
        var e = DateComponents(); e.year = endYear; e.month = lastMonth; e.day = 1
        guard let start = cal.date(from: s),
              let firstOfLast = cal.date(from: e),
              let end = cal.date(byAdding: DateComponents(month: 1, second: -1), to: firstOfLast)
        else { return nil }
        return iso(start, end)
    }
}

// MARK: - SearchFilterSheet

private struct SearchFilterSheet: View {
    @Binding var filter: MobileSearchFilter
    @Environment(\.dismiss) private var dismiss

    private static let yearMin: Double = 1990
    private static let yearMax: Double = 2030
    @State private var yearLow: Double = 1990
    @State private var yearHigh: Double = 2030

    var body: some View {
        NavigationStack {
            List {
                Section("Curation State") {
                    ForEach(CurationState.allCases) { state in
                        Button {
                            if filter.curationStates.contains(state) {
                                filter.curationStates.remove(state)
                            } else {
                                filter.curationStates.insert(state)
                            }
                        } label: {
                            HStack {
                                Image(systemName: state.systemIcon)
                                    .foregroundStyle(state.tint)
                                Text(state.title)
                                Spacer()
                                if filter.curationStates.contains(state) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                }

                Section("Year Range") {
                    Toggle("Filter by year", isOn: Binding(
                        get: { filter.yearRange != nil },
                        set: { enabled in
                            filter.yearRange = enabled
                                ? Int(yearLow)...Int(yearHigh)
                                : nil
                        }
                    ))
                    if filter.yearRange != nil {
                        VStack(spacing: HPSpacing.md) {
                            HStack {
                                Text("\(Int(yearLow))")
                                    .monospacedDigit()
                                Spacer()
                                Text("\(Int(yearHigh))")
                                    .monospacedDigit()
                            }
                            .font(HPFont.metaValue)
                            .foregroundStyle(.secondary)
                            Slider(value: $yearLow, in: Self.yearMin...Self.yearMax, step: 1) {
                                Text("From")
                            }
                            .onChange(of: yearLow) { _, newVal in
                                if newVal > yearHigh { yearHigh = newVal }
                                filter.yearRange = Int(yearLow)...Int(yearHigh)
                            }
                            Slider(value: $yearHigh, in: Self.yearMin...Self.yearMax, step: 1) {
                                Text("To")
                            }
                            .onChange(of: yearHigh) { _, newVal in
                                if newVal < yearLow { yearLow = newVal }
                                filter.yearRange = Int(yearLow)...Int(yearHigh)
                            }
                        }
                    }
                }

                Section("Appearance") {
                    Toggle("Grayscale only", isOn: $filter.grayscaleOnly)
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if filter.isActive {
                        Button("Clear All") { filter = MobileSearchFilter() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}
