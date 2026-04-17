import SwiftUI

// MARK: - CollapsibleInspectorSection

private struct CollapsibleInspectorSection<Content: View>: View {
    let title: String
    @AppStorage var isExpanded: Bool
    let content: Content
    let headerAction: (() -> Void)?

    init(_ title: String, key: String, defaultExpanded: Bool = true,
         headerAction: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        _isExpanded = AppStorage(wrappedValue: defaultExpanded, key)
        self.headerAction = headerAction
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.headline)
                        Spacer()
                    }
                    .padding(.leading, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let action = headerAction {
                    Button(action: action) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .padding(.trailing, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    content
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }
}

// MARK: - InspectorPanel (production: PhotoAsset from DB)

struct InspectorPanel: View {
    let photo: PhotoAsset?
    let onClose: () -> Void

    @ObservedObject var viewModel: LibraryViewModel

    @Environment(\.appDatabase) private var appDatabase: AppDatabase?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Inspector")
                    .font(.headline)
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Inspector")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let photo {
                        thumbnailCard(for: photo)

                        // Siblings strip (Phase 11)
                        SiblingsNavigatorView(photoAssetId: photo.id) { selected in
                            viewModel.select(selected)
                        }

                        // Workflow state — compact
                        CollapsibleInspectorSection("Workflow", key: "inspector.panel.workflow") {
                            InspectorRow(title: "Curation", value: photo.curationStateEnum.title)
                            InspectorRow(title: "Processing", value: photo.processingStateEnum.title)
                            InspectorRow(title: "Sync", value: photo.syncStateEnum.label)
                        }

                        // EXIF Metadata
                        CollapsibleInspectorSection("Metadata", key: "inspector.panel.metadata") {
                            InspectorRow(title: "Location", value: exifValue(photo, userKey: "location") ?? "—")
                            InspectorRow(title: "Camera",   value: cameraString(for: photo) ?? "—")
                            InspectorRow(title: "Lens",     value: exifValue(photo, rawKey: "LensModel") ?? exifValue(photo, rawKey: "Lens") ?? exifValue(photo, userKey: "lens") ?? "—")
                            InspectorRow(title: "Film Stock", value: exifValue(photo, userKey: "film_stock") ?? "—")
                            InspectorRow(title: "ISO",      value: userMetadataInt(photo, key: "iso").map { String($0) } ?? exifValue(photo, rawKey: "ISO") ?? "—")
                            InspectorRow(title: "Captured", value: exifValue(photo, rawKey: "DateTimeOriginal") ?? exifValue(photo, rawKey: "CreateDate") ?? exifValue(photo, userKey: "date") ?? "—")
                            InspectorRow(title: "GPS",      value: gpsString(for: photo) ?? "—")
                        }

                        // Faces / People
                        facesSection(for: photo)

                        // Drive source badge (Phase 14)
                        driveSourceSection(for: photo)

                        // Original file + drive status
                        originalFileSection(for: photo)

                        // Film lineage (compact)
                        filmLineageSection(for: photo)

                        // Asset details — collapsed by default
                        CollapsibleInspectorSection("Asset", key: "inspector.panel.asset", defaultExpanded: false) {
                            InspectorRow(title: "Canonical ID", value: photo.canonicalName)
                            InspectorRow(title: "Role", value: photo.roleDisplayName)
                            InspectorRow(title: "File Type", value: photo.fileExtension)
                            InspectorRow(title: "File Size", value: formatBytes(photo.fileSize))
                            InspectorRow(title: "File Path", value: (photo.filePath as NSString).lastPathComponent)
                        }

                        // Dates — collapsed by default
                        CollapsibleInspectorSection("Dates", key: "inspector.panel.dates", defaultExpanded: false) {
                            InspectorRow(title: "Created", value: photo.createdAt)
                            InspectorRow(title: "Updated", value: photo.updatedAt)
                        }

                        // Hint to open detail view for more
                        openDetailHint

                    } else {
                        Text("Select a photo to inspect details.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                    }
                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Open Detail hint

    private var openDetailHint: some View {
        VStack(spacing: 6) {
            Divider().padding(.vertical, 4)
            Text("Press Space or click expand on a photo to open the full detail view with actions, activity timeline, and more.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    // MARK: - Thumbnail card (non-collapsible)

    @ViewBuilder
    private func thumbnailCard(for photo: PhotoAsset) -> some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(.linearGradient(
                colors: photo.placeholderGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .frame(height: 110)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "photo.artframe")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.86))
                    Text(photo.canonicalName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                }
            }
    }

    private func formatBytes(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_000_000
        if mb >= 1000 {
            return String(format: "%.1f GB", mb / 1000)
        }
        return String(format: "%.1f MB", mb)
    }

    // MARK: - Original file / drive connectivity

    @ViewBuilder
    private func originalFileSection(for photo: PhotoAsset) -> some View {
        let fileURL = URL(fileURLWithPath: photo.filePath)
        let isAvailable = FileManager.default.fileExists(atPath: photo.filePath)
        CollapsibleInspectorSection("Original File", key: "inspector.panel.original", defaultExpanded: true) {
            HStack(spacing: 8) {
                Image(systemName: isAvailable ? "externaldrive.fill.badge.checkmark" : "externaldrive.badge.xmark")
                    .foregroundStyle(isAvailable ? .green : .secondary)
                Text(isAvailable ? "Drive Connected" : "Drive Offline")
                    .font(.system(size: 12))
                    .foregroundStyle(isAvailable ? .primary : .secondary)
            }
            .padding(.vertical, 2)

            InspectorRow(title: "Filename", value: fileURL.lastPathComponent)
            InspectorRow(title: "Volume", value: fileURL.pathComponents.count > 2 ? fileURL.pathComponents[2] : "—")

            if isAvailable {
                HStack(spacing: 8) {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11))

                    Button("Open Original") {
                        NSWorkspace.shared.open(fileURL)
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11))
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Drive Source badge (Phase 14)

    @ViewBuilder
    private func driveSourceSection(for photo: PhotoAsset) -> some View {
        if let driveUUID = photo.sourceDriveUUID {
            let volumeLabel = viewModel.drives.first(where: { $0.id == driveUUID })?.volumeLabel ?? driveUUID
            let connected = viewModel.isDriveConnected(uuid: driveUUID)
            CollapsibleInspectorSection("Drive Source", key: "inspector.panel.drive.source") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(connected ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text("Proxy \u{2014} original on \(volumeLabel) \u{00B7} \(connected ? "Connected" : "Disconnected")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Metadata helpers

    /// Returns a value from rawExifJson or userMetadataJson by key.
    private func exifValue(_ photo: PhotoAsset, rawKey: String? = nil, userKey: String? = nil) -> String? {
        if let key = rawKey,
           let json = photo.rawExifJson,
           let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let val = dict[key] {
            return "\(val)"
        }
        if let key = userKey,
           let json = photo.userMetadataJson,
           let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let val = dict[key] {
            return "\(val)"
        }
        return nil
    }

    private func cameraString(for photo: PhotoAsset) -> String? {
        if let json = photo.rawExifJson,
           let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let make  = (dict["Make"]  as? String) ?? ""
            let model = (dict["Model"] as? String) ?? ""
            let combined = [make, model].filter { !$0.isEmpty }.joined(separator: " ")
            if !combined.isEmpty { return combined }
        }
        return exifValue(photo, userKey: "camera")
    }

    private func userMetadataInt(_ photo: PhotoAsset, key: String) -> Int? {
        guard let json = photo.userMetadataJson,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return dict[key] as? Int
    }

    private func gpsString(for photo: PhotoAsset) -> String? {
        // Check rawExifJson first
        if let json = photo.rawExifJson,
           let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let lat = dict["GPSLatitude"], let lon = dict["GPSLongitude"] {
            let latRef = (dict["GPSLatitudeRef"]  as? String) ?? ""
            let lonRef = (dict["GPSLongitudeRef"] as? String) ?? ""
            return "\(lat)\(latRef) \(lon)\(lonRef)"
        }
        // Fall back to userMetadataJson (written by applyEditorialEnrichment)
        if let json = photo.userMetadataJson,
           let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let lat = dict["latitude"] as? Double,
           let lon = dict["longitude"] as? Double {
            return String(format: "%.4f, %.4f", lat, lon)
        }
        return nil
    }

    // MARK: - Faces section

    @ViewBuilder
    private func facesSection(for photo: PhotoAsset) -> some View {
        if let db = appDatabase {
            CollapsibleInspectorSection("People", key: "inspector.panel.people", defaultExpanded: false) {
                FaceChipGrid(photo: photo, db: db) { faceIndex, faceImage in
                    Task { await viewModel.searchByFace(photoId: photo.id, faceIndex: faceIndex, faceImage: faceImage, db: db) }
                }
            }
        }
    }

    // MARK: - Film Lineage section (CP-2)

    @ViewBuilder
    private func filmLineageSection(for photo: PhotoAsset) -> some View {
        if let db = appDatabase {
            // FilmLineageSection internally checks hasLineage and renders EmptyView if none.
            // Wrapping it directly (no CollapsibleInspectorSection) avoids showing
            // an empty "Film Lineage" header for non-film photos.
            FilmLineageSection(
                photo: photo,
                db: db,
                onSelectPhoto: { selected in
                    viewModel.select(selected)
                }
            )
        }
    }
}

// MARK: - InspectorPanelMock (Preview / MockDataStore only)

struct InspectorPanelMock: View {
    let photo: PhotoRecord?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Inspector")
                    .font(.headline)
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Inspector")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let photo {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.linearGradient(colors: photo.gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(height: 180)
                            .overlay {
                                VStack(spacing: 8) {
                                    Image(systemName: "photo.artframe")
                                        .font(.system(size: 32))
                                        .foregroundStyle(.white.opacity(0.86))
                                    Text(photo.displayTitle)
                                        .font(.headline)
                                        .foregroundStyle(.white)
                                }
                            }

                        inspectorSection("Asset") {
                            InspectorRow(title: "Canonical ID", value: photo.canonicalName)
                            InspectorRow(title: "Role", value: photo.role.displayName)
                            InspectorRow(title: "Drive", value: photo.driveName)
                            InspectorRow(title: "File Type", value: photo.fileType)
                            InspectorRow(title: "Dimensions", value: photo.dimensions)
                        }

                        inspectorSection("Metadata") {
                            InspectorRow(title: "Location", value: "\(photo.city), \(photo.country)")
                            InspectorRow(title: "Camera", value: photo.camera)
                            InspectorRow(title: "Lens", value: photo.lens)
                            InspectorRow(title: "Captured", value: photo.captureDate.formatted(date: .abbreviated, time: .shortened))
                            InspectorRow(title: "GPS", value: photo.hasGPS ? "Available" : "Missing")
                        }

                        inspectorSection("Workflow") {
                            InspectorRow(title: "Curation", value: photo.curation.title)
                            InspectorRow(title: "Processing", value: photo.processingState.title)
                            InspectorRow(title: "Sync", value: photo.syncState.label)
                            InspectorRow(title: "Portfolio", value: photo.isPortfolioCandidate ? "Yes" : "No")
                        }

                        if !photo.keywords.isEmpty {
                            inspectorSection("Keywords") {
                                FlexibleTagWrap(tags: photo.keywords)
                            }
                        }

                        if !photo.thread.isEmpty {
                            inspectorSection("Recent Thread") {
                                ForEach(photo.thread) { item in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.title)
                                            .font(.subheadline.weight(.semibold))
                                        Text(item.body)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text(item.date, style: .date)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 6)
                                }
                            }
                        }
                    } else {
                        Text("Select a photo to inspect details, thread history, and print recipes.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                    }
                }
                .padding(16)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }
}
