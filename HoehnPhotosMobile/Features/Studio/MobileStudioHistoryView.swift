import SwiftUI
import HoehnPhotosCore

// MARK: - MobileStudioHistoryView

/// Read-only view showing all Studio renders for a given photo.
/// Displayed as a grid of thumbnails; tapping opens a full-res preview.
struct MobileStudioHistoryView: View {

    let photoId: String
    @Environment(\.appDatabase) private var appDatabase
    @State private var revisions: [StudioRevision] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selectedRevision: StudioRevision?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = loadError {
                VStack(spacing: 16) {
                    ErrorBanner(message: err) {
                        Task { await loadRevisions() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if revisions.isEmpty {
                emptyState
            } else {
                revisionGrid
            }
        }
        .navigationTitle("Studio History")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadRevisions()
        }
        .sheet(item: $selectedRevision) { revision in
            StudioRevisionDetailView(revision: revision)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        EmptyStateView(
            icon: "paintpalette",
            title: "No Studio Renders",
            message: "Studio renders created on your Mac will appear here after syncing."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Grid

    private var revisionGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(revisions) { revision in
                    StudioRevisionCard(revision: revision)
                        .onTapGesture {
                            selectedRevision = revision
                        }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Data Loading

    private func loadRevisions() async {
        guard let db = appDatabase else {
            isLoading = false
            return
        }
        do {
            revisions = try await MobileStudioRepository(db: db).fetchRevisions(photoId: photoId)
        } catch {
            loadError = error.localizedDescription
            print("[StudioHistory] Load error: \(error)")
        }
        isLoading = false
    }
}

// MARK: - MobileStudioBrowseView

/// Top-level Studio browse view showing all renders across all photos.
/// Used as a tab destination or navigation destination.
struct MobileStudioBrowseView: View {

    @Environment(\.appDatabase) private var appDatabase
    @State private var revisions: [StudioRevision] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selectedRevision: StudioRevision?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = loadError {
                    VStack(spacing: 16) {
                        ErrorBanner(message: err) {
                            Task { await loadRevisions() }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if revisions.isEmpty {
                    emptyState
                } else {
                    revisionGrid
                }
            }
            .navigationTitle("Studio")
            .task {
                await loadRevisions()
            }
            .sheet(item: $selectedRevision) { revision in
                StudioRevisionDetailView(revision: revision)
            }
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            icon: "paintpalette",
            title: "No Studio Renders",
            message: "Render artistic versions of your photos on Mac, then sync to see them here."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var revisionGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(revisions) { revision in
                    StudioRevisionCard(revision: revision)
                        .onTapGesture {
                            selectedRevision = revision
                        }
                }
            }
            .padding(16)
        }
        .refreshable {
            await loadRevisions()
        }
    }

    private func loadRevisions() async {
        guard let db = appDatabase else {
            isLoading = false
            return
        }
        do {
            revisions = try await MobileStudioRepository(db: db).fetchAllRevisions()
        } catch {
            loadError = error.localizedDescription
            print("[StudioBrowse] Load error: \(error)")
        }
        isLoading = false
    }
}

// MARK: - StudioRevisionCard

/// Grid card showing a Studio revision thumbnail with medium and date overlay.
struct StudioRevisionCard: View {
    let revision: StudioRevision
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Thumbnail
            HPColor.cardBackground
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let img = thumbnail {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        VStack(spacing: HPSpacing.sm) {
                            Image(systemName: revision.studioMedium.icon)
                                .font(.system(size: 28))
                                .foregroundStyle(.tertiary)
                            Text(revision.studioMedium.rawValue)
                                .font(HPFont.timestamp)
                                .foregroundStyle(.quaternary)
                        }
                    }
                }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: HPRadius.large))

            // Info overlay
            VStack(alignment: .leading, spacing: HPSpacing.xxs) {
                HStack(spacing: HPSpacing.xs) {
                    Image(systemName: revision.studioMedium.icon)
                        .font(.system(size: 9))
                    Text(revision.studioMedium.rawValue)
                        .font(HPFont.badgeLabel)
                        .lineLimit(1)
                }
                Text(HPDateFormatter.formatISO(revision.createdAt))
                    .font(.system(size: 9))
            }
            .foregroundStyle(.white)
            .padding(HPSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.6), .clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
            )
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: HPRadius.large,
                    bottomTrailingRadius: HPRadius.large,
                    topTrailingRadius: 0
                )
            )
        }
        .accessibilityLabel("\(revision.studioMedium.rawValue) render, \(HPDateFormatter.formatISO(revision.createdAt))")
        .accessibilityAddTraits(.isButton)
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        guard let thumbPath = revision.thumbnailPath else { return }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = appSupport
            .appendingPathComponent("HoehnPhotos")
            .appendingPathComponent("studio")
            .appendingPathComponent(thumbPath)
        let loadedImage = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return nil as UIImage? }
            return UIImage(data: data)
        }.value
        if let img = loadedImage {
            thumbnail = img
        }
    }

}

// MARK: - StudioRevisionDetailView

/// Full-screen preview of a Studio revision with metadata.
struct StudioRevisionDetailView: View {
    let revision: StudioRevision
    @Environment(\.dismiss) private var dismiss
    @State private var fullImage: UIImage?

    var body: some View {
        NavigationStack {
            ZStack {
                HPColor.canvasBackground.ignoresSafeArea()

                if let img = fullImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .padding(HPSpacing.base)
                } else if revision.fullResPath != nil {
                    VStack(spacing: HPSpacing.md) {
                        ProgressView()
                            .tint(.white)
                        Text("Loading render...")
                            .font(HPFont.cardSubtitle)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                } else {
                    VStack(spacing: HPSpacing.base) {
                        Image(systemName: revision.studioMedium.icon)
                            .font(.system(size: 56))
                            .foregroundStyle(.white.opacity(0.3))
                        Text("Full resolution not synced")
                            .font(HPFont.body)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                metadataBar
            }
            .navigationTitle(revision.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .task {
                await loadFullRes()
            }
        }
    }

    private var metadataBar: some View {
        VStack(spacing: HPSpacing.sm) {
            HStack(spacing: HPSpacing.md) {
                Label(revision.studioMedium.rawValue, systemImage: revision.studioMedium.icon)
                    .font(HPFont.bodyStrong)
                Spacer()
                Text(HPDateFormatter.formatISO(revision.createdAt))
                    .font(HPFont.cardSubtitle)
                    .foregroundStyle(.secondary)
            }

            if let params = revision.parameters {
                HStack(spacing: HPSpacing.base) {
                    paramPill("Brush", value: String(format: "%.0f", params.brushSize))
                    paramPill("Detail", value: String(format: "%.0f%%", params.detail * 100))
                    paramPill("Texture", value: String(format: "%.0f%%", params.texture * 100))
                    paramPill("Contrast", value: String(format: "%.0f%%", params.contrast * 100))
                }
            }
        }
        .padding(HPSpacing.base)
        .background(.ultraThinMaterial)
    }

    private func paramPill(_ label: String, value: String) -> some View {
        VStack(spacing: HPSpacing.xxs) {
            Text(value)
                .font(HPFont.metaValue)
            Text(label)
                .font(HPFont.metaLabel)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func loadFullRes() async {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let studioDir = appSupport
            .appendingPathComponent("HoehnPhotos")
            .appendingPathComponent("studio")

        if let fullPath = revision.fullResPath {
            let url = studioDir.appendingPathComponent(fullPath)
            let loadedImage = await Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: url) else { return nil as UIImage? }
                return UIImage(data: data)
            }.value
            if let img = loadedImage {
                fullImage = img
                return
            }
        }

        if let thumbPath = revision.thumbnailPath {
            let url = studioDir.appendingPathComponent(thumbPath)
            let loadedImage = await Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: url) else { return nil as UIImage? }
                return UIImage(data: data)
            }.value
            if let img = loadedImage {
                fullImage = img
            }
        }
    }
}
