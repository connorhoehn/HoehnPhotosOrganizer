import SwiftUI
import HoehnPhotosCore

struct MobileEventDetailView: View {

    let event: ActivityEvent
    @Environment(\.dismiss) private var dismiss
    @State private var thumbnail: UIImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // MARK: Header with icon + title
                    headerSection

                    // MARK: Photo thumbnail (if event has photoAssetId)
                    if let img = thumbnail {
                        photoSection(img)
                    }

                    // MARK: Detail text
                    if let detail = event.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.body)
                            .foregroundStyle(.primary)
                    }

                    // MARK: Metadata table
                    if let metadata = parseMetadata(), !metadata.isEmpty {
                        metadataSection(metadata)
                    }

                    // MARK: Timestamps
                    timestampSection
                }
                .padding()
            }
            .navigationTitle("Event Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadThumbnail() }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 48, height: 48)
                Image(systemName: sfSymbol(for: event.kind))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.headline)
                Text(event.kind.filterLabel.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }

            Spacer()
        }
    }

    // MARK: - Photo

    @ViewBuilder
    private func photoSection(_ img: UIImage) -> some View {
        Image(uiImage: img)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxHeight: 240)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
            )
    }

    // MARK: - Metadata

    @ViewBuilder
    private func metadataSection(_ json: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(json.keys.sorted(), id: \.self) { key in
                if let value = json[key] {
                    HStack(alignment: .top) {
                        Text(key.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .trailing)
                        Text(stringValue(value))
                            .font(.caption)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    // MARK: - Timestamps

    private var timestampSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(event.occurredAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(event.occurredAt, format: .dateTime.month().day().year().hour().minute())
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Helpers

    private func sfSymbol(for kind: ActivityEventKind) -> String {
        switch kind {
        case .importBatch:        return "square.and.arrow.down"
        case .frameExtraction:    return "film.stack"
        case .adjustment:         return "slider.horizontal.3"
        case .colorGrade:         return "paintpalette"
        case .printAttempt:       return "printer"
        case .batchTransform:     return "wand.and.stars"
        case .reAdjustment:       return "arrow.uturn.backward"
        case .note:               return "note.text"
        case .todo:               return "checklist"
        case .rollback:           return "arrow.uturn.backward.circle"
        case .pipelineRun:        return "gearshape.2"
        case .editorialReview:    return "text.bubble"
        case .faceDetection:      return "person.crop.rectangle"
        case .metadataEnrichment: return "tag"
        case .printJob:           return "printer.fill"
        case .scanAttachment:     return "doc.viewfinder"
        case .aiSummary:          return "brain"
        case .search:             return "magnifyingglass"
        }
    }

    private func parseMetadata() -> [String: Any]? {
        guard let metadata = event.metadata, !metadata.isEmpty,
              let data = metadata.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    private func stringValue(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let a = value as? [Any] { return a.map { "\($0)" }.joined(separator: ", ") }
        return "\(value)"
    }

    // MARK: - Thumbnail loading

    private func loadThumbnail() async {
        guard let _ = event.photoAssetId else { return }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let proxyDir = appSupport
            .appendingPathComponent("HoehnPhotos")
            .appendingPathComponent("proxies")

        // Try metadata first for canonical_name
        var canonicalName: String? = nil
        if let meta = parseMetadata(), let name = meta["canonical_name"] as? String {
            canonicalName = name
        }

        if let name = canonicalName {
            let baseName = (name as NSString).deletingPathExtension
            let url = proxyDir.appendingPathComponent(baseName + ".jpg")
            let loadedImage = await Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: url) else { return nil as UIImage? }
                return UIImage(data: data)
            }.value
            if let img = loadedImage {
                thumbnail = img
            }
        }
    }
}
