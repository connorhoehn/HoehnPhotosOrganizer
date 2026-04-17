import SwiftUI
import GRDB
import MapKit

// MARK: - Footer status indicators

private struct StatusIndicatorsView: View {
    let driveCount: Int
    let cloudAIActive: Bool

    var body: some View {
        HStack(spacing: 14) {
            dot(
                label: "\(driveCount) drive\(driveCount == 1 ? "" : "s")",
                icon: "externaldrive.fill",
                active: driveCount > 0
            )
            dot(label: "Local ML", icon: "cpu", active: true)
            dot(label: "Cloud AI", icon: "cloud", active: cloudAIActive)
        }
    }

    private func dot(label: String, icon: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(active ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 5, height: 5)
            Image(systemName: icon)
            Text(label)
        }
        .font(.caption2)
        .foregroundStyle(active ? .tertiary : .quaternary)
    }
}

// MARK: - Section header helper

private struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }
}

// MARK: - MainWorkspaceView (production: LibraryViewModel)

struct MainWorkspaceView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Binding var inspectorVisible: Bool
    @State private var showCallout = false
    @State private var showingPipelineEditor = false
    @State private var showingBatchPasteSheet = false
    @State private var batchPasteOptions: PasteOptions = .all
    @Environment(\.appDatabase) private var appDatabase: AppDatabase?
    @Environment(AdjustmentClipboard.self) private var clipboard: AdjustmentClipboard?

    // MARK: - Curation undo toast
    /// Captured per-photo states just before a bulk curation is applied.
    @State private var lastCurationSnapshot: [(id: String, state: CurationState)] = []
    @State private var lastCurationLabel: String = ""
    @State private var lastCurationCount: Int = 0
    @State private var showUndoToast = false

    private var photoColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 150, maximum: 220), spacing: 16),
            count: max(2, Int(viewModel.gridColumns.rounded()))
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbarStrip
                .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if viewModel.selectedSection == .library {
                HStack(spacing: 16) {
                    ForEach(viewModel.metrics) { metric in
                        MetricCard(metric: metric)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 4)

                Divider()
                    .padding(.horizontal, 24)
            }

            if !viewModel.selectedPhotoIDs.isEmpty &&
               (viewModel.selectedSection == .library || viewModel.selectedSection == .search) {
                bulkActionBar
                    .transition(.move(edge: .top).combined(with: .opacity))
                Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    sectionBody
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            breadcrumbBar
                .background(Color(nsColor: .controlBackgroundColor))
        }
        .overlay(alignment: .bottom) {
            if showUndoToast {
                HStack(spacing: 12) {
                    Text("\(lastCurationCount) photo\(lastCurationCount == 1 ? "" : "s") marked \(lastCurationLabel)")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Button("Undo") {
                        let snapshot = lastCurationSnapshot
                        withAnimation(.easeOut(duration: 0.2)) { showUndoToast = false }
                        Task { await viewModel.restoreCurationStates(snapshot) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                .padding(.bottom, 48)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showUndoToast)
        .sheet(isPresented: $showingPipelineEditor) {
            if let db = appDatabase {
                PipelineEditorView(db: db)
            }
        }
        .sheet(isPresented: $showingBatchPasteSheet) {
            SelectivePasteSheet(
                options: $batchPasteOptions,
                targetCount: viewModel.selectedPhotoIDs.count,
                onConfirm: {
                    guard let clip = clipboard, let db = appDatabase else { return }
                    let targetIds = Array(viewModel.selectedPhotoIDs)
                    let opts = batchPasteOptions
                    showingBatchPasteSheet = false
                    Task {
                        let snapshotRepo = AdjustmentSnapshotRepository(db: db)
                        let activityRepo = ActivityEventRepository(db: db)
                        let activityService = ActivityEventService(repo: activityRepo)
                        let lineageRepo = LineageRepository(db.dbPool)
                        let batchService = BatchAdjustmentService(
                            db: db,
                            snapshotRepo: snapshotRepo,
                            activityService: activityService,
                            lineageRepo: lineageRepo
                        )
                        let source = clip.copiedAdjustment ?? PhotoAdjustments()
                        try? await batchService.applyToPhotos(
                            sourceAdjustment: source,
                            targetPhotoIds: targetIds,
                            operationDescription: "Paste to \(targetIds.count) photos"
                        )
                    }
                },
                onCancel: { showingBatchPasteSheet = false }
            )
        }
    }

    private var toolbarStrip: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.selectedSection.title)
                        .font(.system(size: 17, weight: .bold))
                    Text(sectionSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                TextField("Search photos, places, prints, or notes…", text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .onChange(of: viewModel.searchText) { _ in
                        viewModel.scheduleSearch()
                    }

                if viewModel.isSearching {
                    Text("Searching…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()
                    .frame(height: 22)

                if appDatabase != nil {
                    Button {
                        showingPipelineEditor = true
                    } label: {
                        Image(systemName: "wand.and.rays")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Manage Pipelines")
                }

                if let db = appDatabase {
                    Button {
                        Task {
                            let targets = viewModel.selectedPhotoIDs.isEmpty
                                ? nil
                                : viewModel.photos.filter { viewModel.selectedPhotoIDs.contains($0.id) }
                            await viewModel.runAutoOrient(targetPhotos: targets, db: db)
                        }
                    } label: {
                        if viewModel.isAutoOrienting {
                            HStack(spacing: 4) {
                                ProgressView().scaleEffect(0.65)
                                if let p = viewModel.autoOrientProgress {
                                    Text("\(p.completed)/\(p.total)")
                                        .font(.caption2)
                                }
                            }
                            .foregroundStyle(.blue)
                        } else {
                            Image(systemName: "rotate.right")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isAutoOrienting)
                    .help(viewModel.selectedPhotoIDs.isEmpty
                          ? "Auto-Orient All Photos"
                          : "Auto-Orient Selected (\(viewModel.selectedPhotoIDs.count))")
                }

                Divider()
                    .frame(height: 22)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        inspectorVisible.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.right")
                        .symbolVariant(inspectorVisible ? .fill : .none)
                        .font(.system(size: 15, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(inspectorVisible ? Color.accentColor : .secondary)
                .help(inspectorVisible ? "Hide Inspector" : "Show Inspector")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)

            // Filter summary below search bar
            if let filter = viewModel.lastFilter, !filter.isEmpty {
                HStack {
                    Text("Filter: \(filterSummary(filter))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            }

            // Batch paste bar — shown when multi-selected + clipboard has content
            if clipboard?.hasContent == true && viewModel.selectedPhotoIDs.count >= 2 {
                HStack(spacing: 10) {
                    Image(systemName: "doc.on.clipboard.fill")
                        .foregroundStyle(Color.accentColor)
                    Button("Paste Settings to \(viewModel.selectedPhotoIDs.count) Photos") {
                        batchPasteOptions = .all
                        showingBatchPasteSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.08))
            }
        }
    }

    private func filterSummary(_ filter: SearchFilter) -> String {
        var parts: [String] = []
        if let loc = filter.location { parts.append("location: \(loc)") }
        if let year = filter.yearFrom { parts.append("year: \(year)") }
        if let ft = filter.fileType { parts.append("type: \(ft)") }
        if let cs = filter.curationState { parts.append("state: \(cs)") }
        if let tod = filter.timeOfDay { parts.append("time: \(tod)") }
        if let kws = filter.keywords, !kws.isEmpty { parts.append("keywords: \(kws.joined(separator: ", "))") }
        return parts.joined(separator: " | ")
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 5) {
            Text("HoehnPhotos")
                .foregroundStyle(.quaternary)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.quaternary)
            Text(viewModel.selectedSection.title)
                .foregroundStyle(.tertiary)

            if let photo = viewModel.selectedPhoto,
               viewModel.selectedSection == .library || viewModel.selectedSection == .search {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                Text(photo.canonicalName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            statusIndicators
        }
        .font(.caption)
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
    }

    private var statusIndicators: some View {
        StatusIndicatorsView(
            driveCount: viewModel.detectedDrives.count,
            cloudAIActive: viewModel.cloudAIConfigured
        )
    }

    /// Capture per-photo previous states, apply curation, then show undo toast.
    private func applyCurationWithUndo(_ state: CurationState) {
        let ids = viewModel.selectedPhotoIDs
        // Snapshot current states before overwriting
        let snapshot = viewModel.photos
            .filter { ids.contains($0.id) }
            .compactMap { photo -> (id: String, state: CurationState)? in
                guard let s = CurationState(rawValue: photo.curationState) else { return nil }
                return (id: photo.id, state: s)
            }
        Task {
            await viewModel.applyCuration(state, to: ids)
        }
        lastCurationSnapshot = snapshot
        lastCurationLabel = state.title
        lastCurationCount = ids.count
        // Cancel any in-flight dismiss and restart the 5s window
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            showUndoToast = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            withAnimation(.easeOut(duration: 0.2)) { showUndoToast = false }
        }
    }

    @ViewBuilder
    private var bulkActionBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
            Text("\(viewModel.selectedPhotoIDs.count) selected")
                .font(.system(size: 13, weight: .semibold))

            Divider().frame(height: 20)

            Button {
                applyCurationWithUndo(.keeper)
            } label: { Label("Keeper", systemImage: "star.fill") }
            .buttonStyle(.bordered).controlSize(.small).tint(.yellow)

            Button {
                applyCurationWithUndo(.archive)
            } label: { Label("Archive", systemImage: "archivebox") }
            .buttonStyle(.bordered).controlSize(.small)

            Button {
                applyCurationWithUndo(.needsReview)
            } label: { Label("Needs Review", systemImage: "exclamationmark.circle") }
            .buttonStyle(.bordered).controlSize(.small)

            Button {
                applyCurationWithUndo(.rejected)
            } label: { Label("Reject", systemImage: "xmark.circle") }
            .buttonStyle(.bordered).controlSize(.small).tint(.red)

            Spacer()

            Button {
                viewModel.workflowPhotoIDs = Array(viewModel.selectedPhotoIDs)
                viewModel.selectedPhotoIDs = []
                viewModel.selectedSection = .workflows
            } label: { Label("Workflow", systemImage: "arrow.triangle.2.circlepath.circle") }
            .buttonStyle(.borderedProminent).controlSize(.small)

            Button("Deselect All") { viewModel.selectedPhotoIDs = [] }
                .buttonStyle(.bordered).controlSize(.small).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var sectionBody: some View {
        switch viewModel.selectedSection {
        case .drives, .imports:
            drivesView
        case .printLab:
            printLabView
        case .people:
            FaceGalleryView()
        case .activity:
            activityView
        case .library, .search:
            libraryView
        case .map:
            EmptyView() // Map handled in LibraryWorkspaceView
        case .studio:
            StudioHostView(viewModel: viewModel.studioViewModel, libraryPhotos: viewModel.photos)
        default:
            EmptyView()
}
    }

    private var libraryView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showCallout {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(viewModel.selectedSection == .search ? "Search Snapshot" : "Library Snapshot")
                            .font(.headline)
                        Text(
                            viewModel.selectedSection == .search
                            ? "Natural-language query: \(viewModel.searchText.isEmpty ? "…" : viewModel.searchText)"
                            : "Catalog first, then curation, then print and threads."
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        withAnimation {
                            showCallout = false
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            .linearGradient(
                                colors: [Color.accentColor.opacity(0.13), Color.purple.opacity(0.07)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
            }

            if viewModel.filteredPhotos.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 44))
                        .foregroundStyle(.tertiary)
                    Text("No photos yet.")
                        .font(.title3.weight(.semibold))
                    Text("Connect a drive and start an import.")
                        .foregroundStyle(.secondary)

                    if !showCallout {
                        Button("Show guide") {
                            withAnimation {
                                showCallout = true
                            }
                        }
                        .buttonStyle(.link)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
                LazyVGrid(columns: photoColumns, spacing: 16) {
                    ForEach(viewModel.filteredPhotos) { photo in
                        PhotoCardAsset(photo: photo, isSelected: viewModel.selectedPhotoID == photo.id, viewModel: viewModel)
                            .onTapGesture {
                                viewModel.select(photo)
                            }
                            .zIndex(viewModel.selectedPhotoID == photo.id ? 1 : 0)
                    }
                }
            }
        }
    }

    private var drivesView: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "Connected Drives",
                subtitle: "Originals remain where they are. The app tracks each volume, ingest status, and reconciliation state."
            )

            Divider()

            if viewModel.drives.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "externaldrive.slash")
                        .font(.system(size: 44))
                        .foregroundStyle(.tertiary)
                    Text("No drives catalogued yet.")
                        .font(.title3.weight(.semibold))
                    Text("Connect a drive and start an import to see it here.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
                ForEach(viewModel.drives) { drive in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(drive.volumeLabel)
                                    .font(.headline)
                                Text(drive.mountPoint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }

                        let usedRatio = drive.totalBytes > 0
                            ? Double(drive.totalBytes - drive.freeBytes) / Double(drive.totalBytes)
                            : 0.0
                        ProgressView(value: usedRatio)

                        HStack(spacing: 24) {
                            Label(
                                String(format: "%.1f GB free", Double(drive.freeBytes) / 1_000_000_000),
                                systemImage: "internaldrive"
                            )
                            Label(drive.lastSeen, systemImage: "clock")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                }
            }
        }
    }

    private var importsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "Import Pipeline",
                subtitle: "Every file moves through: discovered → indexed → proxy ready → metadata enriched → sync pending."
            )

            Divider()

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(ImportStage.allCases) { stage in
                        HStack(alignment: .top, spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(viewModel.selectedImportStage == stage ? Color.accentColor : Color.gray.opacity(0.2))
                                    .frame(width: 28, height: 28)

                                Image(systemName: viewModel.selectedImportStage == stage ? "checkmark" : "circle.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(viewModel.selectedImportStage == stage ? .white : .secondary)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(stage.title)
                                    .font(.headline)
                                Text(stage.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(viewModel.selectedImportStage == stage ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                        )
                        .onTapGesture {
                            viewModel.selectedImportStage = stage
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 16) {
                    Text("Pending Assets")
                        .font(.headline)

                    let pending = viewModel.photos.filter { $0.processingState != ProcessingState.metadataEnriched.rawValue }
                    ForEach(pending) { photo in
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.linearGradient(
                                    colors: photo.placeholderGradient,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                                .frame(width: 70, height: 70)
                                .overlay {
                                    Image(systemName: "photo")
                                        .font(.title3)
                                        .foregroundStyle(.white.opacity(0.85))
                                }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(photo.canonicalName)
                                    .font(.headline)
                                Text(photo.canonicalName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                StatusPill(title: photo.processingStateEnum.title, tint: .orange)
                            }

                            Spacer()
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .onTapGesture {
                            viewModel.select(photo)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var printLabView: some View {
        PrintLabHostView(
            viewModel: viewModel.printLabViewModel,
            libraryPhotos: viewModel.photos
        )
    }

    private var activityView: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "Activity",
                subtitle: "Recent search sessions, print experiments, and import progress."
            )

            Divider()

            // Activity log will be populated as ingestion and search actions run.
            VStack(spacing: 14) {
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.system(size: 44))
                    .foregroundStyle(.tertiary)
                Text("No activity yet.")
                    .font(.title3.weight(.semibold))
                Text("Activity will appear here as you import drives and run searches.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        }
    }

    private var sectionSubtitle: String {
        switch viewModel.selectedSection {
        case .library:
            "Catalog of originals, derivatives, and in-progress assets."
        case .search:
            "Natural-language discovery on local metadata and local ML."
        case .map:
            "Geotagged photos plotted on a map with cluster-based filtering."
        case .drives, .imports:
            "Connected storage, ingest progress, and reconciliation state."
        case .jobs:
            "Triage imported photos into jobs — cluster, label, and track completeness."
        case .workflows:
            "Apply transforms, annotations, and batch jobs to selected photos."
        case .printLab:
            "Persistent recipes, curves, and print history per image."
        case .studio:
            "Artistic rendering from photos — oil, watercolor, charcoal, and more."
        case .people:
            "Label faces, run auto-match, and send borderline matches to Claude."
        case .activity:
            "What happened recently and what still needs attention."
        case .settings:
            ""
        }
    }
}

// MARK: - MainWorkspaceViewMock (Preview / MockDataStore only)

/// Preview-only variant that wraps MockDataStore for #Preview blocks.
struct MainWorkspaceViewMock: View {
    @ObservedObject var store: MockDataStore
    @Binding var inspectorVisible: Bool
    @State private var showCallout = false

    private var photoColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 150, maximum: 220), spacing: 16),
            count: max(2, Int(store.gridColumns.rounded()))
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbarStrip
                .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if store.selectedSection == .library {
                HStack(spacing: 16) {
                    ForEach(store.metrics) { metric in
                        MetricCard(metric: metric)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 4)

                Divider()
                    .padding(.horizontal, 24)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    sectionBody
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            breadcrumbBar
                .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private var toolbarStrip: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.selectedSection.title)
                    .font(.system(size: 17, weight: .bold))
                Text(sectionSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            TextField("Search photos, places, prints, or notes…", text: $store.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)

            Divider()
                .frame(height: 22)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    inspectorVisible.toggle()
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .symbolVariant(inspectorVisible ? .fill : .none)
                    .font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(inspectorVisible ? Color.accentColor : .secondary)
            .help(inspectorVisible ? "Hide Inspector" : "Show Inspector")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 5) {
            Text("HoehnPhotos")
                .foregroundStyle(.quaternary)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.quaternary)
            Text(store.selectedSection.title)
                .foregroundStyle(.tertiary)

            if let photo = store.selectedPhoto,
               store.selectedSection == .library || store.selectedSection == .search {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                Text(photo.canonicalName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            StatusIndicatorsView(driveCount: 0, cloudAIActive: false)
        }
        .font(.caption)
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var sectionBody: some View {
        switch store.selectedSection {
        case .drives, .imports:
            drivesView
        case .printLab:
            printLabView
        case .people:
            FaceGalleryView()
        case .activity:
            activityView
        case .library, .search:
            libraryView
        case .map:
            EmptyView()
        case .studio:
            StudioHostView(viewModel: StudioViewModel(), libraryPhotos: [])
        default:
            EmptyView()
        }
    }

    private var libraryView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.filteredPhotos.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 44))
                        .foregroundStyle(.tertiary)
                    Text("No photos yet.")
                        .font(.title3.weight(.semibold))
                    Text("Connect a drive and tap Import to start.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
            } else {
                LazyVGrid(columns: photoColumns, spacing: 16) {
                    ForEach(store.filteredPhotos) { photo in
                        PhotoCard(photo: photo, isSelected: store.selectedPhotoID == photo.id)
                            .onTapGesture {
                                store.select(photo)
                            }
                            .zIndex(store.selectedPhotoID == photo.id ? 1 : 0)
                    }
                }
            }
        }
    }

    private var drivesView: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "Connected Drives",
                subtitle: "Originals remain where they are. The app tracks each volume, ingest status, and reconciliation state."
            )
            Divider()
            ForEach(store.drives) { drive in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(drive.name)
                                .font(.headline)
                            Text(drive.mountPoint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if drive.needsAttention {
                            Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    ProgressView(value: drive.progress)
                    HStack(spacing: 24) {
                        Label("\(drive.photoCount) photos", systemImage: "photo.on.rectangle")
                        Label(
                            String(format: "%.1f TB free / %.1f TB", drive.freeSpaceTB, drive.totalSpaceTB),
                            systemImage: "internaldrive"
                        )
                        Label(
                            drive.lastSeen.formatted(date: .abbreviated, time: .shortened),
                            systemImage: "clock"
                        )
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
        }
    }

    private var importsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "Import Pipeline",
                subtitle: "Every file moves through: discovered → indexed → proxy ready → metadata enriched → sync pending."
            )
            Divider()
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(ImportStage.allCases) { stage in
                        HStack(alignment: .top, spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(store.selectedImportStage == stage ? Color.accentColor : Color.gray.opacity(0.2))
                                    .frame(width: 28, height: 28)
                                Image(systemName: store.selectedImportStage == stage ? "checkmark" : "circle.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(store.selectedImportStage == stage ? .white : .secondary)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(stage.title).font(.headline)
                                Text(stage.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(store.selectedImportStage == stage ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                        )
                        .onTapGesture { store.selectedImportStage = stage }
                    }
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text("Pending Assets").font(.headline)
                    ForEach(store.photos.filter { $0.processingState != .metadataEnriched }) { photo in
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.linearGradient(colors: photo.gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 70, height: 70)
                                .overlay {
                                    Image(systemName: "photo").font(.title3).foregroundStyle(.white.opacity(0.85))
                                }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(photo.displayTitle).font(.headline)
                                Text(photo.canonicalName).font(.caption).foregroundStyle(.secondary)
                                StatusPill(title: photo.processingState.title, tint: .orange)
                            }
                            Spacer()
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                        .onTapGesture { store.select(photo) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var printLabView: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "Print Lab",
                subtitle: "Every paper, curve, chemistry note, and photographed result attached to the image forever."
            )
            Divider()
            ForEach(store.photos.filter { !$0.printRecipes.isEmpty }) { photo in
                VStack(alignment: .leading, spacing: 12) {
                    Text(photo.displayTitle).font(.headline)
                    ForEach(photo.printRecipes) { recipe in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(recipe.processName).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(recipe.lastUsed, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Paper: \(recipe.paper) • Curve: \(recipe.curveName)").font(.caption).foregroundStyle(.secondary)
                            Text(recipe.notes).font(.caption)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
                    }
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                .onTapGesture { store.select(photo) }
            }
        }
    }

    private var activityView: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "Activity",
                subtitle: "Recent search sessions, print experiments, and import progress."
            )
            Divider()
            ForEach(store.activities) { activity in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: activity.kind.systemImage)
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(activity.title).font(.headline)
                            Spacer()
                            Text(activity.timestamp, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(activity.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
    }

    private var sectionSubtitle: String {
        switch store.selectedSection {
        case .library: "Catalog of originals, derivatives, and in-progress assets."
        case .search: "Natural-language discovery on local metadata and local ML."
        case .map: "Geotagged photos plotted on a map with cluster-based filtering."
        case .drives, .imports: "Connected storage, ingest progress, and reconciliation state."
        case .jobs: "Triage imported photos into jobs — cluster, label, and track completeness."
        case .workflows: "Apply transforms, annotations, and batch jobs to selected photos."
        case .printLab: "Persistent recipes, curves, and print history per image."
        case .studio: "Artistic rendering from photos — oil, watercolor, charcoal, and more."
        case .people: "Label faces, run auto-match, and send borderline matches to Claude."
        case .activity: "What happened recently and what still needs attention."
        case .settings: ""
        }
    }
}

// MARK: - ActivityFeedSection (production: wires ActivityFeedView from environment)

/// Reads ActivityEventRepository + ActivityEventService from the SwiftUI environment
/// and renders the real ActivityFeedView. Falls back to a placeholder if the services
/// are unavailable (e.g., in mock previews).
private struct ActivityFeedSection: View {
    @Environment(\.activityEventService) private var activityEventService: ActivityEventService?
    @Environment(\.activityEventRepository) private var activityEventRepository: ActivityEventRepository?
    @Environment(\.appDatabase) private var appDatabase: AppDatabase?
    var onResumeInPrintLab: ((PrintJobSnapshot) -> Void)?
    var onApplyAISuggestion: ((PrintJobSnapshot, Double, Double) -> Void)?
    var onSendBatchToWorkflow: (([String]) -> Void)?
    var onOpenInStudio: (() -> Void)?
    var onOpenInJobs: ((String?) -> Void)?
    var onOpenInCurveLab: (() -> Void)?

    var body: some View {
        if let service = activityEventService, let repo = activityEventRepository {
            ActivityFeedView(
                viewModel: ActivityFeedViewModel(
                    repo: repo,
                    service: service,
                    photoRepo: appDatabase.map { PhotoRepository(db: $0) }
                ),
                onResumeInPrintLab: onResumeInPrintLab,
                onApplyAISuggestion: onApplyAISuggestion,
                onSendBatchToWorkflow: onSendBatchToWorkflow,
                onOpenInStudio: onOpenInStudio,
                onOpenInJobs: onOpenInJobs,
                onOpenInCurveLab: onOpenInCurveLab
            )
        } else {
            VStack(spacing: 16) {
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.system(size: 44))
                    .foregroundStyle(.tertiary)
                Text("Activity unavailable.")
                    .font(.title3.weight(.semibold))
                Text("Activity service not injected into the environment.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - ActivityLogView

private struct ActivityLogView: View {
    @Environment(\.appDatabase) private var appDatabase: AppDatabase?
    @State private var records: [ActivityDB] = []

    var body: some View {
        Group {
            if records.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                        .font(.system(size: 44))
                        .foregroundStyle(.tertiary)
                    Text("No activity yet.")
                        .font(.title3.weight(.semibold))
                    Text("Activity will appear here as you import drives, run workflows, and print.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(records) { record in
                            ActivityRow(record: record)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }
        }
        .task {
            guard let db = appDatabase else { return }
            let observation = ValueObservation.tracking {
                try ActivityDB.order(Column("timestamp").desc).limit(200).fetchAll($0)
            }
            do {
                for try await rows in observation.values(in: db.dbPool) {
                    records = rows
                }
            } catch {}
        }
    }
}

private struct ActivityRow: View {
    let record: ActivityDB

    private var kindIcon: String {
        switch ActivityKind(rawValue: record.kind) {
        case .workflowGenerated: "arrow.triangle.2.circlepath.circle.fill"
        case .printLogged:       "printer.fill"
        case .importCompleted:   "tray.and.arrow.down.fill"
        case .searchRun:         "magnifyingglass.circle.fill"
        case .noteAdded:         "note.text"
        case .none:              "clock.fill"
        }
    }

    private var formattedTime: String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: record.timestamp) else { return record.timestamp }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return rel.localizedString(for: date, relativeTo: Date())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: kindIcon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(record.title).font(.headline)
                    Spacer()
                    Text(formattedTime).font(.caption).foregroundStyle(.secondary)
                }
                Text(record.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
    }
}

// MARK: - Photo frame preference key for rubberband selection

private struct PhotoFrameData: Equatable {
    let id: String
    let frame: CGRect
}

private struct PhotoFramesKey: PreferenceKey {
    static var defaultValue: [PhotoFrameData] = []
    static func reduce(value: inout [PhotoFrameData], nextValue: () -> [PhotoFrameData]) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - LibraryWorkspaceView (production: LibraryViewModel with full curation UI)

struct LibraryWorkspaceView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Binding var inspectorVisible: Bool
    private let db: AppDatabase

    // Drag-to-select state
    @State private var dragStart: CGPoint? = nil
    @State private var dragCurrent: CGPoint? = nil
    @State private var photoFrames: [String: CGRect] = [:]

    // Note input state
    @State private var noteInputPhotoIds: [String] = []
    @State private var showingNoteInput: Bool = false
    @State private var showingPermanentDeleteConfirm: Bool = false
    @State private var showingDustRemoval: Bool = false

    // Keyboard-driven preview trigger
    @State private var previewPhotoID: String? = nil

    // Keyboard curation flash (P / X / U) — shown briefly over the grid
    @State private var curationFlashState: CurationState? = nil
    @State private var curationFlashVisible: Bool = false

    // Albums popover (moved from sidebar into library toolbar)
    @State private var showAlbumsPopover = false

    // Curation filter disclosure
    @State private var curationFilterExpanded = false

    // Imports enrichment filter + grid
    @State private var enrichFilter: EnrichFilter = .all
    @State private var importsGridColumns: Double = 3

    // Search palette
    @State private var showSearchPalette = false
    @State private var paletteQuery = ""

    private var selectionDragRect: CGRect? {
        guard let s = dragStart, let c = dragCurrent,
              abs(c.x - s.x) > 4 || abs(c.y - s.y) > 4 else { return nil }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y),
                      width: abs(c.x - s.x), height: abs(c.y - s.y))
    }

    @StateObject private var reviewViewModel: ReviewModeViewModel

    init(viewModel: LibraryViewModel, db: AppDatabase, inspectorVisible: Binding<Bool>) {
        self.viewModel = viewModel
        self.db = db
        self._inspectorVisible = inspectorVisible
        self._reviewViewModel = StateObject(
            wrappedValue: ReviewModeViewModel(photoRepo: viewModel.photoRepo)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.showDevelopMode {
                libraryToolbarStrip
                    .background(Color(nsColor: .controlBackgroundColor))

                Divider()
            }

            if viewModel.showDevelopMode, viewModel.developPhoto != nil {
                DevelopView(
                    viewModel: viewModel,
                    isPresented: $viewModel.showDevelopMode
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else if viewModel.showReviewMode {
                ReviewModeView(
                    viewModel: reviewViewModel,
                    onDismiss: { viewModel.showReviewMode = false }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { reviewViewModel.loadPhotos(viewModel.filteredPhotos) }
            } else {
                if viewModel.selectedSection == .library {
                    VStack(spacing: 0) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                curationFilterExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: curationFilterExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                Text("Filters")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                if let f = viewModel.curationFilter {
                                    Text("· \(f.title)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(f.tint)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)

                        if curationFilterExpanded {
                            CurationFilterBar(
                                counts: viewModel.curationCounts,
                                selectedFilter: $viewModel.curationFilter
                            )
                            .padding(.horizontal, 18)
                            .padding(.vertical, 6)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor))

                    Divider()
                }

                if viewModel.curationFilter == .deleted {
                    deletedModeActionBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Divider()
                } else if !viewModel.selectedPhotoIDs.isEmpty &&
                   (viewModel.selectedSection == .library || viewModel.selectedSection == .search) {
                    lwvBulkActionBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Divider()
                }

                sectionContentArea
            }
        }
        .sheet(isPresented: $showingNoteInput) {
            NoteInputSheet(photoIds: noteInputPhotoIds, db: db)
        }
        .sheet(isPresented: $showingDustRemoval) {
            BatchDustRemovalView(photoIds: Array(viewModel.selectedPhotoIDs))
        }
    }

    // MARK: - Toolbar

    private var libraryToolbarStrip: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.showDevelopMode ? "Develop" : viewModel.showReviewMode ? "Review" : viewModel.selectedSection.title)
                    .font(.system(size: 17, weight: .bold))
                if viewModel.selectedSection == .printLab {
                    printLabBreadcrumb
                } else if viewModel.selectedSection == .search {
                    searchBreadcrumb
                } else {
                    Text(viewModel.showDevelopMode ? (viewModel.developPhoto?.canonicalName ?? "") : viewModel.showReviewMode ? "P = Keeper · X = Reject · ← → Navigate" : viewModel.selectedSection.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if viewModel.showReviewMode {
                Button {
                    viewModel.showReviewMode = false
                } label: {
                    Label("Done", systemImage: "chevron.left")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.bordered)
            } else if viewModel.selectedSection == .library {
                // Develop button
                Button {
                    if let photoId = viewModel.selectedPhotoIDs.first,
                       let photo = viewModel.photos.first(where: { $0.id == photoId }) {
                        viewModel.developPhoto = photo
                    } else if let first = viewModel.filteredPhotos.first {
                        viewModel.developPhoto = first
                    }
                    if viewModel.developPhoto != nil {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            viewModel.showDevelopMode = true
                        }
                    }
                } label: {
                    Label("Develop", systemImage: "camera.filters")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("d", modifiers: .command)
                .help("Enter full-screen develop mode (⌘D)")

            }

            // TODO: Albums button hidden — revisit for shareable album links
            // if viewModel.selectedSection == .library && !viewModel.showReviewMode {
            //     Button { showAlbumsPopover = true } label: {
            //         Label("Albums", systemImage: "folder.fill")
            //             .font(.system(size: 13, weight: .medium))
            //     }
            //     .buttonStyle(.bordered)
            //     .controlSize(.small)
            //     .popover(isPresented: $showAlbumsPopover, arrowEdge: .bottom) {
            //         SmartAlbumPopoverView(...)
            //     }
            // }

            if !viewModel.showReviewMode && viewModel.selectedSection != .printLab
                && viewModel.selectedSection != .search {
                // Search palette button
                Button {
                    paletteQuery = ""
                    showSearchPalette = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .medium))
                        Text("Search")
                            .font(.system(size: 13))
                        Spacer()
                        Image(systemName: "mic")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .frame(width: 200)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                            )
                    )
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showSearchPalette, arrowEdge: .bottom) {
                    SearchPaletteView(
                        query: $paletteQuery,
                        onSubmit: { query in
                            viewModel.searchText = query
                            viewModel.selectedSection = .search
                            showSearchPalette = false
                            Task { await viewModel.executeSearch() }
                        }
                    )
                }

                Divider().frame(height: 22)
            }

            if !viewModel.showReviewMode && viewModel.selectedSection == .library {
                Menu {
                    ForEach(LibrarySortOrder.allCases) { order in
                        Button {
                            viewModel.sortOrder = order
                        } label: {
                            if viewModel.sortOrder == order {
                                Label(order.label, systemImage: "checkmark")
                            } else {
                                Text(order.label)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 13, weight: .medium))
                        Text(viewModel.sortOrder.shortLabel)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Sort photos")
            }

            if !viewModel.showReviewMode &&
               viewModel.selectedSection == .library {
                Divider().frame(height: 22)

                let binding: Binding<Double> = $viewModel.gridColumns

                HStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Slider(value: binding, in: 2...8, step: 1)
                        .frame(width: 90)
                    Image(systemName: "square.grid.3x3")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .help("Grid columns: \(Int(binding.wrappedValue.rounded()))")
            }

            SyncToolbarIndicator()

            if viewModel.selectedSection != .printLab && viewModel.selectedSection != .drives {
                let hasPhoto = viewModel.selectedPhoto != nil
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { inspectorVisible.toggle() }
                } label: {
                    Image(systemName: "sidebar.right")
                        .symbolVariant(inspectorVisible ? .fill : .none)
                        .font(.system(size: 15, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(hasPhoto && inspectorVisible ? Color.accentColor : .secondary)
                .disabled(!hasPhoto)
                .help(hasPhoto
                    ? (inspectorVisible ? "Hide Inspector" : "Show Inspector")
                    : "Select a photo to open Inspector")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .onChange(of: viewModel.selectedSection) { _, section in
            if section != .library && section != .search && inspectorVisible {
                withAnimation(.easeInOut(duration: 0.2)) { inspectorVisible = false }
            }
            if section == .library {
                viewModel.searchResults = []
                viewModel.searchText = ""
            }
        }
    }

    // MARK: - Print Lab Breadcrumb

    private var printLabBreadcrumb: some View {
        HStack(spacing: 4) {
            let parts = viewModel.printLabViewModel.breadcrumbSubtitle.split(separator: "›").map(String.init)
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.quaternary)
                }
                Text(part.trimmingCharacters(in: .whitespaces))
                    .font(.caption)
                    .foregroundStyle(index == parts.count - 1 ? .secondary : .tertiary)
            }
        }
    }

    // MARK: - Search Breadcrumb

    private var searchBreadcrumb: some View {
        Text(viewModel.searchBreadcrumbSubtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Compact selection action bar

    private var deletedModeActionBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash.fill").foregroundStyle(.gray)
            Text("\(viewModel.curationCounts.deleted) photo\(viewModel.curationCounts.deleted == 1 ? "" : "s") in Trash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer()

            if !viewModel.selectedPhotoIDs.isEmpty {
                Text("\(viewModel.selectedPhotoIDs.count) selected")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Button {
                    Task { await viewModel.applyCuration(.needsReview, to: viewModel.selectedPhotoIDs) }
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered).controlSize(.small).tint(.blue)

                Button {
                    showingPermanentDeleteConfirm = true
                } label: {
                    Label("Permanently Delete", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent).controlSize(.small).tint(.red)
                .confirmationDialog(
                    "Permanently delete \(viewModel.selectedPhotoIDs.count) photo\(viewModel.selectedPhotoIDs.count == 1 ? "" : "s")?",
                    isPresented: $showingPermanentDeleteConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Delete Permanently", role: .destructive) {
                        let ids = viewModel.selectedPhotoIDs
                        Task { await viewModel.permanentlyDelete(ids: ids) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The original files will be moved to the Finder Trash. This cannot be undone from within the app.")
                }
            } else {
                Text("Select photos to restore or permanently delete")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.08))
    }

    private var lwvBulkActionBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
            Text("\(viewModel.selectedPhotoIDs.count) selected")
                .font(.system(size: 13, weight: .semibold))

            Divider().frame(height: 20)

            Button {
                Task { await viewModel.applyCuration(.keeper, to: viewModel.selectedPhotoIDs) }
            } label: { Label("Keeper", systemImage: "star.fill") }
            .buttonStyle(.bordered).controlSize(.small).tint(.yellow)

            Button {
                Task { await viewModel.applyCuration(.archive, to: viewModel.selectedPhotoIDs) }
            } label: { Label("Archive", systemImage: "archivebox") }
            .buttonStyle(.bordered).controlSize(.small)

            Button {
                Task { await viewModel.applyCuration(.needsReview, to: viewModel.selectedPhotoIDs) }
            } label: { Label("Needs Review", systemImage: "exclamationmark.circle") }
            .buttonStyle(.bordered).controlSize(.small)

            Button {
                Task { await viewModel.applyCuration(.rejected, to: viewModel.selectedPhotoIDs) }
            } label: { Label("Reject", systemImage: "xmark.circle") }
            .buttonStyle(.bordered).controlSize(.small).tint(.red)

            Spacer()

            // Auto-orient selected photos via ML model
            if viewModel.isAutoOrienting, let progress = viewModel.autoOrientProgress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Orienting \(progress.completed)/\(progress.total)…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    let targets = viewModel.filteredPhotos.filter {
                        viewModel.selectedPhotoIDs.contains($0.id)
                    }
                    Task { await viewModel.runAutoOrient(targetPhotos: targets, db: db) }
                } label: { Label("Auto-Orient", systemImage: "rotate.right") }
                .buttonStyle(.bordered).controlSize(.small).tint(.indigo)
                .help("Detect and correct rotation for selected photos using the ML orientation model")
            }

            // Background batch editorial review (Haiku — fast)
            if viewModel.batchEditorialRunning, let progress = viewModel.batchEditorialProgress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Review \(progress.completed)/\(progress.total)…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    let ids = Array(viewModel.selectedPhotoIDs)
                    Task { await viewModel.runBatchEditorialReview(photoIds: ids, db: db) }
                } label: { Label("Review", systemImage: "text.bubble") }
                .buttonStyle(.bordered).controlSize(.small).tint(.purple)
                .help("Run editorial reviews in background using Haiku (fast, concurrent)")
            }

            Button {
                showingDustRemoval = true
            } label: { Label("Clean Dust", systemImage: "sparkle.magnifyingglass") }
            .buttonStyle(.bordered).controlSize(.small).tint(.orange)
            .help("Run film dust & hair removal on selected photos")

            Button {
                viewModel.workflowPhotoIDs = Array(viewModel.selectedPhotoIDs)
                viewModel.selectedPhotoIDs = []
                viewModel.selectedSection = .workflows
            } label: { Label("Workflow", systemImage: "arrow.triangle.2.circlepath.circle") }
            .buttonStyle(.borderedProminent).controlSize(.small)

            Button {
                noteInputPhotoIds = Array(viewModel.selectedPhotoIDs)
                showingNoteInput = true
            } label: { Label("Add Note", systemImage: "note.text.badge.plus") }
            .buttonStyle(.bordered).controlSize(.small).tint(.purple)

            Button("Deselect All") { viewModel.selectedPhotoIDs = [] }
                .buttonStyle(.bordered).controlSize(.small).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Section routing

    @ViewBuilder
    private var sectionContentArea: some View {
        switch viewModel.selectedSection {
        case .search:
            SearchHostView(viewModel: viewModel, db: db)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .library:
            ScrollView {
                photoGridContent
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 24)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay {
                // Keyboard shortcuts (invisible, zero-size)
                VStack {
                    Button("") {
                        viewModel.selectedPhotoIDs = Set(viewModel.filteredPhotos.map { $0.id })
                    }
                    .keyboardShortcut("a", modifiers: .command)
                    Button("") {
                        viewModel.selectedPhotoIDs = []
                        viewModel.selectedPhotoID = nil
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    Button("") {
                        viewModel.selectedPhotoIDs = []
                        viewModel.selectedPhotoID = nil
                    }
                    .keyboardShortcut(.escape, modifiers: .command)
                    // Arrow key navigation
                    Button("") { moveSelection(by: -1) }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Button("") { moveSelection(by: 1) }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                    Button("") { moveSelection(by: -gridColumnCount) }
                        .keyboardShortcut(.upArrow, modifiers: [])
                    Button("") { moveSelection(by: gridColumnCount) }
                        .keyboardShortcut(.downArrow, modifiers: [])
                    // Space: toggle focused photo into multi-select
                    Button("") {
                        guard let id = viewModel.selectedPhotoID else { return }
                        if viewModel.selectedPhotoIDs.contains(id) {
                            viewModel.selectedPhotoIDs.remove(id)
                        } else {
                            viewModel.selectedPhotoIDs.insert(id)
                        }
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    // Enter: open full-screen preview for focused photo
                    Button("") {
                        guard let id = viewModel.selectedPhotoID else { return }
                        previewPhotoID = id
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            previewPhotoID = nil
                        }
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    // P: Pick / Keeper (auto-advance)
                    Button("") {
                        guard viewModel.selectedPhotoID != nil else { return }
                        triggerCurationFlash(.keeper)
                        Task { await viewModel.curateSelected(.keeper, autoAdvance: true) }
                    }
                    .keyboardShortcut("p", modifiers: [])
                    // X: Reject (auto-advance)
                    Button("") {
                        guard viewModel.selectedPhotoID != nil else { return }
                        triggerCurationFlash(.rejected)
                        Task { await viewModel.curateSelected(.rejected, autoAdvance: true) }
                    }
                    .keyboardShortcut("x", modifiers: [])
                    // U: Unflag / Needs Review (no auto-advance)
                    Button("") {
                        guard viewModel.selectedPhotoID != nil else { return }
                        triggerCurationFlash(.needsReview)
                        Task { await viewModel.curateSelected(.needsReview, autoAdvance: false) }
                    }
                    .keyboardShortcut("u", modifiers: [])
                }
                .opacity(0)
                .allowsHitTesting(false)
            }
            // Curation flash overlay (P / X / U)
            .overlay(alignment: .top) {
                if curationFlashVisible, let flash = curationFlashState {
                    CurationFlashBadge(state: flash)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        .padding(.top, 20)
                }
            }
            Divider()
            breadcrumbBarVM.background(Color(nsColor: .controlBackgroundColor))

        case .printLab:
            PrintLabHostView(
                viewModel: viewModel.printLabViewModel,
                libraryPhotos: viewModel.photos
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .studio:
            StudioHostView(viewModel: viewModel.studioViewModel, libraryPhotos: viewModel.photos)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .drives, .imports:
            drivesSection

        case .jobs:
            JobsView(viewModel: viewModel)

        case .workflows:
            WorkflowsView(viewModel: viewModel)

        case .people:
            FaceGalleryView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .activity:
            ActivityFeedSection(
                onResumeInPrintLab: { snapshot in
                    Task {
                        _ = await viewModel.printLabViewModel.restoreFromSnapshot(snapshot)
                        viewModel.selectedSection = .printLab
                    }
                },
                onApplyAISuggestion: { snapshot, center, range in
                    Task {
                        _ = await viewModel.printLabViewModel.applyAISuggestion(
                            snapshot: snapshot,
                            brightnessCenter: center,
                            range: range
                        )
                        viewModel.selectedSection = .printLab
                    }
                },
                onSendBatchToWorkflow: { photoIds in
                    viewModel.workflowPhotoIDs = photoIds
                    viewModel.selectedSection = .workflows
                },
                onOpenInStudio: {
                    viewModel.selectedSection = .studio
                },
                onOpenInJobs: { jobId in
                    viewModel.pendingJobSelection = jobId
                    viewModel.selectedSection = .jobs
                },
                onOpenInCurveLab: {
                    viewModel.selectedSection = .printLab
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        default:
            Spacer()
        }
    }

    // MARK: - Photo grid

    private var gridColumnCount: Int { max(2, Int(viewModel.gridColumns.rounded())) }

    private var photoColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 150, maximum: 220), spacing: 16),
            count: gridColumnCount
        )
    }

    private func moveSelection(by delta: Int) {
        let photos = viewModel.filteredPhotos
        guard !photos.isEmpty else { return }
        let currentID = viewModel.selectedPhotoID ?? photos[0].id
        guard let idx = photos.firstIndex(where: { $0.id == currentID }) else {
            viewModel.select(photos[0])
            return
        }
        let newIdx = max(0, min(photos.count - 1, idx + delta))
        viewModel.select(photos[newIdx])
        withAnimation(.easeInOut(duration: 0.2)) { inspectorVisible = true }
    }

    /// Flash a brief curation badge at the top of the grid to confirm a P / X / U keystroke.
    private func triggerCurationFlash(_ state: CurationState) {
        curationFlashState = state
        withAnimation(.easeInOut(duration: 0.15)) { curationFlashVisible = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            withAnimation(.easeOut(duration: 0.25)) { curationFlashVisible = false }
        }
    }

    @ViewBuilder
    private var photoGridContent: some View {
        if viewModel.filteredPhotos.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 44)).foregroundStyle(.tertiary)
                Text("No photos match the current filter.").font(.title3.weight(.semibold))
                Text("Try a different curation filter or search term.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.top, 80)
        } else {
            ZStack(alignment: .topLeading) {
                // Background context menu on empty space
                Color.clear
                    .contentShape(Rectangle())
                    .contextMenu {
                        if !viewModel.selectedPhotoIDs.isEmpty {
                            Button("Deselect All") {
                                viewModel.selectedPhotoIDs = []
                                viewModel.selectedPhotoID = nil
                            }
                        }
                    }

                LazyVGrid(columns: photoColumns, spacing: 16) {
                    ForEach(viewModel.filteredPhotos) { photo in
                        PhotoCardAsset(
                            photo: photo,
                            isSelected: viewModel.selectedPhotoID == photo.id
                                || viewModel.selectedPhotoIDs.contains(photo.id),
                            isPendingSelection: selectionDragRect.flatMap { rect in
                                photoFrames[photo.id].map { $0.intersects(rect) }
                            } ?? false,
                            forceShowPreview: previewPhotoID == photo.id,
                            onQuickCuration: { state in
                                Task { await viewModel.applyCuration(state, to: [photo.id]) }
                            },
                            onOpenInspector: {
                                withAnimation(.easeInOut(duration: 0.2)) { inspectorVisible = true }
                            },
                            onAddNote: {
                                let ids = viewModel.selectedPhotoIDs.contains(photo.id) && viewModel.selectedPhotoIDs.count > 1
                                    ? Array(viewModel.selectedPhotoIDs)
                                    : [photo.id]
                                noteInputPhotoIds = ids
                                showingNoteInput = true
                            },
                            onSendToPrintLab: {
                                viewModel.sendToPrintLab(photo)
                            },
                            onSendToWorkflow: {
                                viewModel.sendToWorkflow(photo)
                            },
                            onRemoveFromLibrary: {
                                let ids: Set<String> = viewModel.selectedPhotoIDs.contains(photo.id) && viewModel.selectedPhotoIDs.count > 1
                                    ? viewModel.selectedPhotoIDs
                                    : [photo.id]
                                Task { await viewModel.applyCuration(.deleted, to: ids) }
                            },
                            viewModel: viewModel
                        )
                        .background(GeometryReader { geo in
                            Color.clear.preference(
                                key: PhotoFramesKey.self,
                                value: [PhotoFrameData(
                                    id: photo.id,
                                    frame: geo.frame(in: .named("lwvGrid"))
                                )]
                            )
                        })
                        .simultaneousGesture(TapGesture().onEnded { _ in
                            if NSEvent.modifierFlags.contains(.command) {
                                if viewModel.selectedPhotoIDs.contains(photo.id) {
                                    viewModel.selectedPhotoIDs.remove(photo.id)
                                } else {
                                    viewModel.selectedPhotoIDs.insert(photo.id)
                                }
                            } else if NSEvent.modifierFlags.contains(.shift),
                                      !viewModel.selectedPhotoIDs.isEmpty {
                                // Shift+click: range select
                                let ids = viewModel.filteredPhotos.map { $0.id }
                                let existing = viewModel.selectedPhotoIDs
                                if let last = ids.last(where: { existing.contains($0) }),
                                   let li = ids.firstIndex(of: last),
                                   let ci = ids.firstIndex(of: photo.id) {
                                    let range = li < ci ? li...ci : ci...li
                                    viewModel.selectedPhotoIDs.formUnion(ids[range])
                                }
                            } else if !viewModel.selectedPhotoIDs.isEmpty {
                                // Multi-select mode: click toggles
                                if viewModel.selectedPhotoIDs.contains(photo.id) {
                                    viewModel.selectedPhotoIDs.remove(photo.id)
                                } else {
                                    viewModel.selectedPhotoIDs.insert(photo.id)
                                }
                            } else {
                                viewModel.select(photo)
                                withAnimation(.easeInOut(duration: 0.2)) { inspectorVisible = true }
                            }
                        })
                        .contextMenu {
                            if viewModel.selectedPhotoIDs.contains(photo.id) {
                                Button("Deselect") { viewModel.selectedPhotoIDs.remove(photo.id) }
                                Button("Deselect All") { viewModel.selectedPhotoIDs = [] }
                            } else {
                                Button("Select") { viewModel.selectedPhotoIDs.insert(photo.id) }
                            }
                            Divider()
                            Button("Mark Keeper") {
                                let ids: Set<String> = viewModel.selectedPhotoIDs.isEmpty
                                    ? [photo.id] : viewModel.selectedPhotoIDs
                                Task { await viewModel.applyCuration(.keeper, to: ids) }
                            }
                            Button("Archive") {
                                let ids: Set<String> = viewModel.selectedPhotoIDs.isEmpty
                                    ? [photo.id] : viewModel.selectedPhotoIDs
                                Task { await viewModel.applyCuration(.archive, to: ids) }
                            }
                            Button("Reject") {
                                let ids: Set<String> = viewModel.selectedPhotoIDs.isEmpty
                                    ? [photo.id] : viewModel.selectedPhotoIDs
                                Task { await viewModel.applyCuration(.rejected, to: ids) }
                            }
                            Divider()
                            Button {
                                viewModel.sendToPrintLab(photo)
                            } label: {
                                Label("Open in Print Lab", systemImage: "printer")
                            }
                            Divider()
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [URL(fileURLWithPath: photo.filePath)]
                                )
                            } label: {
                                Label("Show in Finder", systemImage: "folder")
                            }
                        }
                        .zIndex((viewModel.selectedPhotoID == photo.id || viewModel.selectedPhotoIDs.contains(photo.id)) ? 1 : 0)
                    }
                }
                .onPreferenceChange(PhotoFramesKey.self) { data in
                    photoFrames = Dictionary(data.map { ($0.id, $0.frame) }, uniquingKeysWith: { $1 })
                }

                // Rubber-band selection rectangle overlay
                if let rect = selectionDragRect {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.accentColor, lineWidth: 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.12)))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "lwvGrid")
            // Rubber-band drag: simultaneousGesture fires regardless of where the drag starts,
            // so it works both from empty space and from on top of a photo card.
            .simultaneousGesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named("lwvGrid"))
                    .onChanged { v in
                        if dragStart == nil { dragStart = v.startLocation }
                        if dragStart != nil { dragCurrent = v.location }
                    }
                    .onEnded { _ in
                        if let rect = selectionDragRect {
                            let ids = photoFrames
                                .filter { $0.value.intersects(rect) }
                                .map { $0.key }
                            if NSEvent.modifierFlags.contains(.command)
                                || NSEvent.modifierFlags.contains(.shift) {
                                viewModel.selectedPhotoIDs.formUnion(ids)
                            } else {
                                viewModel.selectedPhotoIDs = Set(ids)
                            }
                        } else {
                            viewModel.selectedPhotoIDs = []
                            viewModel.selectedPhotoID = nil
                        }
                        dragStart = nil
                        dragCurrent = nil
                    }
            )
        }
    }

    // MARK: - Section content helpers

    private var drivesSection: some View {
        DriveBrowserView()
            .environment(\.libraryViewModel, viewModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var importsSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader(
                        title: "Review & Enrich",
                        subtitle: "Find gaps in imported photos — add captions, detect faces, tag locations, and log gear."
                    )
                    Spacer()
                    let needsWork = viewModel.photos.filter { !$0.metadataGaps.isEmpty }.count
                    if needsWork > 0 {
                        Text("\(needsWork) need attention")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }

                Divider()

                // Filter chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(EnrichFilter.allCases) { filter in
                            Button {
                                enrichFilter = filter
                            } label: {
                                Text(filter.label)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(
                                        enrichFilter == filter ? Color.accentColor : Color(nsColor: .controlBackgroundColor)
                                    ))
                                    .foregroundStyle(enrichFilter == filter ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Photo grid
                let filtered = viewModel.photos.filter { photo in
                    switch enrichFilter {
                    case .all: true
                    case .noExif: photo.rawExifJson == nil
                    case .noCaption: photo.userMetadataJson == nil
                    case .noFaces: photo.peopleDetected == nil
                    case .noScene: photo.sceneType == nil
                    }
                }

                if filtered.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.green.opacity(0.7))
                        Text("All photos are enriched for this filter.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
                } else {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(minimum: 160)), count: Int(importsGridColumns)),
                        spacing: 14
                    ) {
                        ForEach(filtered) { photo in
                            EnrichPhotoCard(
                                photo: photo,
                                photoRepo: viewModel.photoRepo,
                                onSelect: { viewModel.select(photo) }
                            )
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Breadcrumb

    private var breadcrumbBarVM: some View {
        HStack(spacing: 5) {
            Text("HoehnPhotos").foregroundStyle(.quaternary)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.quaternary)
            Text(viewModel.selectedSection.title).foregroundStyle(.tertiary)
            if let filter = viewModel.curationFilter {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.quaternary)
                Text(filter.title).foregroundStyle(.secondary)
            }
            Spacer()
            StatusIndicatorsView(
                driveCount: viewModel.detectedDrives.count,
                cloudAIActive: viewModel.cloudAIConfigured
            )
        }
        .font(.caption)
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
    }
}

// MARK: - Enrich Filter

enum EnrichFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case noExif = "No EXIF"
    case noCaption = "No Caption"
    case noFaces = "Faces Unscanned"
    case noScene = "No Scene Tag"

    var id: String { rawValue }
    var label: String { rawValue }
}

// MARK: - Enrich Photo Card

private struct EnrichPhotoCard: View {
    let photo: PhotoAsset
    let photoRepo: PhotoRepository
    let onSelect: () -> Void

    @State private var showGearSheet = false
    @State private var proxyImage: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Thumbnail with processing badge
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let img = proxyImage {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.linearGradient(
                                colors: photo.placeholderGradient,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(height: 120)
                            .overlay {
                                Image(systemName: "photo")
                                    .font(.title2)
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                    }
                }
                StatusPill(
                    title: photo.processingStateEnum.title,
                    tint: photo.processingStateEnum == .metadataEnriched ? .green : .orange
                )
                .padding(8)
            }

            // File name
            Text(photo.canonicalName)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)

            // Gap pills
            let gaps = photo.metadataGaps
            if !gaps.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(gaps) { gap in
                            Label(gap.rawValue, systemImage: gap.icon)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(gap.tint.opacity(0.15)))
                                .foregroundStyle(gap.tint)
                        }
                    }
                }
            } else {
                Label("Fully enriched", systemImage: "checkmark.seal.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.green)
            }

            // Action buttons
            HStack(spacing: 6) {
                EnrichActionButton(icon: "wand.and.stars", label: "Caption", action: onSelect)
                EnrichActionButton(icon: "person.2.fill", label: "Faces", action: onSelect)
                EnrichActionButton(icon: "location.fill", label: "Locate", action: onSelect)
                EnrichActionButton(icon: "gearshape", label: "Gear") { showGearSheet = true }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .sheet(isPresented: $showGearSheet) {
            GearNotesSheet(photo: photo, photoRepo: photoRepo, onSaved: {})
        }
        .task(id: photo.id) {
            let baseName = (photo.canonicalName as NSString).deletingPathExtension
            let url = ProxyGenerationActor.thumbsDirectory()
                .appendingPathComponent(baseName + ".jpg")
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            proxyImage = await Task.detached(priority: .utility) {
                NSImage(contentsOf: url)
            }.value
        }
    }
}

private struct EnrichActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 11))
                Text(label).font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            )
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Search Palette

private struct SearchPaletteView: View {
    @Binding var query: String
    let onSubmit: (String) -> Void

    @FocusState private var focused: Bool

    private let templates: [(icon: String, label: String, query: String)] = [
        ("person.2.fill",      "People",          "photos with people"),
        ("mappin.and.ellipse", "Location",        "photos by location"),
        ("camera.aperture",    "Film",            "film photography"),
        ("star.fill",          "Keepers",         "keepers"),
        ("photo.artframe",     "Portfolio",       "portfolio candidates"),
        ("calendar",           "Recent",          "photos from this year"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Text input
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14))
                TextField("Search photos, places, people…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { if !query.isEmpty { onSubmit(query) } }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            // Templates
            VStack(alignment: .leading, spacing: 2) {
                Text("Templates")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                ForEach(templates, id: \.label) { t in
                    Button {
                        onSubmit(t.query)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: t.icon)
                                .font(.system(size: 12))
                                .frame(width: 18)
                                .foregroundStyle(.secondary)
                            Text(t.label)
                                .font(.system(size: 13))
                            Spacer()
                            Image(systemName: "arrow.up.left")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.001)) // hit-test
                    .hoverHighlight()
                }

                Divider().padding(.top, 4)

                Text("Press ↵ to search or pick a template above")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
        .frame(width: 300)
        .onAppear { focused = true }
    }
}

private extension View {
    func hoverHighlight() -> some View {
        self.modifier(HoverHighlightModifier())
    }
}

private struct HoverHighlightModifier: ViewModifier {
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .background(hovered ? Color(nsColor: .controlAccentColor).opacity(0.08) : .clear)
            .onHover { hovered = $0 }
    }
}

// MARK: - Curation flash badge (keyboard P / X / U confirmation)

private struct CurationFlashBadge: View {
    let state: CurationState

    private var icon: String {
        switch state {
        case .keeper:      return "star.fill"
        case .rejected:    return "xmark.circle.fill"
        case .needsReview: return "flag.slash.fill"
        default:           return "circle.fill"
        }
    }

    private var label: String {
        switch state {
        case .keeper:      return "Keeper"
        case .rejected:    return "Rejected"
        case .needsReview: return "Unflagged"
        default:           return state.rawValue
        }
    }

    private var tint: Color {
        switch state {
        case .keeper:      return .yellow
        case .rejected:    return .red
        case .needsReview: return .secondary
        default:           return .blue
        }
    }

    var body: some View {
        Label(label, systemImage: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
    }
}
