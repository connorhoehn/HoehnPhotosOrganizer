import SwiftUI
import GRDB

// MARK: - EventDetailView

/// Full detail view for a single ActivityEvent.
/// Shows: large icon header, title, detail, optional photo thumbnail, child events,
/// and an inline "Add Note" field at the bottom.
struct EventDetailView: View {

    let event: ActivityEvent
    let viewModel: ActivityFeedViewModel
    var onOpenInStudio: (() -> Void)?
    var onOpenInJobs: ((String?) -> Void)?
    var onOpenInCurveLab: (() -> Void)?

    @State private var newNoteText: String = ""
    @State private var isSavingNote: Bool = false
    @FocusState private var noteFocused: Bool

    private var isStudioEvent: Bool {
        [.studioRender, .studioVersion, .studioExport, .studioPrintLab].contains(event.kind)
    }

    private var isJobEvent: Bool {
        [.jobCreated, .jobCompleted, .jobSplit].contains(event.kind)
    }

    private var isCurveLabEvent: Bool {
        [.curveLinearized, .curveSaved, .curveBlended].contains(event.kind)
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: Header
            eventHeader
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            // MARK: Children list
            childrenSection

            Divider()

            // MARK: Inline note add
            addNoteBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .task {
            // Eagerly load children if not cached
            if viewModel.childrenCache[event.id] == nil {
                viewModel.toggleExpand(eventId: event.id)
            }
        }
    }

    // MARK: - Event header

    private var eventHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                // Photo thumbnail when available
                if let photoId = event.photoAssetId {
                    photoThumbnail(photoId: photoId)
                } else {
                    // Large icon badge
                    ZStack {
                        Circle()
                            .fill(eventColor.opacity(0.15))
                            .frame(width: 52, height: 52)
                        Image(systemName: eventSymbol)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(eventColor)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(event.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.primary)

                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Text(event.occurredAt, style: .relative)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                        Text("·")
                            .foregroundStyle(.quaternary)
                        Text(event.occurredAt, format: .dateTime.month().day().hour().minute())
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()
            }
        }
    }

    /// Photo proxy thumbnail for the header.
    /// Uses the view model's proxy URL cache (keyed by canonicalName) rather than
    /// the photoAssetId UUID, which would produce a non-existent filename.
    @ViewBuilder
    private func photoThumbnail(photoId: String) -> some View {
        let proxyURL = viewModel.resolveProxyURL(for: photoId)
        let nsImage = proxyURL.flatMap { NSImage(contentsOf: $0) }

        if let img = nsImage {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 80, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
        } else {
            ZStack {
                Circle()
                    .fill(eventColor.opacity(0.15))
                    .frame(width: 52, height: 52)
                Image(systemName: eventSymbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(eventColor)
            }
        }
    }

    // MARK: - Children section

    @ViewBuilder
    private var childrenSection: some View {
        let children = viewModel.childrenCache[event.id] ?? []
        if children.isEmpty {
            // Show full event detail as body content when no children
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Studio events: large image preview + structured metadata
                    if isStudioEvent {
                        studioDetailContent
                    } else if isJobEvent {
                        jobDetailContent
                    } else if isCurveLabEvent {
                        curveLabDetailContent
                    } else {
                        if let detail = event.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 14))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let metadata = event.metadata, !metadata.isEmpty,
                           let data = metadata.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            metadataSection(json)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(children) { child in
                        childRow(child)
                        if child.id != children.last?.id {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func childRow(_ child: ActivityEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(childColor(for: child.kind).opacity(0.12))
                    .frame(width: 28, height: 28)
                Image(systemName: symbol(for: child.kind))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(childColor(for: child.kind))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(child.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                if let detail = child.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            Spacer()

            Text(child.occurredAt, style: .relative)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Add note bar

    private var addNoteBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            TextField("Add a note…", text: $newNoteText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .focused($noteFocused)
                .onSubmit {
                    guard !newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    submitNote()
                }

            Button {
                submitNote()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSavingNote)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Note submission

    private func submitNote() {
        let body = newNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        newNoteText = ""
        isSavingNote = true
        Task {
            try? await viewModel.addNote(body: body, toEvent: event.id)
            isSavingNote = false
        }
    }

    // MARK: - Metadata section

    @ViewBuilder
    private func metadataSection(_ json: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(json.keys.sorted(), id: \.self) { key in
                let displayKey = key
                    .replacingOccurrences(of: "_", with: " ")
                    .capitalized
                if let value = json[key] {
                    let valueStr: String = {
                        if let s = value as? String { return s }
                        if let n = value as? NSNumber { return n.stringValue }
                        if let a = value as? [Any] { return a.map { "\($0)" }.joined(separator: ", ") }
                        return "\(value)"
                    }()
                    HStack(alignment: .top, spacing: 8) {
                        Text(displayKey)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .trailing)
                        Text(valueStr)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                        Spacer()
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }

    // MARK: - Studio detail content

    @ViewBuilder
    private var studioDetailContent: some View {
        let json = parseMetadata()

        // Large image preview
        if let photoId = event.photoAssetId {
            studioImagePreview(photoId: photoId)
        }

        // "Open in Studio" button
        if let openAction = onOpenInStudio {
            Button {
                openAction()
            } label: {
                Label("Open in Studio", systemImage: "paintpalette")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }

        // Structured metadata cards
        studioMetadataCards(json: json)

        // Detail text (if present and not already shown in metadata)
        if let detail = event.detail, !detail.isEmpty,
           json["version_name"] == nil, json["medium"] == nil {
            Text(detail)
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Job detail content

    @ViewBuilder
    private var jobDetailContent: some View {
        let json = parseMetadata()

        // Icon badge
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(jobIconColor.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: jobIconSymbol)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(jobIconColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(event.occurredAt, style: .relative)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }

        // Metadata cards
        jobMetadataCards(json: json)

        // Detail text
        if let detail = event.detail, !detail.isEmpty {
            Text(detail)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }

        // "Open in Jobs" button
        if let openAction = onOpenInJobs {
            let jobId = json["job_id"] as? String ?? json["parent_job_id"] as? String
            Button {
                openAction(jobId)
            } label: {
                Label("Open in Jobs", systemImage: "tray.full")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
    }

    // MARK: - CurveLab detail content

    @ViewBuilder
    private var curveLabDetailContent: some View {
        let json = parseMetadata()

        // Icon badge
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(curveLabIconColor.opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: curveLabIconSymbol)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(curveLabIconColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(event.occurredAt, style: .relative)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }

        // Metadata cards
        curveLabMetadataCards(json: json)

        // Detail text
        if let detail = event.detail, !detail.isEmpty {
            Text(detail)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }

        // "Open in CurveLab" button
        if let openAction = onOpenInCurveLab {
            Button {
                openAction()
            } label: {
                Label("Open in CurveLab", systemImage: "line.diagonal")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
    }

    private var curveLabIconSymbol: String {
        switch event.kind {
        case .curveLinearized: return "line.diagonal"
        case .curveSaved:     return "square.and.arrow.down"
        case .curveBlended:   return "arrow.triangle.merge"
        default:              return "line.diagonal"
        }
    }

    private var curveLabIconColor: Color {
        switch event.kind {
        case .curveLinearized: return .purple
        case .curveSaved:     return .green
        case .curveBlended:   return .orange
        default:              return .purple
        }
    }

    @ViewBuilder
    private func curveLabMetadataCards(json: [String: Any]) -> some View {
        let rows: [(String, String)] = {
            switch event.kind {
            case .curveLinearized:
                var items: [(String, String)] = []
                if let quad = json["input_quad"] as? String {
                    items.append(("Input Quad", quad))
                }
                if let measurement = json["measurement_file"] as? String {
                    items.append(("Measurement", (measurement as NSString).lastPathComponent))
                }
                if let smoothing = json["smoothing"] as? Double {
                    items.append(("Smoothing", String(format: "%.2f", smoothing)))
                } else if let smoothing = json["smoothing"] as? NSNumber {
                    items.append(("Smoothing", String(format: "%.2f", smoothing.doubleValue)))
                }
                return items

            case .curveSaved:
                var items: [(String, String)] = []
                if let filename = json["filename"] as? String {
                    items.append(("Filename", filename))
                }
                if let profile = json["profile"] as? String {
                    items.append(("Profile", profile))
                }
                return items

            case .curveBlended:
                var items: [(String, String)] = []
                if let curve1 = json["curve1"] as? String {
                    items.append(("Curve 1", curve1))
                }
                if let curve2 = json["curve2"] as? String {
                    items.append(("Curve 2", curve2))
                }
                if let output = json["output"] as? String {
                    items.append(("Output", output))
                }
                return items

            default:
                return []
            }
        }()

        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows, id: \.0) { label, value in
                    HStack(alignment: .top, spacing: 8) {
                        Text(label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .trailing)
                        Text(value)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                        Spacer()
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
        }
    }

    private var jobIconSymbol: String {
        switch event.kind {
        case .jobCreated:   return "tray.and.arrow.down"
        case .jobCompleted: return "checkmark.circle"
        case .jobSplit:     return "scissors"
        default:            return "tray.full"
        }
    }

    private var jobIconColor: Color {
        switch event.kind {
        case .jobCreated:   return .cyan
        case .jobCompleted: return .green
        case .jobSplit:     return .cyan
        default:            return .secondary
        }
    }

    @ViewBuilder
    private func jobMetadataCards(json: [String: Any]) -> some View {
        let rows: [(String, String)] = {
            var items: [(String, String)] = []
            if let photoCount = json["photo_count"] as? Int {
                items.append(("Photos", "\(photoCount) photos"))
            } else if let photoCount = json["photo_count"] as? NSNumber {
                items.append(("Photos", "\(photoCount.intValue) photos"))
            }
            if event.kind == .jobSplit, let childCount = json["child_count"] as? Int {
                items.append(("Sub-jobs", "Split into \(childCount) sub-jobs"))
            } else if event.kind == .jobSplit, let childCount = json["child_count"] as? NSNumber {
                items.append(("Sub-jobs", "Split into \(childCount.intValue) sub-jobs"))
            }
            return items
        }()

        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows, id: \.0) { label, value in
                    HStack(alignment: .top, spacing: 8) {
                        Text(label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .trailing)
                        Text(value)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                        Spacer()
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
        }
    }

    @ViewBuilder
    private func studioImagePreview(photoId: String) -> some View {
        let proxyURL = viewModel.resolveProxyURL(for: photoId)
        let nsImage = proxyURL.flatMap { NSImage(contentsOf: $0) }

        if let img = nsImage {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        }
    }

    @ViewBuilder
    private func studioMetadataCards(json: [String: Any]) -> some View {
        let rows: [(String, String)] = {
            switch event.kind {
            case .studioRender:
                var items: [(String, String)] = []
                if let medium = json["medium"] as? String {
                    items.append(("Medium", medium.capitalized))
                }
                if let duration = json["duration_seconds"] as? Double {
                    let formatted = duration < 60
                        ? String(format: "%.1f seconds", duration)
                        : String(format: "%.1f minutes", duration / 60)
                    items.append(("Duration", formatted))
                }
                return items

            case .studioVersion:
                var items: [(String, String)] = []
                if let name = json["version_name"] as? String {
                    items.append(("Version", name))
                }
                if let medium = json["medium"] as? String {
                    items.append(("Medium", medium.capitalized))
                }
                return items

            case .studioExport:
                var items: [(String, String)] = []
                if let format = json["format"] as? String {
                    items.append(("Format", format.uppercased()))
                }
                if let path = json["file_path"] as? String {
                    items.append(("File", (path as NSString).lastPathComponent))
                }
                return items

            case .studioPrintLab:
                var items: [(String, String)] = []
                if let medium = json["medium"] as? String {
                    items.append(("Medium", medium.capitalized))
                }
                return items

            default:
                return []
            }
        }()

        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows, id: \.0) { label, value in
                    HStack(alignment: .top, spacing: 8) {
                        Text(label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .trailing)
                        Text(value)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                        Spacer()
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
        }
    }

    private func parseMetadata() -> [String: Any] {
        guard let metadata = event.metadata, !metadata.isEmpty,
              let data = metadata.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    // MARK: - Icon/color helpers

    private var eventSymbol: String { symbol(for: event.kind) }
    private var eventColor: Color { childColor(for: event.kind) }

    private func symbol(for kind: ActivityEventKind) -> String {
        switch kind {
        case .importBatch:     return "square.and.arrow.down.fill"
        case .frameExtraction: return "film.fill"
        case .adjustment:      return "slider.horizontal.3"
        case .colorGrade:      return "paintpalette.fill"
        case .printAttempt:    return "printer.fill"
        case .batchTransform:  return "arrow.triangle.2.circlepath"
        case .reAdjustment:    return "arrow.counterclockwise"
        case .note:            return "text.bubble.fill"
        case .todo:            return "checklist"
        case .rollback:           return "clock.arrow.circlepath"
        case .pipelineRun:        return "gearshape.2.fill"
        case .editorialReview:    return "text.bubble.fill"
        case .faceDetection:      return "person.crop.circle"
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

    private func childColor(for kind: ActivityEventKind) -> Color {
        switch kind {
        case .importBatch:        return .indigo
        case .frameExtraction:    return .orange
        case .adjustment:         return .blue
        case .colorGrade:         return .purple
        case .printAttempt:       return .green
        case .batchTransform:     return .teal
        case .reAdjustment:       return .gray
        case .note:               return .yellow
        case .todo:               return .pink
        case .rollback:           return .red
        case .pipelineRun:        return .mint
        case .editorialReview:    return .purple
        case .faceDetection:      return .teal
        case .metadataEnrichment: return .blue
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

// MARK: - ActivityEventKind display name extension

private extension ActivityEventKind {
    var displayName: String {
        switch self {
        case .importBatch:        return "Import Batch"
        case .frameExtraction:    return "Frame Extraction"
        case .adjustment:         return "Adjustment"
        case .colorGrade:         return "Color Grade"
        case .printAttempt:       return "Print Attempt"
        case .batchTransform:     return "Batch Transform"
        case .reAdjustment:       return "Re-Adjustment"
        case .note:               return "Note"
        case .todo:               return "To-Do"
        case .rollback:           return "Rollback"
        case .pipelineRun:        return "Pipeline Run"
        case .editorialReview:    return "Editorial Review"
        case .faceDetection:      return "Face Detection"
        case .metadataEnrichment: return "Metadata Enrichment"
        case .printJob:           return "Print Job"
        case .scanAttachment:     return "Scan Attachment"
        case .aiSummary:          return "AI Summary"
        case .search:             return "Search"
        case .studioRender:       return "Studio Render"
        case .studioVersion:      return "Studio Version"
        case .studioExport:       return "Studio Export"
        case .studioPrintLab:     return "Studio → Print Lab"
        case .jobCreated:         return "Job Created"
        case .jobCompleted:       return "Job Completed"
        case .jobSplit:           return "Job Split"
        case .curveLinearized:    return "Curve Linearized"
        case .curveSaved:         return "Curve Saved"
        case .curveBlended:       return "Curve Blended"
        case .versionCreated:     return "Version Created"
        }
    }
}

// MARK: - Preview

#Preview("EventDetailView") {
    Text("EventDetailView requires ActivityFeedViewModel.\nUse in context.")
        .foregroundStyle(.secondary)
        .padding()
}
