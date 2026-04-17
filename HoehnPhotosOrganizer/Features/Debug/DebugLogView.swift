import SwiftUI
import GRDB

// MARK: - DebugLogView

/// Debug panel opened from Debug > Show Debug Log.
/// Shows a summary of what's in the catalog database plus recent activity.
struct DebugLogView: View {
    let db: AppDatabase

    @State private var stats: CatalogStats = .empty
    @State private var recentPhotos: [PhotoAsset] = []
    @State private var isLoading = true
    @State private var dbPath: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Debug Log")
                        .font(.title2.bold())
                    Text(dbPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Refresh") { Task { await loadStats() } }
                    .buttonStyle(.bordered)
            }
            .padding(20)

            Divider()

            if isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        statsSectionView
                        recentPhotosView
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 500)
        .task { await loadStats() }
    }

    // MARK: - Stats section

    private var statsSectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Catalog Stats")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                statCard(label: "Total Photos", value: "\(stats.total)")
                statCard(label: "Proxy Pending", value: "\(stats.proxyPending)")
                statCard(label: "Proxy Ready", value: "\(stats.proxyReady)")
                statCard(label: "Metadata Enriched", value: "\(stats.metadataEnriched)")
                statCard(label: "Errored", value: "\(stats.errored)", color: stats.errored > 0 ? .red : .secondary)
                statCard(label: "Film Frames", value: "\(stats.filmFrames)")
            }
        }
    }

    private func statCard(label: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title.bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - Recent photos

    private var recentPhotosView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Catalog Entries (last 20)")
                .font(.headline)

            if recentPhotos.isEmpty {
                Text("No photos in catalog yet.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                VStack(spacing: 0) {
                    ForEach(recentPhotos) { photo in
                        PhotoDebugRow(photo: photo)
                        Divider()
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
        }
    }

    // MARK: - Data loading

    private func loadStats() async {
        do {
            let result = try await db.dbPool.read { database -> (CatalogStats, [PhotoAsset]) in
                let total = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM photo_assets") ?? 0
                let proxyPending = try Int.fetchOne(database,
                    sql: "SELECT COUNT(*) FROM photo_assets WHERE processing_state = 'proxyPending'") ?? 0
                let proxyReady = try Int.fetchOne(database,
                    sql: "SELECT COUNT(*) FROM photo_assets WHERE processing_state = 'proxyReady'") ?? 0
                let metadataEnriched = try Int.fetchOne(database,
                    sql: "SELECT COUNT(*) FROM photo_assets WHERE processing_state = 'metadataEnriched'") ?? 0
                let errored = try Int.fetchOne(database,
                    sql: "SELECT COUNT(*) FROM photo_assets WHERE error_message IS NOT NULL AND error_message != ''") ?? 0
                let filmFrames = try Int.fetchOne(database,
                    sql: "SELECT COUNT(*) FROM photo_assets WHERE role = 'workflowOutput'") ?? 0

                let recent = try PhotoAsset
                    .order(Column("updated_at").desc)
                    .limit(20)
                    .fetchAll(database)

                let stats = CatalogStats(
                    total: total,
                    proxyPending: proxyPending,
                    proxyReady: proxyReady,
                    metadataEnriched: metadataEnriched,
                    errored: errored,
                    filmFrames: filmFrames
                )
                return (stats, recent)
            }
            await MainActor.run {
                stats = result.0
                recentPhotos = result.1
                isLoading = false
            }
        } catch {
            await MainActor.run { isLoading = false }
        }

        // Resolve DB path for display
        if let url = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false) {
            await MainActor.run {
                dbPath = url
                    .appendingPathComponent("HoehnPhotosOrganizer/Catalog.db")
                    .path
            }
        }
    }
}

// MARK: - CatalogStats

private struct CatalogStats {
    var total: Int
    var proxyPending: Int
    var proxyReady: Int
    var metadataEnriched: Int
    var errored: Int
    var filmFrames: Int

    static let empty = CatalogStats(
        total: 0, proxyPending: 0, proxyReady: 0,
        metadataEnriched: 0, errored: 0, filmFrames: 0
    )
}

// MARK: - PhotoDebugRow

private struct PhotoDebugRow: View {
    let photo: PhotoAsset

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(photo.canonicalName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(photo.filePath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(photo.processingState)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(stateColor(photo.processingState).opacity(0.15))
                    .foregroundStyle(stateColor(photo.processingState))
                    .clipShape(Capsule())
                if let err = photo.errorMessage, !err.isEmpty {
                    Text("Error: \(err)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "proxyReady", "metadataEnriched", "syncPending", "synced": return .green
        case "proxyPending", "indexed": return .orange
        default: return .secondary
        }
    }
}
