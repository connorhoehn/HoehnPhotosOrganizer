import SwiftUI

// MARK: - ActivityThreadCard

/// Root card component for the activity feed. Displays an event with icon badge,
/// title, detail, timestamp, and a navigation chevron. Tapping navigates to detail.
struct ActivityThreadCard: View {
    let event: ActivityEvent
    let children: [ActivityEvent]?
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onTap: () -> Void
    /// Optional proxy thumbnail URL for the event's associated photo.
    /// When provided and the file exists on disk, a thumbnail replaces the icon badge.
    var proxyURL: URL? = nil
    /// Optional proxy URL resolver for child events (used for import batch mosaic).
    var childProxyURLResolver: ((String?) -> URL?)? = nil

    @State private var isHovered: Bool = false
    @State private var isPinButtonHovered: Bool = false
    @State private var thumbnailImage: NSImage?
    @State private var mosaicImages: [NSImage] = []

    // Holding a @State reference to the @Observable singleton ensures the body
    // is re-evaluated when pinnedIds changes.
    @State private var pinnedStore = PinnedNotesStore.shared

    private var isPinned: Bool {
        pinnedStore.isPinned(eventId: event.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card row — whole card is tap target
            Button(action: onTap) {
                HStack(alignment: .top, spacing: 12) {
                    // Badge area: thumbnail, import mosaic, or icon fallback
                    badgeView

                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        if let detail = event.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        // Child count badge
                        if let childList = children, !childList.isEmpty {
                            Text("\(childList.count) item\(childList.count == 1 ? "" : "s")")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(eventColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(eventColor.opacity(0.1)))
                        }
                    }

                    Spacer(minLength: 4)

                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 4) {
                            if let device = deviceOrigin(for: event) {
                                Image(systemName: deviceSymbol(for: device))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.teal)
                                Text("via \(device)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.teal)
                                Text("·")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.quaternary)
                            }
                            // Auto-refreshes every 60 s so relative labels stay accurate.
                            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                                Text(event.occurredAt.relativeVerbose(now: ctx.date))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }

                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Filmstrip preview for import batches
            if event.kind == .importBatch, let childList = children, !childList.isEmpty {
                importBatchFilmstrip(children: childList)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            if let accentColor = threadAccentColor {
                UnevenRoundedRectangle(
                    topLeadingRadius: 10, bottomLeadingRadius: 10,
                    bottomTrailingRadius: 0, topTrailingRadius: 0
                )
                .fill(accentColor)
                .frame(width: 3)
            }
        }
        .overlay(alignment: .topTrailing) {
            if event.kind == .note {
                pinButton
                    .padding(6)
            }
        }
        .shadow(
            color: isHovered ? Color.black.opacity(0.12) : Color.black.opacity(0.05),
            radius: isHovered ? 6 : 3,
            x: 0,
            y: isHovered ? 3 : 1
        )
        .onHover { hovering in isHovered = hovering }
        .task { await loadThumbnails() }
    }

    // MARK: - Badge view (thumbnail or icon)

    @ViewBuilder
    private var badgeView: some View {
        if event.kind == .importBatch, !mosaicImages.isEmpty {
            // 2x2 mosaic for import batches
            importMosaicBadge
        } else if let img = thumbnailImage {
            // Single photo thumbnail
            Image(nsImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(eventColor.opacity(0.3), lineWidth: 1)
                )
        } else {
            // Default icon badge
            ZStack {
                Circle()
                    .fill(eventColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: eventSymbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(eventColor)
            }
        }
    }

    /// 2x2 grid of tiny thumbnails for import batch events.
    private var importMosaicBadge: some View {
        let grid = Array(mosaicImages.prefix(4))
        return VStack(spacing: 2) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(0..<2, id: \.self) { col in
                        let idx = row * 2 + col
                        if idx < grid.count {
                            Image(nsImage: grid[idx])
                                .resizable()
                                .scaledToFill()
                                .frame(width: 19, height: 19)
                                .clipped()
                        } else {
                            Rectangle()
                                .fill(Color(nsColor: .separatorColor).opacity(0.3))
                                .frame(width: 19, height: 19)
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(eventColor.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Thumbnail loading

    private func loadThumbnails() async {
        if event.kind == .importBatch {
            await loadMosaicThumbnails()
        } else if let url = proxyURL {
            thumbnailImage = await loadImageFromDisk(url: url)
        }
    }

    /// Loads up to 4 child photo thumbnails for the import batch mosaic.
    private func loadMosaicThumbnails() async {
        guard let childList = children else { return }
        let photoChildren = childList
            .filter { $0.kind == .frameExtraction && $0.photoAssetId != nil }
            .prefix(4)
        guard !photoChildren.isEmpty else { return }

        // Try resolver first (from view model's cache), fall back to title-based extraction
        var images: [NSImage] = []
        for child in photoChildren {
            var url: URL?
            if let resolver = childProxyURLResolver {
                url = resolver(child.photoAssetId)
            }
            if url == nil {
                // Fall back to extracting canonical name from the event title
                let filename = child.title
                    .replacingOccurrences(of: "Extracted ", with: "")
                    .replacingOccurrences(of: "Imported ", with: "")
                let baseName = (filename as NSString).deletingPathExtension
                url = ProxyGenerationActor.proxiesDirectory()
                    .appendingPathComponent(baseName + ".jpg")
            }
            if let url, let img = await loadImageFromDisk(url: url) {
                images.append(img)
            }
            if images.count >= 4 { break }
        }
        if !images.isEmpty {
            mosaicImages = images
        }
    }

    /// Asynchronously loads an NSImage from a file URL on a background thread.
    private func loadImageFromDisk(url: URL) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return await Task.detached(priority: .utility) {
            NSImage(contentsOf: url)
        }.value
    }

    // MARK: - Import batch filmstrip

    @ViewBuilder
    private func importBatchFilmstrip(children: [ActivityEvent]) -> some View {
        let photoChildren = children.filter { $0.kind == .frameExtraction && $0.photoAssetId != nil }
        let previewChildren = Array(photoChildren.prefix(5))
        if !previewChildren.isEmpty {
            HStack(spacing: 0) {
                // Overlapping thumbnail stack
                ZStack(alignment: .leading) {
                    ForEach(Array(previewChildren.enumerated()), id: \.element.id) { index, child in
                        filmstripThumb(canonicalHint: child.title)
                            .offset(x: CGFloat(index) * 30)
                            .zIndex(Double(previewChildren.count - index))
                    }
                }
                .frame(height: 32)
                .padding(.trailing, CGFloat(previewChildren.count - 1) * 30)

                // Count capsule
                if photoChildren.count > 0 {
                    Text("\(photoChildren.count) photos")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.indigo)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.indigo.opacity(0.1)))
                        .padding(.leading, 8)
                }

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }

    /// Renders a small proxy thumbnail with border. Extracts the base filename from
    /// the child event title (e.g. "Extracted frame_01.dng" -> "frame_01").
    private func filmstripThumb(canonicalHint: String) -> some View {
        let filename = canonicalHint
            .replacingOccurrences(of: "Extracted ", with: "")
            .replacingOccurrences(of: "Imported ", with: "")
        let baseName = (filename as NSString).deletingPathExtension
        let proxyURL = ProxyGenerationActor.proxiesDirectory()
            .appendingPathComponent(baseName + ".jpg")

        return AsyncImage(url: proxyURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.5))
        }
        .frame(width: 40, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color(nsColor: .controlBackgroundColor), lineWidth: 2)
        )
        .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
    }

    // MARK: - Pin button (notes only)

    private var pinButton: some View {
        Button {
            PinnedNotesStore.shared.toggle(eventId: event.id)
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isPinned ? Color.orange : (isPinButtonHovered ? Color.primary : Color.secondary.opacity(0.5)))
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(isPinButtonHovered || isPinned
                              ? Color(nsColor: .controlBackgroundColor).opacity(0.9)
                              : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(isPinned ? "Unpin note" : "Pin note to top")
        .onHover { hovering in isPinButtonHovered = hovering }
        .animation(.easeInOut(duration: 0.12), value: isPinned)
        .animation(.easeInOut(duration: 0.12), value: isPinButtonHovered)
    }

    // MARK: - Thread accent (left bar color for threaded event kinds)

    private var threadAccentColor: Color? {
        switch event.kind {
        case .importBatch: return .indigo
        case .printJob:    return .green
        default:           return nil
        }
    }

    // MARK: - Icon/color resolution

    var eventSymbol: String {
        switch event.kind {
        case .importBatch:     return "square.and.arrow.down.fill"
        case .frameExtraction: return "film.fill"
        case .adjustment:      return "slider.horizontal.3"
        case .colorGrade:      return "paintpalette.fill"
        case .printAttempt:    return "printer.fill"
        case .batchTransform:  return "arrow.triangle.2.circlepath"
        case .reAdjustment:    return "arrow.counterclockwise"
        case .note:            return "text.bubble.fill"
        case .todo:            return "checklist"
        case .rollback:          return "clock.arrow.circlepath"
        case .pipelineRun:       return "gearshape.2.fill"
        case .editorialReview:   return "text.bubble.fill"
        case .faceDetection:     return "person.crop.circle"
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

    var eventColor: Color {
        switch event.kind {
        case .importBatch:       return .indigo
        case .frameExtraction:   return .orange
        case .adjustment:        return .blue
        case .colorGrade:        return .purple
        case .printAttempt:      return .green
        case .batchTransform:    return .teal
        case .reAdjustment:      return .gray
        case .note:              return .yellow
        case .todo:              return .pink
        case .rollback:          return .red
        case .pipelineRun:       return .mint
        case .editorialReview:   return .purple
        case .faceDetection:     return .teal
        case .metadataEnrichment: return .blue
        case .printJob:          return .green
        case .scanAttachment:    return .orange
        case .aiSummary:         return .purple
        case .search:            return .blue
        case .studioRender:      return .purple
        case .studioVersion:     return .purple
        case .studioExport:      return .purple
        case .studioPrintLab:    return .purple
        case .jobCreated:        return .cyan
        case .jobCompleted:      return .green
        case .jobSplit:          return .cyan
        case .curveLinearized:   return .purple
        case .curveSaved:        return .green
        case .curveBlended:      return .orange
        case .versionCreated:    return .blue
        }
    }
}

// MARK: - Device origin helper

/// Extracts `"device"` from an ActivityEvent's metadata JSON (e.g. "iPhone", "iPad").
/// Returns nil for desktop-originated events (no device field).
func deviceOrigin(for event: ActivityEvent) -> String? {
    guard let json = event.metadata,
          let data = json.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let device = dict["device"] as? String else { return nil }
    return device
}

/// SF Symbol for a device name — iPhone, iPad, or generic device.
func deviceSymbol(for device: String) -> String {
    let lower = device.lowercased()
    if lower.contains("iphone") { return "iphone" }
    if lower.contains("ipad")   { return "ipad" }
    return "externaldrive.fill.badge.wifi"
}

// MARK: - Date extension for relative formatting

extension Date {
    /// Verbose relative string ("2 minutes ago", "Yesterday", "3 days ago").
    /// Falls back to absolute short date for events older than 7 days.
    func relativeVerbose(now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(self)
        guard seconds >= 0 else { return "just now" }

        switch seconds {
        case ..<60:
            return "just now"
        case ..<120:
            return "1 minute ago"
        case ..<3600:
            let mins = Int(seconds / 60)
            return "\(mins) minutes ago"
        case ..<7200:
            return "1 hour ago"
        case ..<86400:
            let hours = Int(seconds / 3600)
            return "\(hours) hours ago"
        case ..<(86400 * 2):
            return "Yesterday"
        case ..<(86400 * 7):
            let days = Int(seconds / 86400)
            return "\(days) days ago"
        default:
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: self)
        }
    }

    /// Compact relative string kept for backwards-compat ("2m", "3h", "4d").
    var relativeFormatted: String {
        let now = Date()
        let seconds = now.timeIntervalSince(self)
        switch seconds {
        case ..<60:
            return "now"
        case ..<3600:
            let mins = Int(seconds / 60)
            return "\(mins)m"
        case ..<86400:
            let hours = Int(seconds / 3600)
            return "\(hours)h"
        case ..<604800:
            let days = Int(seconds / 86400)
            return "\(days)d"
        default:
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .none
            return formatter.string(from: self)
        }
    }
}

// MARK: - Preview

#Preview("ActivityThreadCard — Cross-Device Sync") {
    // Simulate a realistic feed with mobile + desktop events interleaved
    let batchId = UUID().uuidString

    // 1. Desktop import batch
    let importBatch = ActivityEvent(
        id: batchId,
        kind: .importBatch,
        parentEventId: nil,
        photoAssetId: nil,
        title: "Imported Kodak Portra 400 roll",
        detail: "24 files from NIKON_D850",
        metadata: "{\"driveName\":\"NIKON_D850\"}",
        occurredAt: Date(timeIntervalSinceNow: -7200),
        createdAt: Date()
    )

    // Children: mix of desktop system + mobile user events
    let frameExtraction = ActivityEvent(
        id: UUID().uuidString,
        kind: .frameExtraction,
        parentEventId: batchId,
        photoAssetId: "photo-1",
        title: "Extracted IMG_0001.dng",
        detail: "4912 x 3264, 14-bit RAW",
        metadata: nil,
        occurredAt: Date(timeIntervalSinceNow: -7100),
        createdAt: Date()
    )

    // Mobile note from phone
    let mobileNote = ActivityEvent(
        id: UUID().uuidString,
        kind: .note,
        parentEventId: batchId,
        photoAssetId: nil,
        title: "Connor commented",
        detail: "The harbor shots at golden hour are stunning — definitely want to print IMG_0012 on Hahnemühle",
        metadata: "{\"device\":\"iPhone\"}",
        occurredAt: Date(timeIntervalSinceNow: -3600),
        createdAt: Date()
    )

    // AI response on desktop
    let aiSummary = ActivityEvent(
        id: UUID().uuidString,
        kind: .aiSummary,
        parentEventId: batchId,
        photoAssetId: nil,
        title: "AI analyzed batch",
        detail: "12 keepers identified. Strong golden-hour palette across harbor series. Recommend Hahnemühle Photo Rag 308gsm for IMG_0012.",
        metadata: nil,
        occurredAt: Date(timeIntervalSinceNow: -3500),
        createdAt: Date()
    )

    // 2. Mobile scan attachment — separate root event
    let scanEvent = ActivityEvent(
        id: UUID().uuidString,
        kind: .scanAttachment,
        parentEventId: nil,
        photoAssetId: "photo-12",
        title: "Scan attached: Harbor_Print_Test.jpg",
        detail: "Test print scanned from Epson SC-P700",
        metadata: "{\"device\":\"iPhone\",\"scanSource\":\"camera\"}",
        occurredAt: Date(timeIntervalSinceNow: -1800),
        createdAt: Date()
    )

    // 3. Mobile note — standalone review feedback
    let mobileFeedback = ActivityEvent(
        id: UUID().uuidString,
        kind: .note,
        parentEventId: nil,
        photoAssetId: nil,
        title: "Connor commented",
        detail: "Print looks slightly warm — need to pull magenta. Shadow detail is great though, the Rag paper holds it well.",
        metadata: "{\"device\":\"iPhone\"}",
        occurredAt: Date(timeIntervalSinceNow: -900),
        createdAt: Date()
    )

    // 4. Desktop metadata enrichment
    let metadataEvent = ActivityEvent(
        id: UUID().uuidString,
        kind: .metadataEnrichment,
        parentEventId: nil,
        photoAssetId: "photo-12",
        title: "Metadata applied to 6 photos",
        detail: "location: Monterey Harbor · tags: golden hour, seascape",
        metadata: nil,
        occurredAt: Date(timeIntervalSinceNow: -600),
        createdAt: Date()
    )

    // 5. Mobile curation note from iPad
    let ipadNote = ActivityEvent(
        id: UUID().uuidString,
        kind: .note,
        parentEventId: nil,
        photoAssetId: nil,
        title: "Connor commented",
        detail: "Reviewed the full roll on iPad — marked 4 more keepers from the dock series. IMG_0018-0021 are strong portfolio candidates.",
        metadata: "{\"device\":\"iPad\"}",
        occurredAt: Date(timeIntervalSinceNow: -300),
        createdAt: Date()
    )

    ScrollView {
        VStack(spacing: 10) {
            // Most recent first
            ActivityThreadCard(
                event: ipadNote,
                children: [],
                isExpanded: false,
                onToggleExpand: {},
                onTap: {}
            )

            ActivityThreadCard(
                event: metadataEvent,
                children: [],
                isExpanded: false,
                onToggleExpand: {},
                onTap: {}
            )

            ActivityThreadCard(
                event: mobileFeedback,
                children: [],
                isExpanded: false,
                onToggleExpand: {},
                onTap: {}
            )

            ActivityThreadCard(
                event: scanEvent,
                children: [],
                isExpanded: false,
                onToggleExpand: {},
                onTap: {}
            )

            ActivityThreadCard(
                event: importBatch,
                children: [frameExtraction, mobileNote, aiSummary],
                isExpanded: true,
                onToggleExpand: {},
                onTap: {}
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    .frame(width: 500, height: 700)
    .background(Color(nsColor: .windowBackgroundColor))
}
