import SwiftUI
import GRDB

// MARK: - FilmLineageSection

/// Compact inspector section showing film-strip lineage for a `PhotoAsset`.
///
/// Renders nothing (`EmptyView`) when the photo has no lineage relationships —
/// so it is safe to include unconditionally in InspectorPanel for all photos.
///
/// CP-2: Film Frame Lineage browser.
struct FilmLineageSection: View {

    let photo: PhotoAsset
    let db: AppDatabase
    let onSelectPhoto: (PhotoAsset) -> Void

    // MARK: - Local state (no separate ViewModel — per plan constraint)

    @State private var parent: PhotoAsset?
    @State private var siblings: [PhotoAsset] = []
    @State private var children: [PhotoAsset] = []
    @State private var extractionEvent: ExtractionEvent?
    @State private var toolLogs: [ExtractionToolLog] = []
    // Name-pattern fallback (when no formal asset_lineage records exist)
    @State private var originalScan: PhotoAsset?
    @State private var seriesVersions: [PhotoAsset] = []
    @State private var loaded = false

    // MARK: - View body

    var body: some View {
        Group {
            if loaded && hasLineage {
                sectionContent
            }
            // Renders nothing until load completes or if no lineage exists
        }
        .task(id: photo.id) {
            await loadLineage()
        }
    }

    // MARK: - Section content

    private var hasLineage: Bool {
        parent != nil || !siblings.isEmpty || !children.isEmpty || !toolLogs.isEmpty
        || originalScan != nil || !seriesVersions.isEmpty
    }

    private var sectionContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Film Lineage")
                .font(.headline)

            // Parent row (shown when this photo is a child frame)
            if let parent {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Parent Scan")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        onSelectPhoto(parent)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.richtext")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(parent.canonicalName)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.right.circle")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            // Sibling chips (other frames from the same scan)
            if !siblings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sibling Frames")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FlowChips(items: siblings, onTap: onSelectPhoto)
                }
            }

            // Child frames (shown when this photo is a parent scan)
            if !children.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Extracted Frames")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FlowChips(items: children, onTap: onSelectPhoto)
                }
            }

            // Name-pattern fallback: original scan (shown when this is a frame with no formal parent)
            if parent == nil, let original = originalScan {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Original Scan")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        onSelectPhoto(original)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.richtext")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(original.canonicalName)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.right.circle")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            // Name-pattern fallback: other versions in the same series
            if siblings.isEmpty, !seriesVersions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(originalScan != nil ? "Other Frames" : "Versions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FlowChips(items: seriesVersions, onTap: onSelectPhoto)
                }
            }

            // Extraction event + tool log
            if !toolLogs.isEmpty {
                Divider()
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape.2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Extraction Log")
                            .font(.caption.weight(.semibold))
                        if let event = extractionEvent {
                            Text("(\(event.frameCount) frames)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    ForEach(toolLogs) { log in
                        ToolLogRow(log: log)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    // MARK: - Data loading

    private func loadLineage() async {
        let repo = LineageRepository(db.dbPool)
        do {
            async let parentTask   = repo.fetchParent(for: photo.id)
            async let siblingsTask = repo.fetchSiblings(for: photo.id)
            async let childrenTask = repo.fetchChildren(for: photo.id)
            async let eventTask    = repo.fetchExtractionEvent(for: photo.id)
            async let relatedTask  = repo.fetchRelatedByBaseName(for: photo)

            let (p, s, c, event, related) = try await (parentTask, siblingsTask, childrenTask, eventTask, relatedTask)

            var logs: [ExtractionToolLog] = []
            if let event {
                logs = try await repo.fetchToolLogs(extractionId: event.id)
            }

            parent          = p
            siblings        = s
            children        = c
            extractionEvent = event
            toolLogs        = logs
            originalScan    = related.original
            seriesVersions  = related.versions
            loaded          = true
        } catch {
            // Non-fatal: lineage section simply stays hidden on DB error
            loaded = true
        }
    }
}

// MARK: - FlowChips

/// Horizontal scrolling row of tappable name chips for sibling/child frames.
private struct FlowChips: View {
    let items: [PhotoAsset]
    let onTap: (PhotoAsset) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    Button {
                        onTap(item)
                    } label: {
                        Text(shortName(item.canonicalName))
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.15))
                            )
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Strips extension + common prefix to produce a compact frame label like "_01".
    private func shortName(_ canonical: String) -> String {
        let noExt = (canonical as NSString).deletingPathExtension
        // Return last 6 chars max so chips stay narrow
        if noExt.count <= 6 { return noExt }
        return String(noExt.suffix(6))
    }
}

// MARK: - ToolLogRow

/// Single row in the Extraction Log list.
private struct ToolLogRow: View {
    let log: ExtractionToolLog

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            statusIcon
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(log.toolName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if !log.detail.isEmpty {
                    Text(log.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch log.status {
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .fallback, .skipped:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .started:
            Image(systemName: "circle.dotted")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
