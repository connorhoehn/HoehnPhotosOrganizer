import SwiftUI
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

// MARK: - MobileSearchView

struct MobileSearchView: View {

    @Environment(\.appDatabase) private var appDatabase
    @EnvironmentObject private var syncService: PeerSyncService
    @State private var query = ""
    @State private var results: [PhotoAsset] = []
    @State private var isSearching = false
    @State private var selectedPhotoIndex: Int?
    @State private var resultLimit: Int = 100

    @State private var filter = MobileSearchFilter()
    @State private var showFilterSheet = false
    @State private var sortNewestFirst = true
    @State private var searchDebounceTask: Task<Void, Never>?
    @AppStorage("searchCompactGrid") private var useCompactGrid = false

    @AppStorage("recentSearches") private var recentSearchesJSON: String = "[]"

    private var recentSearches: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(recentSearchesJSON.utf8))) ?? []
    }

    private func addRecentSearch(_ q: String) {
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
            await search()
        }
    }

    private var columns: [GridItem] {
        let count = useCompactGrid ? HPGrid.compactColumns : HPGrid.defaultColumns
        return Array(repeating: GridItem(.flexible(), spacing: HPGrid.photoGutter), count: count)
    }

    var body: some View {
        NavigationStack {
            Group {
                if results.isEmpty && !isSearching && query.isEmpty && !filter.isActive {
                    VStack(spacing: 0) {
                        recentChips
                        Spacer()
                        noQueryEmptyState
                        Spacer()
                    }
                } else if results.isEmpty && isSearching {
                    SkeletonPhotoGrid(rows: 4, columns: 3)
                        .padding(.top, HPSpacing.sm)
                } else if results.isEmpty && !isSearching {
                    noResultsEmptyState
                } else {
                    VStack(spacing: 0) {
                        activeFilterChips
                        resultHeader
                        searchGrid
                    }
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Photos, places, cameras...")
            .onSubmit(of: .search) {
                resultLimit = 100
                Task { await search() }
            }
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
            .sheet(isPresented: $showFilterSheet) {
                SearchFilterSheet(filter: $filter)
            }
            .sheet(isPresented: Binding(
                get: { selectedPhotoIndex != nil },
                set: { if !$0 { selectedPhotoIndex = nil } }
            )) {
                MobilePhotoDetailView(photos: results, initialIndex: selectedPhotoIndex ?? 0)
            }
        }
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
                                Task { await search() }
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
    private var activeFilterChips: some View {
        if filter.isActive {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HPSpacing.sm) {
                    ForEach(Array(filter.curationStates), id: \.self) { state in
                        chipView(
                            label: state.title,
                            icon: state.systemIcon,
                            tint: state.tint
                        ) {
                            withAnimation(HPAnimation.chipSpring) {
                                filter.curationStates.remove(state)
                            }
                        }
                    }
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
    private var resultHeader: some View {
        if !results.isEmpty {
            HStack {
                Text("\(results.count) result\(results.count == 1 ? "" : "s")")
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

    // MARK: - Empty States

    private var noQueryEmptyState: some View {
        EmptyStateView(
            icon: "magnifyingglass",
            title: "Search your library",
            message: "Search by name, location, camera, or date.\nUse filters to narrow by curation state, year, or color."
        )
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
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    // MARK: - Search Grid

    private var searchGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: HPGrid.photoGutter) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, photo in
                    MobilePhotoCell(photo: photo)
                        .aspectRatio(1, contentMode: .fill)
                        .onTapGesture {
                            HPHaptic.light()
                            selectedPhotoIndex = index
                        }
                        .photoContextMenu(photo: photo, onCurate: { state in
                            Task {
                                guard let db = appDatabase else { return }
                                await applyCuration(photo: photo, state: state, db: db, syncService: syncService)
                                await search()
                            }
                        }, onViewDetails: {
                            selectedPhotoIndex = index
                        })
                }
            }
            .animation(HPAnimation.cardSpring, value: useCompactGrid)

            if results.count >= resultLimit {
                Button("Load more results") {
                    resultLimit += 100
                    Task { await search() }
                }
                .font(HPFont.body)
                .foregroundStyle(.accentColor)
                .padding(HPSpacing.base)
            }
        }
    }

    // MARK: - Search

    private func search() async {
        guard let db = appDatabase else { return }
        guard !query.isEmpty || filter.isActive else {
            results = []
            return
        }
        isSearching = true
        results = (try? await MobilePhotoRepository(db: db).search(
            query: query,
            curationStates: filter.curationStates,
            grayscaleOnly: filter.grayscaleOnly,
            yearRange: filter.yearRange,
            sortNewestFirst: sortNewestFirst,
            limit: resultLimit
        )) ?? []
        if !query.isEmpty { addRecentSearch(query) }
        isSearching = false
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
