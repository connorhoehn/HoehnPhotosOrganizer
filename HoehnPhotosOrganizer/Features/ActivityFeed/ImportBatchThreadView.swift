import SwiftUI

// MARK: - TimelineItem (collapsed timeline model)

/// Represents either a single event or a group of collapsed frame extractions.
private enum TimelineItem {
    case single(ActivityEvent)
    case extractionGroup(Int, ActivityEvent) // (count, sample event)
}

// MARK: - ImportBatchThreadView

/// GitHub-issue-style threaded view for an import batch event.
///
/// Shows a mosaic header, photo grid with selection + curation badges,
/// a vertical timeline of child events with author labels and connector lines,
/// collapsible quick-metadata panel, and a comment bar.
struct ImportBatchThreadView: View {

    let event: ActivityEvent
    let children: [ActivityEvent]
    let photos: [PhotoAsset]

    var onSendToWorkflow: (([String]) -> Void)?
    var onAddNote: ((String) -> Void)?
    /// Callback: (targetPhotoIDs, location, gear, tags) — applies quick metadata to selected or all photos.
    var onApplyMetadata: (([String], String, String, String) -> Void)?
    /// Navigate to Jobs tab, optionally selecting the specific job.
    var onOpenInJobs: ((String?) -> Void)?

    @State private var selectedPhotoIDs: Set<String> = []
    @State private var newComment = ""
    @State private var hoveredPhotoID: String?
    @State private var showMetadataPanel = false

    // Quick metadata fields
    @State private var metaLocation = ""
    @State private var metaGear = ""
    @State private var metaTags = ""

    private let gridColumns = [
        GridItem(.adaptive(minimum: 130, maximum: 200), spacing: 6)
    ]

    var body: some View {
        VStack(spacing: 0) {
            batchHeader
            Divider()

            if showMetadataPanel {
                quickMetadataPanel
                Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !photos.isEmpty {
                        statsBar
                            .padding(.horizontal, 20)
                            .padding(.top, 16)
                            .padding(.bottom, 12)

                        photoGrid
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)
                    }

                    if !children.isEmpty {
                        Divider()
                            .padding(.horizontal, 20)

                        timelineSection
                            .padding(.vertical, 12)
                    }

                    if children.isEmpty && photos.isEmpty {
                        emptyState
                    }
                }
            }

            Divider()
            commentBar
        }
    }

    // MARK: - Header

    private var batchHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            // Mosaic thumbnail stack
            mosaicPreview
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(event.title)
                    .font(.system(size: 17, weight: .bold))

                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                // Metadata pills
                HStack(spacing: 6) {
                    pill("\(photos.count) photos", color: .indigo)

                    if let driveName = decodeDriveName() {
                        pill(driveName, color: .teal)
                    }

                    let fileTypes = Set(photos.map { ($0.canonicalName as NSString).pathExtension.uppercased() })
                    ForEach(Array(fileTypes.prefix(3)), id: \.self) { ext in
                        pill(ext, color: .gray)
                    }
                }

                if let jobId = decodeJobId() {
                    Button {
                        onOpenInJobs?(jobId)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "checklist")
                            Text("Open Triage Job")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(event.occurredAt, format: .dateTime.month().day().year().hour().minute())
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Text("·")
                        .foregroundStyle(.quaternary)
                    Text("\(children.count) update\(children.count == 1 ? "" : "s")")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Action buttons
            VStack(alignment: .trailing, spacing: 8) {
                if selectedPhotoIDs.isEmpty {
                    Button {
                        onSendToWorkflow?(photos.map(\.id))
                    } label: {
                        Label("Send All to Workflow", systemImage: "arrow.right.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(photos.isEmpty)
                } else {
                    Button {
                        onSendToWorkflow?(Array(selectedPhotoIDs))
                    } label: {
                        Label("Send \(selectedPhotoIDs.count) to Workflow", systemImage: "arrow.right.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showMetadataPanel.toggle()
                    }
                } label: {
                    Label("Quick Metadata", systemImage: "tag")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(20)
    }

    // MARK: - Mosaic Preview

    private var mosaicPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.indigo.opacity(0.06))

            if photos.count >= 4 {
                // 2x2 grid of thumbnails
                let first4 = Array(photos.prefix(4))
                VStack(spacing: 1) {
                    HStack(spacing: 1) {
                        proxyThumbnail(for: first4[0]).frame(maxWidth: .infinity, maxHeight: .infinity)
                        proxyThumbnail(for: first4[1]).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    HStack(spacing: 1) {
                        proxyThumbnail(for: first4[2]).frame(maxWidth: .infinity, maxHeight: .infinity)
                        proxyThumbnail(for: first4[3]).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else if let first = photos.first {
                proxyThumbnail(for: first)
            } else {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.indigo.opacity(0.4))
            }
        }
    }

    @ViewBuilder
    private func proxyThumbnail(for photo: PhotoAsset) -> some View {
        let baseName = (photo.canonicalName as NSString).deletingPathExtension
        let proxyURL = ProxyGenerationActor.proxiesDirectory()
            .appendingPathComponent(baseName + ".jpg")
        AsyncImage(url: proxyURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(Color(nsColor: .separatorColor))
        }
        .clipped()
    }

    // MARK: - Stats Bar

    private var keeperCount: Int {
        photos.filter { $0.curationState == CurationState.keeper.rawValue }.count
    }
    private var archiveCount: Int {
        photos.filter { $0.curationState == CurationState.archive.rawValue }.count
    }
    private var reviewCount: Int {
        photos.filter { $0.curationState == CurationState.needsReview.rawValue }.count
    }

    private var statsBar: some View {
        HStack(spacing: 16) {
            Text("Photos")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer()

            if keeperCount > 0 { statBadge(count: keeperCount, label: "Keeper", color: .green) }
            if archiveCount > 0 { statBadge(count: archiveCount, label: "Archive", color: .blue) }
            if reviewCount > 0 { statBadge(count: reviewCount, label: "Review", color: .orange) }

            selectionControls
        }
    }

    @ViewBuilder
    private var selectionControls: some View {
        if !selectedPhotoIDs.isEmpty {
            Divider().frame(height: 16)
            Button {
                selectedPhotoIDs.removeAll()
            } label: {
                HStack(spacing: 4) {
                    Text("\(selectedPhotoIDs.count) selected")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        } else if photos.count > 1 {
            Divider().frame(height: 16)
            Button("Select All") {
                selectedPhotoIDs = Set(photos.map(\.id))
            }
            .font(.system(size: 11, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private func statBadge(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(count)")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Photo Grid

    private var photoGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 6) {
            ForEach(photos) { photo in
                ImportBatchPhotoCell(
                    photo: photo,
                    isSelected: selectedPhotoIDs.contains(photo.id),
                    isHovered: hoveredPhotoID == photo.id,
                    onToggle: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            if selectedPhotoIDs.contains(photo.id) {
                                selectedPhotoIDs.remove(photo.id)
                            } else {
                                selectedPhotoIDs.insert(photo.id)
                            }
                        }
                    },
                    onHover: { hovering in
                        hoveredPhotoID = hovering ? photo.id : nil
                    }
                )
            }
        }
    }

    // MARK: - Timeline

    private var timelineSection: some View {
        let collapsed = collapsedTimeline
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(collapsed.enumerated()), id: \.offset) { index, item in
                switch item {
                case .single(let child):
                    threadEntry(child)
                case .extractionGroup(let count, let first):
                    extractionGroupRow(count: count, sample: first)
                }
                if index < collapsed.count - 1 {
                    timelineConnector
                }
            }
        }
    }

    /// Collapse consecutive frameExtraction events into a single summary row.
    private var collapsedTimeline: [TimelineItem] {
        var result: [TimelineItem] = []
        var extractionBuffer: [ActivityEvent] = []

        func flushExtractions() {
            guard !extractionBuffer.isEmpty else { return }
            if extractionBuffer.count <= 2 {
                for e in extractionBuffer { result.append(.single(e)) }
            } else {
                result.append(.extractionGroup(extractionBuffer.count, extractionBuffer[0]))
            }
            extractionBuffer.removeAll()
        }

        for child in children {
            if child.kind == .frameExtraction {
                extractionBuffer.append(child)
            } else {
                flushExtractions()
                result.append(.single(child))
            }
        }
        flushExtractions()
        return result
    }

    private func extractionGroupRow(count: Int, sample: ActivityEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: "film.stack.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("System")
                        .font(.system(size: 12, weight: .bold))
                    Text("extracted \(count) frames")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(sample.occurredAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                // Mini filmstrip preview
                let previewPhotos = children
                    .filter { $0.kind == .frameExtraction && $0.photoAssetId != nil }
                    .prefix(6)
                    .compactMap { event in photos.first(where: { $0.id == event.photoAssetId }) }

                if !previewPhotos.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(previewPhotos, id: \.id) { photo in
                            proxyThumbnail(for: photo)
                                .frame(width: 36, height: 24)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        if count > 6 {
                            Text("+\(count - 6)")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color(nsColor: .separatorColor).opacity(0.2))
                                )
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func threadEntry(_ child: ActivityEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Timeline dot
            ZStack {
                Circle()
                    .fill(colorFor(child.kind).opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: symbolFor(child.kind))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(colorFor(child.kind))
            }

            // Content
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(authorLabel(child))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.primary)

                    Text(actionLabel(child))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Spacer()

                    if let device = deviceOrigin(for: child) {
                        Image(systemName: deviceSymbol(for: device))
                            .font(.system(size: 9))
                            .foregroundStyle(.teal)
                    }
                    Text(child.occurredAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                // Content cards per kind
                switch child.kind {
                case .note:
                    if let detail = child.detail {
                        Text(detail)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                            )
                    }

                case .frameExtraction:
                    frameExtractionCard(child)

                case .metadataEnrichment:
                    metadataCard(child)

                case .scanAttachment:
                    scanAttachmentCard(child)

                default:
                    if let detail = child.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    // MARK: - Event-Specific Cards

    private func frameExtractionCard(_ event: ActivityEvent) -> some View {
        HStack(spacing: 10) {
            // Small proxy thumbnail if available
            if let photoId = event.photoAssetId, let photo = photos.first(where: { $0.id == photoId }) {
                proxyThumbnail(for: photo)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 12, weight: .medium))
                if let detail = event.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.04))
                .stroke(Color.orange.opacity(0.12), lineWidth: 1)
        )
    }

    private func metadataCard(_ event: ActivityEvent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "tag.fill")
                .font(.system(size: 14))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 12, weight: .medium))
                if let detail = event.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.blue.opacity(0.04))
                .stroke(Color.blue.opacity(0.12), lineWidth: 1)
        )
    }

    private func scanAttachmentCard(_ event: ActivityEvent) -> some View {
        HStack(spacing: 10) {
            // Scan preview placeholder
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.teal.opacity(0.08))
                    .frame(width: 48, height: 48)
                Image(systemName: "doc.viewfinder.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.teal)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.system(size: 12, weight: .medium))
                if let detail = event.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let device = deviceOrigin(for: event) {
                    HStack(spacing: 3) {
                        Image(systemName: deviceSymbol(for: device))
                            .font(.system(size: 9))
                        Text("Scanned via \(device)")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.teal)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.teal.opacity(0.04))
                .stroke(Color.teal.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - Timeline Connector

    private var timelineConnector: some View {
        HStack {
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 2, height: 16)
                .padding(.leading, 35) // align with center of 32pt dot at 20pt padding
            Spacer()
        }
    }

    // MARK: - Quick Metadata Panel

    private var quickMetadataPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "tag.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.indigo)
                Text("Quick Metadata")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.indigo)
                Text("—")
                    .foregroundStyle(.quaternary)
                Text(selectedPhotoIDs.isEmpty ? "Applies to all \(photos.count) photos" : "Applies to \(selectedPhotoIDs.count) selected")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                metadataField(icon: "location.fill", placeholder: "Location", text: $metaLocation)
                metadataField(icon: "camera.fill", placeholder: "Camera / Lens", text: $metaGear)
                metadataField(icon: "tag", placeholder: "Tags (comma-separated)", text: $metaTags)

                Button {
                    let targetIDs = selectedPhotoIDs.isEmpty ? photos.map(\.id) : Array(selectedPhotoIDs)
                    onApplyMetadata?(targetIDs, metaLocation, metaGear, metaTags)
                    // Reset fields after applying
                    metaLocation = ""
                    metaGear = ""
                    metaTags = ""
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showMetadataPanel = false
                    }
                } label: {
                    Label("Apply", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .controlSize(.small)
                .disabled(metaLocation.isEmpty && metaGear.isEmpty && metaTags.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.indigo.opacity(0.03))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func metadataField(icon: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                )
        }
    }

    // MARK: - Comment Bar

    private var commentBar: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.indigo.opacity(0.12))
                    .frame(width: 28, height: 28)
                Text("C")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.indigo)
            }

            TextField("Add a note...", text: $newComment, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .onSubmit {
                    submitNote()
                }

            Button {
                submitNote()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(
                        newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.secondary : Color.accentColor
                    )
            }
            .buttonStyle(.plain)
            .disabled(newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 28))
                .foregroundStyle(.quaternary)
            Text("Loading batch...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Helpers

    private func submitNote() {
        let body = newComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        newComment = ""
        onAddNote?(body)
    }

    private func decodeDriveName() -> String? {
        guard let json = event.metadata,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = dict["driveName"] as? String else { return nil }
        return name
    }

    private func decodeJobId() -> String? {
        guard let json = event.metadata,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jobId = dict["job_id"] as? String else { return nil }
        return jobId
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
            .foregroundStyle(color)
    }

    private func authorLabel(_ event: ActivityEvent) -> String {
        let device = deviceOrigin(for: event)
        let suffix = device.map { " (\($0))" } ?? ""
        switch event.kind {
        case .note:               return "Connor" + suffix
        case .scanAttachment:     return "Connor" + suffix
        case .frameExtraction:    return "System"
        case .metadataEnrichment: return "System" + suffix
        case .aiSummary:          return "AI Assistant"
        default:                  return "System"
        }
    }

    private func actionLabel(_ event: ActivityEvent) -> String {
        switch event.kind {
        case .note:              return "commented"
        case .frameExtraction:   return "extracted a frame"
        case .metadataEnrichment: return "enriched metadata"
        case .aiSummary:         return "analyzed the batch"
        case .importBatch:       return "started import"
        default:                 return "updated"
        }
    }

    private func symbolFor(_ kind: ActivityEventKind) -> String {
        switch kind {
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

    private func colorFor(_ kind: ActivityEventKind) -> Color {
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

// MARK: - ImportBatchPhotoCell

/// Grid cell with proxy thumbnail, hover filename overlay, curation badge, and selection ring.
private struct ImportBatchPhotoCell: View {
    let photo: PhotoAsset
    let isSelected: Bool
    let isHovered: Bool
    let onToggle: () -> Void
    let onHover: (Bool) -> Void

    private var proxyURL: URL {
        let baseName = (photo.canonicalName as NSString).deletingPathExtension
        return ProxyGenerationActor.proxiesDirectory()
            .appendingPathComponent(baseName + ".jpg")
    }

    private var curationColor: Color? {
        switch photo.curationState {
        case CurationState.keeper.rawValue:      return .green
        case CurationState.archive.rawValue:     return .blue
        case CurationState.rejected.rawValue:    return .red
        default:                                 return nil
        }
    }

    var body: some View {
        Button(action: onToggle) {
            ZStack(alignment: .topTrailing) {
                // Thumbnail
                AsyncImage(url: proxyURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor).opacity(0.3))
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: 18))
                                .foregroundStyle(.quaternary)
                        }
                }
                .frame(height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                // Filename overlay on hover
                if isHovered {
                    VStack {
                        Spacer()
                        Text(photo.canonicalName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity)
                            .background(
                                UnevenRoundedRectangle(
                                    topLeadingRadius: 0, bottomLeadingRadius: 6,
                                    bottomTrailingRadius: 6, topTrailingRadius: 0
                                )
                                .fill(.black.opacity(0.6))
                            )
                    }
                }

                // Badges
                HStack(spacing: 4) {
                    // Curation state dot
                    if let color = curationColor {
                        Circle()
                            .fill(color)
                            .frame(width: 8, height: 8)
                            .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                    }

                    // Selection checkmark
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    }
                }
                .padding(5)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isSelected ? Color.accentColor :
                            (isHovered ? Color.secondary.opacity(0.4) : Color.clear),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .shadow(
                color: isHovered ? Color.black.opacity(0.08) : .clear,
                radius: isHovered ? 4 : 0,
                y: isHovered ? 2 : 0
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in onHover(hovering) }
    }
}

// MARK: - Preview

#Preview("ImportBatchThreadView — Cross-Device Sync") {
    let root = ActivityEvent(
        id: "batch-1",
        kind: .importBatch,
        parentEventId: nil,
        photoAssetId: nil,
        title: "Imported Kodak Portra 400 roll",
        detail: "24 files imported from NIKON_D850",
        metadata: "{\"driveName\":\"NIKON_D850\"}",
        occurredAt: Date(timeIntervalSinceNow: -7200),
        createdAt: Date()
    )
    let children: [ActivityEvent] = [
        // Desktop system: frame extractions
        ActivityEvent(
            id: "child-1", kind: .frameExtraction, parentEventId: "batch-1",
            photoAssetId: "photo-1",
            title: "Extracted IMG_0001.dng", detail: "4912 x 3264, 14-bit RAW",
            metadata: nil,
            occurredAt: Date(timeIntervalSinceNow: -7100), createdAt: Date()
        ),
        ActivityEvent(
            id: "child-2", kind: .frameExtraction, parentEventId: "batch-1",
            photoAssetId: "photo-2",
            title: "Extracted IMG_0002.dng", detail: "4912 x 3264, 14-bit RAW",
            metadata: nil,
            occurredAt: Date(timeIntervalSinceNow: -7090), createdAt: Date()
        ),
        ActivityEvent(
            id: "child-3", kind: .frameExtraction, parentEventId: "batch-1",
            photoAssetId: "photo-3",
            title: "Extracted IMG_0003.dng", detail: "4912 x 3264, 14-bit RAW",
            metadata: nil,
            occurredAt: Date(timeIntervalSinceNow: -7080), createdAt: Date()
        ),
        ActivityEvent(
            id: "child-4", kind: .frameExtraction, parentEventId: "batch-1",
            photoAssetId: "photo-4",
            title: "Extracted IMG_0004.dng", detail: "4912 x 3264, 14-bit RAW",
            metadata: nil,
            occurredAt: Date(timeIntervalSinceNow: -7070), createdAt: Date()
        ),

        // Desktop system: metadata enrichment
        ActivityEvent(
            id: "child-5", kind: .metadataEnrichment, parentEventId: "batch-1",
            photoAssetId: "photo-1",
            title: "Metadata enriched", detail: "location, keywords, scene classification",
            metadata: nil,
            occurredAt: Date(timeIntervalSinceNow: -6000), createdAt: Date()
        ),

        // Mobile: Connor reviews from phone and leaves a note
        ActivityEvent(
            id: "child-6", kind: .note, parentEventId: "batch-1",
            photoAssetId: nil,
            title: "Connor commented",
            detail: "The harbor shots at golden hour are stunning — IMG_0012 is a definite print candidate. Hahnemühle Photo Rag would work perfectly.",
            metadata: "{\"device\":\"iPhone\"}",
            occurredAt: Date(timeIntervalSinceNow: -3600), createdAt: Date()
        ),

        // Mobile: scan attached from phone
        ActivityEvent(
            id: "child-7", kind: .scanAttachment, parentEventId: "batch-1",
            photoAssetId: "photo-12",
            title: "Scan: Harbor_Print_Test.jpg",
            detail: "Test print scanned from Epson SC-P700",
            metadata: "{\"device\":\"iPhone\",\"scanSource\":\"camera\"}",
            occurredAt: Date(timeIntervalSinceNow: -1800), createdAt: Date()
        ),

        // Mobile: feedback on the test print
        ActivityEvent(
            id: "child-8", kind: .note, parentEventId: "batch-1",
            photoAssetId: nil,
            title: "Connor commented",
            detail: "Print is slightly warm — need to pull magenta 5-10%. Shadow detail holds well on the Rag paper though. Try a second pass.",
            metadata: "{\"device\":\"iPhone\"}",
            occurredAt: Date(timeIntervalSinceNow: -1500), createdAt: Date()
        ),

        // Desktop: AI analysis responds
        ActivityEvent(
            id: "child-9", kind: .aiSummary, parentEventId: "batch-1",
            photoAssetId: nil,
            title: "AI analyzed batch",
            detail: "12 keepers identified across harbor series. Recommend reducing magenta by 8% for Hahnemühle Photo Rag 308gsm. Suggested brightness center: 0.52, range: 0.85.",
            metadata: nil,
            occurredAt: Date(timeIntervalSinceNow: -1200), createdAt: Date()
        ),

        // iPad: curation follow-up
        ActivityEvent(
            id: "child-10", kind: .note, parentEventId: "batch-1",
            photoAssetId: nil,
            title: "Connor commented",
            detail: "Reviewed full roll on iPad — marked 4 more keepers from the dock series (IMG_0018-0021). Strong portfolio candidates.",
            metadata: "{\"device\":\"iPad\"}",
            occurredAt: Date(timeIntervalSinceNow: -300), createdAt: Date()
        ),
    ]
    NavigationStack {
        ImportBatchThreadView(
            event: root,
            children: children,
            photos: []
        )
        .frame(width: 750, height: 700)
    }
}
