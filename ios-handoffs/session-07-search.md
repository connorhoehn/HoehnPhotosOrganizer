# Session 7 -- Search Upgrade

## Goal
Add filtering, sorting, grid density, and improved empty states to the iOS search experience. The Mac app's `SearchExperienceView.swift` has a mature `MetadataFilter` + `MetadataFilterSheet` pattern to draw from.

---

## Current State

### MobileSearchView.swift
**Path:** `HoehnPhotosMobile/Features/Search/MobileSearchView.swift`

The view is simple: a `@State var query`, `@State var results: [PhotoAsset]`, a 3-column `LazyVGrid`, and two empty states. Key points:

- Columns are a **hardcoded `let`** -- not stateful, so grid density can't toggle today:
  ```swift
  private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
  ```
- No filter state at all -- no curation, year, or grayscale awareness.
- Result count is only shown in the nav title: `.navigationTitle("Search (\(results.count))")`.
- Search calls `MobilePhotoRepository.search(query:limit:)` which is pure LIKE matching on three text columns.

### MobilePhotoRepository.search()
**Path:** `HoehnPhotosCore/Database/Repository/MobileRepositories.swift` (line 72)

```swift
public func search(query: String, limit: Int = 100) async throws -> [PhotoAsset] {
    let pattern = "%\(query)%"
    return try await db.dbPool.read { conn in
        try PhotoAsset.fetchAll(conn, sql: """
            SELECT * FROM photo_assets
            WHERE canonical_name LIKE ?
               OR raw_exif_json LIKE ?
               OR user_metadata_json LIKE ?
            ORDER BY created_at DESC
            LIMIT ?
        """, arguments: [pattern, pattern, pattern, limit])
    }
}
```

**This method has no filter parameters.** It needs extension for curation state, year range, and grayscale.

### PhotoAsset columns available for filtering
From `HoehnPhotosCore/Models/PhotoAsset.swift`:
- `curationState: String` (column: `curation_state`) -- stores `CurationState.rawValue`
- `isGrayscale: Bool?` (column: `is_grayscale`)
- `dateModified: String?` (column: `date_modified`) -- ISO 8601 timestamp, extract year via `substr` or `strftime`

### CurationState enum (SharedEnums.swift)
```swift
public enum CurationState: String, CaseIterable, Identifiable {
    case keeper, archive, needsReview = "needs_review", rejected, deleted

    public var title: String { ... }    // "Keeper", "Archive", "Needs Review", "Rejected", "Deleted"
    public var tint: Color { ... }      // .green, .blue, .orange, .red, .gray
    public var systemIcon: String { ... } // "star.fill", "archivebox.fill", etc.
}
```

### Mac MetadataFilter reference (SearchExperienceView.swift, line 6)
```swift
struct MetadataFilter {
    var curationStates: Set<CurationState> = []
    var sceneTypes: Set<String> = []
    var peopleOnly: Bool = false
    var grayscaleOnly: Bool = false
    var yearRange: ClosedRange<Int>? = nil

    var isActive: Bool {
        !curationStates.isEmpty || !sceneTypes.isEmpty || peopleOnly || grayscaleOnly || yearRange != nil
    }

    func matches(_ photo: PhotoAsset) -> Bool { ... }
}
```

---

## Implementation Plan

### 1. Add `MobileSearchFilter` struct

Create this in `MobileSearchView.swift` (or a new file in `HoehnPhotosMobile/Features/Search/`). Keep it simple -- no sceneTypes or peopleOnly for now.

```swift
struct MobileSearchFilter {
    var curationStates: Set<CurationState> = []
    var grayscaleOnly: Bool = false
    var yearRange: ClosedRange<Int>? = nil

    var isActive: Bool {
        !curationStates.isEmpty || grayscaleOnly || yearRange != nil
    }
}
```

### 2. Extend MobilePhotoRepository.search()

Add optional filter parameters. Use SQL-level filtering so we don't fetch everything and filter in memory.

```swift
public func search(
    query: String,
    curationStates: Set<CurationState> = [],
    grayscaleOnly: Bool = false,
    yearRange: ClosedRange<Int>? = nil,
    sortNewestFirst: Bool = true,
    limit: Int = 200
) async throws -> [PhotoAsset] {
    let pattern = "%\(query)%"
    return try await db.dbPool.read { conn in
        var sql = """
            SELECT * FROM photo_assets
            WHERE (canonical_name LIKE ?
                   OR raw_exif_json LIKE ?
                   OR user_metadata_json LIKE ?)
        """
        var args: [DatabaseValueConvertible] = [pattern, pattern, pattern]

        // Curation filter
        if !curationStates.isEmpty {
            let placeholders = curationStates.map { _ in "?" }.joined(separator: ", ")
            sql += " AND curation_state IN (\(placeholders))"
            args.append(contentsOf: curationStates.map { $0.rawValue })
        }

        // Grayscale filter
        if grayscaleOnly {
            sql += " AND is_grayscale = 1"
        }

        // Year range filter (extract year from ISO 8601 date_modified)
        if let range = yearRange {
            sql += " AND CAST(substr(date_modified, 1, 4) AS INTEGER) >= ?"
            sql += " AND CAST(substr(date_modified, 1, 4) AS INTEGER) <= ?"
            args.append(range.lowerBound)
            args.append(range.upperBound)
        }

        // Sort
        sql += sortNewestFirst
            ? " ORDER BY created_at DESC"
            : " ORDER BY created_at ASC"
        sql += " LIMIT ?"
        args.append(limit)

        return try PhotoAsset.fetchAll(conn, sql: sql, arguments: StatementArguments(args))
    }
}
```

**Note:** The existing `search(query:limit:)` signature should remain for backward compatibility; add the new overload alongside it.

### 3. New state properties in MobileSearchView

Add these `@State` vars at the top of `MobileSearchView`:

```swift
@State private var filter = MobileSearchFilter()
@State private var showFilterSheet = false
@State private var sortNewestFirst = true
@State private var useCompactGrid = false  // false = 3-col, true = 4-col
```

Replace the hardcoded `columns` constant with a computed property:

```swift
private var columns: [GridItem] {
    let count = useCompactGrid ? 4 : 3
    return Array(repeating: GridItem(.flexible(), spacing: 2), count: count)
}
```

### 4. SearchFilterSheet

Present as `.sheet(isPresented: $showFilterSheet)`. Pattern follows the Mac `MetadataFilterSheet`.

```swift
private struct SearchFilterSheet: View {
    @Binding var filter: MobileSearchFilter
    @Environment(\.dismiss) private var dismiss

    // Year slider state -- initialize from filter or defaults
    @State private var yearLow: Double = 2000
    @State private var yearHigh: Double = 2026

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Curation State
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

                // MARK: - Year Range
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
                        VStack(spacing: 12) {
                            HStack {
                                Text("\(Int(yearLow))")
                                    .monospacedDigit()
                                Spacer()
                                Text("\(Int(yearHigh))")
                                    .monospacedDigit()
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            // Two sliders or a RangedSliderView
                            Slider(value: $yearLow, in: 2000...2026, step: 1) {
                                Text("From")
                            }
                            .onChange(of: yearLow) { _, newVal in
                                if newVal > yearHigh { yearHigh = newVal }
                                filter.yearRange = Int(yearLow)...Int(yearHigh)
                            }
                            Slider(value: $yearHigh, in: 2000...2026, step: 1) {
                                Text("To")
                            }
                            .onChange(of: yearHigh) { _, newVal in
                                if newVal < yearLow { yearLow = newVal }
                                filter.yearRange = Int(yearLow)...Int(yearHigh)
                            }
                        }
                    }
                }

                // MARK: - Grayscale
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
```

### 5. ActiveFilterChips bar

Horizontal scroll of dismissible capsule chips, placed between the search bar and results. Show only when `filter.isActive`.

```swift
@ViewBuilder
private var activeFilterChips: some View {
    if filter.isActive {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(filter.curationStates), id: \.self) { state in
                    chipView(
                        label: state.title,
                        icon: state.systemIcon,
                        tint: state.tint
                    ) {
                        filter.curationStates.remove(state)
                    }
                }
                if filter.grayscaleOnly {
                    chipView(
                        label: "Grayscale",
                        icon: "circle.lefthalf.filled",
                        tint: .secondary
                    ) {
                        filter.grayscaleOnly = false
                    }
                }
                if let yr = filter.yearRange {
                    chipView(
                        label: "\(yr.lowerBound)-\(yr.upperBound)",
                        icon: "calendar",
                        tint: .purple
                    ) {
                        filter.yearRange = nil
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 4)
    }
}

private func chipView(label: String, icon: String, tint: Color, onRemove: @escaping () -> Void) -> some View {
    HStack(spacing: 4) {
        Image(systemName: icon)
            .font(.caption2)
        Text(label)
            .font(.caption)
        Button { onRemove() } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.caption2)
        }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(Capsule().fill(tint.opacity(0.15)))
    .foregroundStyle(tint)
}
```

### 6. Result count header with sort toggle

Place above the grid, below filter chips.

```swift
@ViewBuilder
private var resultHeader: some View {
    if !results.isEmpty {
        HStack {
            Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                sortNewestFirst.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: sortNewestFirst ? "arrow.down" : "arrow.up")
                    Text(sortNewestFirst ? "Newest" : "Oldest")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}
```

### 7. Grid density toggle

A toolbar button that flips `useCompactGrid`:

```swift
.toolbar {
    ToolbarItem(placement: .topBarTrailing) {
        HStack(spacing: 12) {
            // Filter button
            Button {
                showFilterSheet = true
            } label: {
                Image(systemName: filter.isActive
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
            }

            // Grid density toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    useCompactGrid.toggle()
                }
            } label: {
                Image(systemName: useCompactGrid
                    ? "square.grid.3x3"
                    : "square.grid.4x3.fill")
            }
        }
    }
}
```

### 8. Updated body structure

The `body` should be restructured to incorporate the new elements:

```swift
var body: some View {
    NavigationStack {
        Group {
            if results.isEmpty && !isSearching && query.isEmpty {
                VStack(spacing: 0) {
                    recentChips
                    Spacer()
                    noQueryEmptyState
                    Spacer()
                }
            } else if results.isEmpty && isSearching {
                ProgressView("Searching...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty && !isSearching {
                noResultsEmptyState
            } else {
                VStack(spacing: 0) {
                    activeFilterChips      // <-- NEW
                    resultHeader           // <-- NEW
                    searchGrid
                }
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Photos, places, cameras...")
        .onSubmit(of: .search) {
            Task { await search() }
        }
        .onChange(of: filter.curationStates) { _, _ in Task { await search() } }
        .onChange(of: filter.grayscaleOnly) { _, _ in Task { await search() } }
        .onChange(of: filter.yearRange) { _, _ in Task { await search() } }
        .onChange(of: sortNewestFirst) { _, _ in Task { await search() } }
        .toolbar { /* filter + density buttons from section 7 */ }
        .sheet(isPresented: $showFilterSheet) {
            SearchFilterSheet(filter: $filter)
        }
        .sheet(isPresented: /* photo detail binding */) {
            MobilePhotoDetailView(photos: results, initialIndex: selectedPhotoIndex ?? 0)
        }
    }
}
```

### 9. Updated search() function

```swift
private func search() async {
    guard let db = appDatabase else { return }
    // Allow filter-only search (empty query with active filters)
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
        sortNewestFirst: sortNewestFirst
    )) ?? []
    if !query.isEmpty { addRecentSearch(query) }
    isSearching = false
}
```

### 10. Improved empty states

Replace the existing empty states with more helpful text:

**No-query empty state** (currently "Search your library"):
```swift
private var noQueryEmptyState: some View {
    VStack(spacing: 16) {
        Image(systemName: "magnifyingglass")
            .font(.system(size: 48))
            .foregroundStyle(.tertiary)
        Text("Search your library")
            .font(.title3.weight(.semibold))
        Text("Search by name, location, camera, or date.\nUse filters to narrow by curation state, year, or color.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
    }
}
```

**No-results empty state** -- distinguish between "no results for query" vs "no results with filters":
```swift
private var noResultsEmptyState: some View {
    VStack(spacing: 16) {
        Image(systemName: "photo.slash")
            .font(.system(size: 48))
            .foregroundStyle(.tertiary)
        if !query.isEmpty {
            Text("No results for \"\(query)\"")
                .font(.title3.weight(.semibold))
        } else {
            Text("No matching photos")
                .font(.title3.weight(.semibold))
        }
        if filter.isActive {
            Text("Try removing some filters")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Clear Filters") {
                filter = MobileSearchFilter()
            }
            .font(.subheadline)
            .buttonStyle(.bordered)
        } else {
            Text("Try different keywords or check spelling")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}
```

---

## Files to modify

| File | Change |
|------|--------|
| `HoehnPhotosMobile/Features/Search/MobileSearchView.swift` | Add `MobileSearchFilter` struct, new state vars, filter sheet, chips, header, density toggle, updated body/search |
| `HoehnPhotosCore/Database/Repository/MobileRepositories.swift` | Add new `search()` overload with filter/sort parameters (keep old signature) |

## Notes

- `CurationState` is already in `SharedEnums.swift` and available in the iOS target via `HoehnPhotosCore`.
- `PhotoAsset.isGrayscale` and `curationState` columns already exist in the database -- no migration needed.
- The Mac app does client-side filtering via `MetadataFilter.matches(_:)` because it loads all photos. For search, SQL-level filtering is better since we're already building a query string.
- Consider persisting `useCompactGrid` with `@AppStorage("searchCompactGrid")` so density preference survives app relaunch.
- The `MobileSearchFilter` is intentionally simpler than the Mac `MetadataFilter` -- no sceneTypes or peopleOnly. These can be added later.
- The year slider range (2000-2026) is hardcoded in the skeleton. For a more dynamic approach, you could query min/max year from the database, but the static range is fine for v1.
