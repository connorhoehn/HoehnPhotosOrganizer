import SwiftUI
import GRDB

// MARK: - PhotoTimelineView

/// Vertical chronological timeline of all activity events for a single photo.
/// Shows import → extraction → face detection → adjustments → editorial reviews →
/// metadata enrichment → print attempts → notes — in the order they happened.
struct PhotoTimelineView: View {
    let photoAssetId: String
    let db: AppDatabase

    @State private var events: [ActivityEvent] = []
    @State private var loading = true
    @State private var observationTask: Task<Void, Never>? = nil

    var body: some View {
        Group {
            if loading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.75)
                    Text("Loading timeline…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else if events.isEmpty {
                Text("No activity recorded yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        TimelineRow(
                            event: event,
                            isLast: index == events.count - 1
                        )
                    }
                }
            }
        }
        .task(id: photoAssetId) {
            await startObserving()
        }
        .onDisappear { observationTask?.cancel() }
    }

    private func startObserving() async {
        observationTask?.cancel()
        loading = true
        let stream = ValueObservation
            .tracking { db in
                try ActivityEvent
                    .filter(ActivityEvent.Columns.photoAssetId == photoAssetId)
                    .order(ActivityEvent.Columns.occurredAt.asc)
                    .fetchAll(db)
            }
            .values(in: db.dbPool)

        observationTask = Task {
            do {
                for try await fetched in stream {
                    guard !Task.isCancelled else { return }
                    events = fetched
                    loading = false
                }
            } catch {
                loading = false
            }
        }
    }
}

// MARK: - TimelineRow

private struct TimelineRow: View {
    let event: ActivityEvent
    let isLast: Bool

    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left: connector line + icon dot
            VStack(spacing: 0) {
                Circle()
                    .fill(eventColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)

                if !isLast {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 2)
                }
            }
            .frame(width: 24, alignment: .top)

            // Right: content
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: eventSymbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(eventColor)

                    Text(event.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(isExpanded ? nil : 1)

                    Spacer(minLength: 4)

                    Text(event.occurredAt.shortRelative)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: isExpanded)
                }
            }
            .padding(.bottom, isLast ? 4 : 10)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }
        }
    }

    // MARK: - Icon / color

    private var eventSymbol: String {
        switch event.kind {
        case .importBatch:        return "square.and.arrow.down.fill"
        case .frameExtraction:    return "film.fill"
        case .adjustment:         return "slider.horizontal.3"
        case .colorGrade:         return "paintpalette.fill"
        case .printAttempt:       return "printer.fill"
        case .batchTransform:     return "arrow.triangle.2.circlepath"
        case .reAdjustment:       return "arrow.counterclockwise"
        case .note:               return "text.bubble.fill"
        case .todo:               return "checklist"
        case .rollback:           return "clock.arrow.circlepath"
        case .pipelineRun:        return "gearshape.2.fill"
        case .editorialReview:    return "sparkles"
        case .faceDetection:      return "person.crop.circle.fill"
        case .metadataEnrichment: return "tag.fill"
        case .printJob:           return "printer.dotmatrix.fill"
        case .scanAttachment:     return "doc.viewfinder.fill"
        case .aiSummary:          return "sparkles"
        case .search:             return "magnifyingglass"
        case .studioRender:       return "paintbrush.pointed.fill"
        case .studioVersion:      return "clock.badge.checkmark.fill"
        case .studioExport:       return "square.and.arrow.up"
        case .studioPrintLab:     return "printer.fill"
        case .jobCreated:         return "tray.full.fill"
        case .jobCompleted:       return "checkmark.circle.fill"
        case .jobSplit:           return "arrow.triangle.branch"
        case .curveLinearized:    return "line.diagonal"
        case .curveSaved:         return "square.and.arrow.down"
        case .curveBlended:       return "arrow.triangle.merge"
        case .versionCreated:     return "doc.badge.plus"
        }
    }

    private var eventColor: Color {
        switch event.kind {
        case .importBatch:        return .indigo
        case .frameExtraction:    return .orange
        case .adjustment:         return .blue
        case .colorGrade:         return .purple
        case .printAttempt:       return .green
        case .batchTransform:     return .teal
        case .reAdjustment:       return .secondary
        case .note:               return .yellow
        case .todo:               return .pink
        case .rollback:           return .red
        case .pipelineRun:        return .mint
        case .editorialReview:    return Color(red: 0.58, green: 0.44, blue: 0.86)
        case .faceDetection:      return Color(red: 0.20, green: 0.70, blue: 0.60)
        case .metadataEnrichment: return Color(red: 0.80, green: 0.55, blue: 0.25)
        case .printJob:           return .green
        case .scanAttachment:     return .orange
        case .aiSummary:          return .purple
        case .search:             return .blue
        case .studioRender:       return .purple
        case .studioVersion:      return .purple
        case .studioExport:       return .purple
        case .studioPrintLab:     return .purple
        case .jobCreated:         return .cyan
        case .jobCompleted:       return .green
        case .jobSplit:           return .cyan
        case .curveLinearized:    return .purple
        case .curveSaved:         return .green
        case .curveBlended:       return .orange
        case .versionCreated:     return .blue
        }
    }
}

// MARK: - Date formatting

private extension Date {
    var shortRelative: String {
        let seconds = Date().timeIntervalSince(self)
        switch seconds {
        case ..<60:        return "now"
        case ..<3600:      return "\(Int(seconds / 60))m"
        case ..<86400:     return "\(Int(seconds / 3600))h"
        case ..<604800:    return "\(Int(seconds / 86400))d"
        default:
            let f = DateFormatter()
            f.dateStyle = .short
            f.timeStyle = .none
            return f.string(from: self)
        }
    }
}
