import SwiftUI
import HoehnPhotosCore

// MARK: - MobileStudioGalleryView

/// Top-level gallery of all Studio renders across all photos.
/// Shows a 2-column grid with medium filter chips at the top.
struct MobileStudioGalleryView: View {

    @Environment(\.appDatabase) private var appDatabase
    @State private var allRevisions: [StudioRevision] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selectedMedium: StudioMedium?  // nil = "All"
    @State private var selectedRevision: StudioRevision?

    private let columns = [
        GridItem(.flexible(), spacing: HPSpacing.md),
        GridItem(.flexible(), spacing: HPSpacing.md),
    ]

    private var filteredRevisions: [StudioRevision] {
        guard let medium = selectedMedium else { return allRevisions }
        return allRevisions.filter { $0.medium == medium.rawValue }
    }

    /// Mediums that actually have renders (for chip visibility).
    private var availableMediums: [StudioMedium] {
        let present = Set(allRevisions.map(\.medium))
        return StudioMedium.allCases.filter { present.contains($0.rawValue) }
    }

    /// Build FilterChip array for the shared FilterChipBar.
    private var mediumChips: [FilterChip] {
        var chips: [FilterChip] = [
            FilterChip(id: "all", label: "All", icon: "paintpalette", count: allRevisions.count)
        ]
        for medium in availableMediums {
            let count = allRevisions.filter { $0.medium == medium.rawValue }.count
            chips.append(FilterChip(id: medium.rawValue, label: medium.rawValue, icon: medium.icon, count: count))
        }
        return chips
    }

    private var selectedChipId: String? {
        selectedMedium?.rawValue ?? "all"
    }

    var body: some View {
        Group {
            if isLoading {
                skeletonGrid
            } else if let err = loadError {
                VStack(spacing: HPSpacing.base) {
                    ErrorBanner(message: err) {
                        Task { await loadRevisions() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if allRevisions.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    FilterChipBar(
                        chips: mediumChips,
                        selectedId: selectedChipId
                    ) { chipId in
                        if chipId == nil || chipId == "all" {
                            selectedMedium = nil
                        } else {
                            selectedMedium = StudioMedium(rawValue: chipId!)
                        }
                    }
                    revisionGrid
                }
            }
        }
        .task { await loadRevisions() }
        .sheet(item: $selectedRevision) { revision in
            MobileStudioDetailView(revision: revision)
        }
    }

    // MARK: - Grid

    private var revisionGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: HPSpacing.md) {
                ForEach(filteredRevisions) { revision in
                    StudioRevisionCard(revision: revision)
                        .onTapGesture {
                            selectedRevision = revision
                        }
                }
            }
            .padding(HPSpacing.base)
        }
        .refreshable {
            await loadRevisions()
        }
    }

    // MARK: - Skeleton Loading

    private var skeletonGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: HPSpacing.md) {
                ForEach(0..<6, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: HPSpacing.sm) {
                        ShimmerCell()
                            .aspectRatio(1, contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: HPRadius.large))
                        SkeletonRect(width: 80, height: 12)
                        SkeletonRect(width: 60, height: 10)
                    }
                }
            }
            .padding(HPSpacing.base)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        EmptyStateView(
            icon: "paintpalette",
            title: "No Studio Renders",
            message: "Render artistic versions of your photos on Mac, then sync to see them here."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading

    private func loadRevisions() async {
        guard let db = appDatabase else {
            isLoading = false
            return
        }
        do {
            allRevisions = try await MobileStudioRepository(db: db).fetchAllRevisions()
        } catch {
            loadError = error.localizedDescription
            print("[StudioGallery] Load error: \(error)")
        }
        isLoading = false
    }
}

