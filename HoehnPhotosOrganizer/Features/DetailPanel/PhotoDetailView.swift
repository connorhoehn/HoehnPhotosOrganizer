import SwiftUI

// MARK: - PhotoDetailView

/// Rich 3-pane detail workspace that replaces the old ImagePreviewOverlay.
/// Layout: Left sidebar (actions + activity timeline) | Center (image + overlays) | Right sidebar (metadata inspector)
struct PhotoDetailView: View {
    let photo: PhotoAsset
    let image: NSImage?
    @Binding var isPresented: Bool
    @ObservedObject var viewModel: LibraryViewModel

    @Environment(\.appDatabase) private var appDatabase: AppDatabase?
    @EnvironmentObject private var rollbackEngine: RollbackEngine

    // Panel visibility
    @AppStorage("detail.leftSidebar") private var showLeftSidebar = true
    @AppStorage("detail.rightSidebar") private var showRightSidebar = true

    // Action sheets
    @State private var showingEditorialFeedback = false
    @State private var showingAdjustments = false
    @State private var showingGenerativeRendering = false
    @State private var showingFilmExtraction = false
    @State private var showingSimilaritySearch = false
    @State private var showingPipelinePicker = false
    @State private var showingPipelineEditor = false
    @State private var showingRunProgress = false
    @State private var showingProxyMissingAlert = false
    @State private var availablePipelines: [PipelineDefinition] = []
    @State private var currentStream: AsyncStream<PipelineRunProgress>?
    @State private var currentRunID: String?
    @State private var showNoteInput = false

    // Export state
    @State private var exportInProgress = false
    @State private var lastExportURL: URL? = nil
    @State private var exportError: String? = nil

    // Image display
    @State private var showHighRes = false
    @State private var highResImage: NSImage? = nil
    @State private var showFaceOverlay = false

    // Masking state (shared between AdjustmentPanelView sheet and MaskOverlayView)
    @State private var maskLayers: [AdjustmentLayer] = []
    @State private var selectedMaskId: String? = nil
    @State private var showMaskOverlay: Bool = false
    @State private var displayedImageRect: CGRect = .zero

    // Zoom & pan
    @State private var zoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            detailToolbar

            Divider()

            // 3-pane body
            HStack(spacing: 0) {
                if showLeftSidebar {
                    leftSidebar
                        .frame(width: 280)
                        .transition(.move(edge: .leading).combined(with: .opacity))

                    Divider()
                }

                centerPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showRightSidebar {
                    Divider()

                    rightSidebar
                        .frame(width: 280)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 1300, idealWidth: 1600, minHeight: 800, idealHeight: 1000)
        .sheet(isPresented: $showingEditorialFeedback) {
            EditorialFeedbackView(photo: photo, viewModel: viewModel)
        }
        .sheet(isPresented: $showingAdjustments) {
            AdjustmentPanelView(
                targets: [photo],
                externalMaskLayers: $maskLayers,
                externalSelectedMaskId: $selectedMaskId
            )
        }
        .sheet(isPresented: $showingGenerativeRendering) {
            GenerativeRenderingView(photo: photo, viewModel: viewModel)
        }
        .sheet(isPresented: $showingFilmExtraction) {
            FilmStripPreviewSheet(sourcePhotoId: photo.id)
        }
        .sheet(isPresented: $showingSimilaritySearch) {
            SimilaritySearchView(referencePhoto: photo)
        }
        .sheet(isPresented: $showNoteInput) {
            if let db = appDatabase {
                NoteInputSheet(photoId: photo.id, db: db)
            }
        }
        .sheet(isPresented: $showingPipelineEditor) {
            if let db = appDatabase {
                PipelineEditorView(db: db)
            }
        }
        .sheet(isPresented: $showingPipelinePicker) {
            if let db = appDatabase {
                pipelinePickerSheet(for: photo, db: db)
            }
        }
        .sheet(isPresented: $showingRunProgress) {
            if let stream = currentStream, let runID = currentRunID {
                PipelineRunProgressView(stream: stream, runID: runID)
            }
        }
        .alert("Proxy Not Available", isPresented: $showingProxyMissingAlert) {
            Button("OK") {}
        } message: {
            Text("A proxy image must be generated before running a pipeline. The photo is still processing.")
        }
    }

    // MARK: - Top Toolbar

    private var detailToolbar: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showLeftSidebar.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 14))
                    .foregroundStyle(showLeftSidebar ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help("Toggle Actions Panel")

            Divider().frame(height: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(photo.canonicalName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    StatusPill(title: photo.curationStateEnum.title, tint: photo.curationStateEnum.tint)
                    StatusPill(title: photo.processingStateEnum.title, tint: .white.opacity(0.5))
                }
            }

            Spacer()

            // Image toggle
            Toggle(isOn: $showHighRes) {
                Image(systemName: showHighRes ? "eye.fill" : "eye")
                    .font(.system(size: 12))
            }
            .toggleStyle(.button)
            .help(showHighRes ? "Showing Original" : "Showing Proxy")
            .onChange(of: showHighRes) { _, wantHiRes in
                if wantHiRes { loadHighResImage() }
            }

            // Mask overlay toggle
            Button {
                showMaskOverlay.toggle()
            } label: {
                Image(systemName: showMaskOverlay ? "circle.dashed.inset.filled" : "circle.dashed")
                    .font(.system(size: 14))
                    .foregroundStyle(showMaskOverlay ? Color.yellow : .secondary)
            }
            .buttonStyle(.plain)
            .help("Toggle mask overlay")

            Divider().frame(height: 16)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showRightSidebar.toggle() }
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 14))
                    .foregroundStyle(showRightSidebar ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help("Toggle Metadata Panel")

            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Left Sidebar: Actions + Activity Timeline

    private var leftSidebar: some View {
        VStack(spacing: 0) {
            // Actions section
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("Actions")

                    ActionButton(icon: "text.bubble", title: "Editorial Review", accent: .purple) {
                        showingEditorialFeedback = true
                    }
                    ActionButton(icon: "gearshape.2", title: "Run Pipeline", accent: .mint) {
                        loadAndShowPipelines()
                    }
                    ActionButton(icon: "slider.horizontal.3", title: "Edit Adjustments", accent: .blue) {
                        showingAdjustments = true
                    }
                    ActionButton(icon: "note.text.badge.plus", title: "Add Note", accent: .yellow) {
                        showNoteInput = true
                    }

                    Divider().padding(.vertical, 8)

                    sectionLabel("Activity")

                    if let db = appDatabase {
                        PhotoTimelineView(photoAssetId: photo.id, db: db)
                            .id(photo.id)
                    } else {
                        Text("No activity recorded.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(14)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Center Pane: Image + Overlays + Zoom/Pan

    private var centerPane: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                let displayImage = showHighRes ? (highResImage ?? image) : image

                if let img = displayImage {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(zoomScale)
                        .offset(x: panOffset.width, y: panOffset.height)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .background(
                            GeometryReader { imgGeo in
                                Color.clear
                                    .onAppear {
                                        displayedImageRect = computeDisplayedImageRect(
                                            for: img,
                                            in: geo.size
                                        )
                                    }
                                    .onChange(of: geo.size) {
                                        displayedImageRect = computeDisplayedImageRect(
                                            for: img,
                                            in: geo.size
                                        )
                                    }
                            }
                        )
                        .gesture(
                            MagnifyGesture()
                                .onChanged { value in
                                    zoomScale = max(1.0, min(10.0, value.magnification))
                                }
                        )
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    guard zoomScale > 1.0 else { return }
                                    panOffset = CGSize(
                                        width: lastPanOffset.width + value.translation.width,
                                        height: lastPanOffset.height + value.translation.height
                                    )
                                }
                                .onEnded { _ in
                                    lastPanOffset = panOffset
                                }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                if zoomScale > 1.0 {
                                    zoomScale = 1.0
                                    panOffset = .zero
                                    lastPanOffset = .zero
                                } else {
                                    zoomScale = 3.0
                                }
                            }
                        }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "photo")
                            .font(.system(size: 64, weight: .light))
                            .foregroundStyle(.white.opacity(0.3))
                        Text("No preview available")
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }

                // Mask overlay
                if showMaskOverlay {
                    MaskOverlayView(
                        maskLayers: $maskLayers,
                        selectedMaskId: $selectedMaskId,
                        displayedImageRect: displayedImageRect
                    )
                }

                // Zoom indicator
                if zoomScale > 1.0 {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text("\(Int(zoomScale * 100))%")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule().fill(.black.opacity(0.5))
                                )
                            .padding(12)
                        }
                    }
                }
            }
        }
    }

    /// Compute the letterboxed image rect within a container of the given size.
    private func computeDisplayedImageRect(for img: NSImage, in containerSize: CGSize) -> CGRect {
        let imgSize = img.size
        guard imgSize.width > 0, imgSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else { return .zero }

        let imgAspect = imgSize.width / imgSize.height
        let containerAspect = containerSize.width / containerSize.height

        let displayW: CGFloat
        let displayH: CGFloat
        if imgAspect > containerAspect {
            // Image is wider — constrained by container width
            displayW = containerSize.width
            displayH = containerSize.width / imgAspect
        } else {
            // Image is taller — constrained by container height
            displayH = containerSize.height
            displayW = containerSize.height * imgAspect
        }
        let originX = (containerSize.width - displayW) / 2
        let originY = (containerSize.height - displayH) / 2
        return CGRect(x: originX, y: originY, width: displayW, height: displayH)
    }

    // MARK: - Right Sidebar: Metadata Inspector (slim)

    private var rightSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // Workflow state — compact
                DetailMetadataSection("Status") {
                    InspectorRow(title: "Curation", value: photo.curationStateEnum.title)
                    InspectorRow(title: "Processing", value: photo.processingStateEnum.title)
                    InspectorRow(title: "Sync", value: photo.syncStateEnum.label)
                }

                // EXIF Metadata
                DetailMetadataSection("Metadata") {
                    InspectorRow(title: "Location", value: exifValue(photo, userKey: "location") ?? "—")
                    InspectorRow(title: "Camera", value: cameraString(for: photo) ?? "—")
                    InspectorRow(title: "Lens", value: exifValue(photo, rawKey: "LensModel") ?? exifValue(photo, rawKey: "Lens") ?? exifValue(photo, userKey: "lens") ?? "—")
                    InspectorRow(title: "Film Stock", value: exifValue(photo, userKey: "film_stock") ?? "—")
                    InspectorRow(title: "ISO", value: userMetadataInt(photo, key: "iso").map { String($0) } ?? exifValue(photo, rawKey: "ISO") ?? "—")
                    InspectorRow(title: "Captured", value: exifValue(photo, rawKey: "DateTimeOriginal") ?? exifValue(photo, rawKey: "CreateDate") ?? exifValue(photo, userKey: "date") ?? "—")
                    InspectorRow(title: "GPS", value: gpsString(for: photo) ?? "—")
                }

                // Faces
                if let db = appDatabase {
                    DetailMetadataSection("People") {
                        FaceChipGrid(photo: photo, db: db) { faceIndex, faceImage in
                            Task { await viewModel.searchByFace(photoId: photo.id, faceIndex: faceIndex, faceImage: faceImage, db: db) }
                        }
                    }
                }

                // Original file + drive connectivity
                originalFileSection

                // Siblings navigator
                SiblingsNavigatorView(photoAssetId: photo.id) { selected in
                    viewModel.select(selected)
                }

                // Film lineage (only renders when photo has lineage relationships)
                if let db = appDatabase {
                    FilmLineageSection(
                        photo: photo,
                        db: db,
                        onSelectPhoto: { selected in
                            viewModel.select(selected)
                        }
                    )
                }

                // Asset details
                DetailMetadataSection("Asset") {
                    InspectorRow(title: "ID", value: photo.canonicalName)
                    InspectorRow(title: "Role", value: photo.roleDisplayName)
                    InspectorRow(title: "Type", value: photo.fileExtension)
                    InspectorRow(title: "Size", value: formatBytes(photo.fileSize))
                }

                // History / Rollback
                if let db = appDatabase {
                    DetailMetadataSection("History") {
                        LineageTimelineView(
                            viewModel: LineageTimelineViewModel(
                                photoAssetId: photo.id,
                                db: db,
                                onRollback: { snapshot in
                                    try? await rollbackEngine.rollback(to: snapshot, photoAssetId: photo.id)
                                }
                            )
                        )
                        .id(photo.id)
                    }
                }

                // Dates
                DetailMetadataSection("Dates") {
                    InspectorRow(title: "Created", value: photo.createdAt)
                    InspectorRow(title: "Updated", value: photo.updatedAt)
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Original file section

    @ViewBuilder
    private var originalFileSection: some View {
        let fileURL = URL(fileURLWithPath: photo.filePath)
        let isAvailable = FileManager.default.fileExists(atPath: photo.filePath)
        DetailMetadataSection("Original File") {
            HStack(spacing: 8) {
                Image(systemName: isAvailable ? "externaldrive.fill.badge.checkmark" : "externaldrive.badge.xmark")
                    .foregroundStyle(isAvailable ? .green : .secondary)
                Text(isAvailable ? "Drive Connected" : "Drive Offline")
                    .font(.system(size: 12))
                    .foregroundStyle(isAvailable ? .primary : .secondary)
            }
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
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.tertiary)
            .padding(.bottom, 2)
    }

    private func exportMetadata() {
        guard let db = appDatabase else { return }
        Task {
            exportInProgress = true
            exportError = nil
            do {
                let service = MetadataExportService(db: db)
                let url = try await service.exportMetadataAsJSON(photoId: photo.id)
                lastExportURL = url
            } catch {
                exportError = error.localizedDescription
            }
            exportInProgress = false
        }
    }

    private func loadHighResImage() {
        let url = URL(fileURLWithPath: photo.filePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        Task.detached(priority: .userInitiated) {
            let img = NSImage(contentsOf: url)
            await MainActor.run { highResImage = img }
        }
    }

    private func loadAndShowPipelines() {
        guard let db = appDatabase else { return }
        Task {
            do {
                let repo = PipelineRepository(db: db)
                availablePipelines = try await repo.fetchAllPipelines()
            } catch {
                availablePipelines = []
            }
            showingPipelinePicker = true
        }
    }

    private func pipelinePickerSheet(for photo: PhotoAsset, db: AppDatabase) -> some View {
        NavigationStack {
            Group {
                if availablePipelines.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "wand.and.rays")
                            .font(.system(size: 44))
                            .foregroundStyle(.tertiary)
                        Text("No pipelines saved yet.")
                            .font(.title3.weight(.semibold))
                        Text("Create a pipeline first using Manage Pipelines.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(availablePipelines) { pipeline in
                            Button {
                                launchPipeline(pipeline, for: photo, db: db)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(pipeline.name).font(.body)
                                    Text(PipelinePurpose(rawValue: pipeline.purpose)?.displayLabel ?? pipeline.purpose)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Select Pipeline")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingPipelinePicker = false }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 300)
    }

    private func launchPipeline(_ pipeline: PipelineDefinition, for photo: PhotoAsset, db: AppDatabase) {
        showingPipelinePicker = false
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let proxyDirectory = appSupport.appendingPathComponent("HoehnPhotosOrganizer").appendingPathComponent("proxies")
        let outputDirectory = appSupport.appendingPathComponent("HoehnPhotosOrganizer").appendingPathComponent("pipeline_outputs")
        let baseName = (photo.canonicalName as NSString).deletingPathExtension
        let proxyURL = proxyDirectory.appendingPathComponent(baseName + ".jpg")
        guard fm.fileExists(atPath: proxyURL.path) else {
            showingProxyMissingAlert = true
            return
        }
        let actor = PipelineRunActor()
        let (runID, stream) = actor.run(
            pipelineId: pipeline.id,
            sourcePhotoId: photo.id,
            proxyURL: proxyURL,
            outputDirectory: outputDirectory,
            db: db
        )
        currentRunID = runID
        currentStream = stream
        showingRunProgress = true
    }

    // MARK: - Metadata value helpers (duplicated from InspectorPanel for now)

    private func formatBytes(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_000_000
        if mb >= 1000 { return String(format: "%.1f GB", mb / 1000) }
        return String(format: "%.1f MB", mb)
    }

    private func exifValue(_ photo: PhotoAsset, rawKey: String? = nil, userKey: String? = nil) -> String? {
        if let key = rawKey,
           let json = photo.rawExifJson,
           let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let val = dict[key] { return "\(val)" }
        if let key = userKey,
           let json = photo.userMetadataJson,
           let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let val = dict[key] { return "\(val)" }
        return nil
    }

    private func cameraString(for photo: PhotoAsset) -> String? {
        if let json = photo.rawExifJson,
           let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let make  = (dict["Make"] as? String) ?? ""
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
        if let json = photo.rawExifJson,
           let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let lat = dict["GPSLatitude"], let lon = dict["GPSLongitude"] {
            let latRef = (dict["GPSLatitudeRef"] as? String) ?? ""
            let lonRef = (dict["GPSLongitudeRef"] as? String) ?? ""
            return "\(lat)\(latRef) \(lon)\(lonRef)"
        }
        if let json = photo.userMetadataJson,
           let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let lat = dict["latitude"] as? Double,
           let lon = dict["longitude"] as? Double {
            return String(format: "%.4f, %.4f", lat, lon)
        }
        return nil
    }
}

// MARK: - ActionButton

private struct ActionButton: View {
    let icon: String
    let title: String
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(0.08))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - DetailMetadataSection

private struct DetailMetadataSection<Content: View>: View {
    let title: String
    let content: Content

    @State private var isExpanded = true

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    content
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }
}

// MARK: - FaceOverlayLayer (placeholder for face bounding boxes on image)

private struct FaceOverlayLayer: View {
    let photo: PhotoAsset
    let db: AppDatabase

    var body: some View {
        // Future: render face bounding boxes over the image
        EmptyView()
    }
}
