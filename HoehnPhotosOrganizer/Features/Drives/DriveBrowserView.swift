import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import os.log

// MARK: - Cursor helper

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Cell frame preference key (rubber-band selection)

private struct CellFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - DriveBrowserView

/// Root view for the Drives section.
/// Shows an overview of all detected removable volumes; tapping one navigates to a photo grid.
struct DriveBrowserView: View {

    @StateObject private var vm = DrivesOverviewViewModel()
    @State private var selectedDrive: MountedDriveState?
    @State private var scanPreviewDrive: MountedDriveState?
    @Environment(\.libraryViewModel) private var libraryViewModel
    @Environment(\.appDatabase) private var db

    var body: some View {
        Group {
            if let drive = selectedDrive {
                DrivePhotoGridView(drive: drive) {
                    selectedDrive = nil
                }
            } else {
                drivesOverview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $scanPreviewDrive) { drive in
            DriveScanPreviewSheet(
                drive: drive,
                onImport: { result, jobName, mode in
                    scanPreviewDrive = nil
                    handleScanImport(drive: drive, result: result, jobName: jobName, mode: mode)
                },
                onDismiss: { scanPreviewDrive = nil }
            )
        }
    }

    // MARK: - Overview

    private var drivesOverview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                overviewHeader

                if vm.mountedDrives.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 260, maximum: 320), spacing: 16)],
                        spacing: 16
                    ) {
                        ForEach(vm.mountedDrives) { drive in
                            DriveCard(drive: drive, onBrowse: {
                                selectedDrive = drive
                            }, onImport: {
                                scanPreviewDrive = drive
                            })
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private var overviewHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connected Drives")
                .font(.title2.weight(.semibold))
            Text("Browse photos on any attached drive without importing or copying files.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.slash")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No external drives detected")
                .font(.title3.weight(.semibold))
            Text("Connect a drive — it will appear here automatically.")
                .foregroundStyle(.secondary)
            Button("Refresh") { vm.refreshMountedVolumes() }
                .buttonStyle(BorderedButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: - Scan-to-import bridge

    /// Handles the result from DriveScanPreviewSheet: imports the scanned files into
    /// the library using importDigitalPhotosWithJobName, which creates a single triage
    /// job with the user's chosen name. Skips duplicates when "Import New Only" was chosen.
    private func handleScanImport(
        drive: MountedDriveState,
        result: DriveScanResult,
        jobName: String,
        mode: DriveScanPreviewSheet.ImportMode
    ) {
        let importLogger = Logger(subsystem: "HoehnPhotosOrganizer", category: "DriveScanImport")
        guard let vm = libraryViewModel, let database = db else { return }

        let files: [ScannedFile]
        switch mode {
        case .all:
            files = result.files
            importLogger.info("[DriveScanImport] Mode: all — importing \(result.files.count) file(s)")
        case .newOnly:
            files = result.files.filter { !result.duplicateFilenames.contains($0.deduplicationKey) }
            let skipped = result.files.count - files.count
            importLogger.info("[DriveScanImport] Mode: newOnly — \(result.files.count) total, \(skipped) duplicates skipped, \(files.count) to import")
        }

        guard !files.isEmpty else {
            importLogger.info("[DriveScanImport] No files to import after filtering")
            return
        }

        let urls = files.map(\.url)

        Task {
            await vm.importDigitalPhotosWithJobName(urls, db: database, jobName: jobName)
            importLogger.info("[DriveScanImport] Import complete for job '\(jobName)'")
        }
    }
}

// MARK: - DriveCard

private struct DriveCard: View {

    @ObservedObject var drive: MountedDriveState
    let onBrowse: () -> Void
    var onImport: (() -> Void)? = nil

    @State private var isHovered = false

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var usedOfTotalString: String {
        "\(formatBytes(drive.usedBytes)) of \(formatBytes(drive.totalBytes))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // Drive icon + name + chevron
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(drive.label)
                        .font(.headline)
                        .lineLimit(1)
                    Text(drive.mountPoint.path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            // Capacity bar
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(usedOfTotalString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if drive.capacityRatio > 0.9 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption2)
                    }
                }
                ProgressView(value: drive.capacityRatio)
                    .tint(drive.capacityRatio > 0.9 ? .orange : Color.accentColor)
            }

            // Index status row
            if drive.isIndexing {
                indexingProgress
            } else if drive.hasBeenIndexed {
                indexedStatus
            } else {
                notIndexedStatus
            }

            // Action buttons — stop propagation so they don't trigger card tap
            HStack(spacing: 8) {
                if drive.isIndexing {
                    Button("Stop") { drive.stopIndexing() }
                        .buttonStyle(BorderedButtonStyle())
                } else if drive.hasBeenIndexed {
                    Button("Re-Import") { onImport?() }
                        .buttonStyle(BorderedButtonStyle())
                    Button("Clear") { drive.forgetIndex() }
                        .buttonStyle(BorderedButtonStyle())
                        .foregroundStyle(.red)
                } else {
                    Button("Import") { onImport?() }
                        .buttonStyle(BorderedProminentButtonStyle())
                }
            }
            .font(.subheadline)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(isHovered ? 0.12 : 0.06), radius: isHovered ? 10 : 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isHovered ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1.5)
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { isHovered = $0 }
        .onTapGesture { onBrowse() }
        .cursor(.pointingHand)
    }

    @ViewBuilder
    private var indexingProgress: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: drive.currentStage.systemImage)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
                Text(drive.currentStage.rawValue)
                    .font(.caption.weight(.medium))
                Spacer()
                switch drive.currentStage {
                case .discovering:
                    if drive.totalFileCount > 0 {
                        Text("\(drive.totalFileCount) found")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                case .detectingDuplicates:
                    EmptyView()
                default:
                    if drive.totalFileCount > 0 {
                        Text("\(drive.indexedCount) / \(drive.totalFileCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if drive.currentStage == .detectingDuplicates {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Color.accentColor)
            } else {
                ProgressView(value: max(0.02, drive.indexProgress))
                    .tint(Color.accentColor)
            }
            if !drive.currentFilename.isEmpty {
                Text(drive.currentFilename)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if drive.folderCount > 0 {
                HStack(spacing: 8) {
                    Label("\(drive.folderCount)", systemImage: "folder")
                    Label("\(drive.rawCount) RAW", systemImage: "camera.aperture")
                    Label("\(drive.jpegCount) JPEG", systemImage: "photo")
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
            }
        }
    }

    @ViewBuilder
    private var indexedStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 11))
                Text("\(drive.photos.count) photos indexed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if drive.duplicateCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 11))
                    Text("\(drive.duplicateCount) duplicate files found")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var notIndexedStatus: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            Text("Not yet indexed")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - DrivePhotoGridView

/// Photo grid for a single drive.
struct DrivePhotoGridView: View {

    @Environment(\.appDatabase) private var db
    @Environment(\.libraryViewModel) private var libraryViewModel

    @ObservedObject var drive: MountedDriveState
    let onBack: () -> Void

    @State private var selectedPhoto: DrivePhotoRecord? = nil
    @State private var selectedPhotoIDs: Set<String> = []
    @State private var showImportSheet = false
    @State private var previewPhoto: DrivePhotoRecord?
    @State private var rubberBandStart: CGPoint?
    @State private var rubberBandCurrent: CGPoint?
    @State private var cellFrames: [String: CGRect] = [:]
    @State private var sortOrder: SortOrder = .captureDate
    @State private var searchText = ""
    @State private var showOnlyDuplicates = false
    @State private var showInspector = false

    @State private var photoForExtraction: DrivePhotoRecord? = nil
    @State private var completionBanner: String? = nil
    @State private var showScanPreview = false

    enum SortOrder: String, CaseIterable, Identifiable {
        case captureDate = "Date"
        case filename    = "Name"
        case fileSize    = "Size"
        var id: String { rawValue }
    }

    private struct PhotoDisplayItem: Identifiable {
        let photo: DrivePhotoRecord
        let formatCount: Int   // >1 when multiple formats share the same folder+stem
        let copyCount: Int?    // non-nil when duplicate_group_id is set
        var id: String { photo.id }
    }

    private static let nonRawExts: Set<String> = ["jpg","jpeg","heic","heif","png","tif","tiff"]

    /// Maps duplicate_group_id → number of photos sharing that group.
    private var groupCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for p in drive.photos {
            guard let g = p.duplicateGroupId else { continue }
            counts[g, default: 0] += 1
        }
        return counts
    }

    /// Deduplicate drive.photos by (folder, stem) — JPEG preferred over RAW.
    /// Returns one best record per group, tagged with how many formats exist in that group.
    private var deduplicatedPhotos: [PhotoDisplayItem] {
        let counts = groupCounts
        var groups: [String: [DrivePhotoRecord]] = [:]
        for p in drive.photos {
            let folder = (p.relativePath as NSString).deletingLastPathComponent
            let stem   = (p.filename as NSString).deletingPathExtension.lowercased()
            let key    = folder + "\0" + stem
            groups[key, default: []].append(p)
        }
        return groups.values.map { group in
            let best = group.first(where: {
                Self.nonRawExts.contains(($0.filename as NSString).pathExtension.lowercased())
            }) ?? group.first!
            let fc = group.count
            let cc = best.duplicateGroupId.flatMap { counts[$0] }
            return PhotoDisplayItem(photo: best, formatCount: fc, copyCount: cc)
        }
    }

    private var displayPhotos: [PhotoDisplayItem] {
        var list = deduplicatedPhotos
        if showOnlyDuplicates {
            // Show every copy of duplicate groups for comparison
            list = list.filter { $0.photo.duplicateGroupId != nil }
        } else {
            // Default: collapse duplicate groups — show only one representative per group
            var seenGroups: Set<String> = []
            list = list.filter { item in
                guard let gid = item.photo.duplicateGroupId else { return true }
                return seenGroups.insert(gid).inserted
            }
        }
        if !searchText.isEmpty {
            list = list.filter { $0.photo.filename.localizedCaseInsensitiveContains(searchText) }
        }
        // All sorts use photo.id as a stable tiebreaker so that items with equal
        // primary keys (e.g. captureDate = nil during thumbnail generation) don't
        // swap positions on successive renders, which causes grid flicker.
        switch sortOrder {
        case .captureDate:
            list.sort {
                let a = $0.photo.captureDate ?? ""; let b = $1.photo.captureDate ?? ""
                return a != b ? a > b : $0.photo.id < $1.photo.id
            }
        case .filename:
            list.sort {
                $0.photo.filename != $1.photo.filename
                    ? $0.photo.filename < $1.photo.filename
                    : $0.photo.id < $1.photo.id
            }
        case .fileSize:
            list.sort {
                $0.photo.fileSize != $1.photo.fileSize
                    ? $0.photo.fileSize > $1.photo.fileSize
                    : $0.photo.id < $1.photo.id
            }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            // Prominent progress banner during indexing or thumbnail generation
            if drive.isIndexing || drive.isGeneratingThumbnails {
                thumbnailProgressBanner
            }

            HStack(spacing: 0) {
                // Main content
                Group {
                    if drive.isIndexing && drive.photos.isEmpty {
                        indexingPlaceholder
                    } else if drive.photos.isEmpty && !drive.isIndexing {
                        noPhotosPlaceholder
                    } else {
                        photoGrid
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Inspector panel — photo detail when selected, indexing progress otherwise
                if showInspector {
                    Divider()
                    if let photo = selectedPhoto {
                        DrivePhotoDetailView(
                            photo: photo,
                            mountPoint: drive.mountPoint,
                            onDismiss: {
                                showInspector = false
                                selectedPhoto = nil
                            },
                            onExtractFrames: (photo.filmFrameCount ?? 0) > 0 ? {
                                photoForExtraction = photo
                            } : nil
                        )
                    } else {
                        IndexingInspectorView(drive: drive) {
                            showInspector = false
                        }
                    }
                }
            }
        }
        .onAppear {
            if drive.isIndexing || drive.isGeneratingThumbnails {
                showInspector = true
            }
        }
        .onChange(of: drive.isIndexing) { indexing in
            if indexing { showInspector = true }
        }
        .onChange(of: drive.isGeneratingThumbnails) { generating in
            if !generating && drive.thumbnailsDone > 0 {
                let n = drive.thumbnailsDone
                completionBanner = "\(n) thumbnail\(n == 1 ? "" : "s") ready"
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    completionBanner = nil
                }
            }
        }
        .onChange(of: drive.isRunningWorkflows) { running in
            if !running && drive.workflowProcessed > 0 {
                let n = drive.workflowProcessed
                completionBanner = "Workflows complete — \(n) photo\(n == 1 ? "" : "s") analyzed"
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    completionBanner = nil
                }
            }
        }
        .onChange(of: selectedPhoto?.id) { photoID in
            if photoID != nil {
                showInspector = true
            } else if !drive.isIndexing && drive.currentStage == .idle {
                showInspector = false
            }
        }
        .sheet(item: $photoForExtraction) { photo in
            DriveFilmExtractorSheet(photo: photo, mountPoint: drive.mountPoint) {
                photoForExtraction = nil
            }
        }
        .overlay {
            if let photo = previewPhoto {
                DrivePhotoQuickLookOverlay(
                    photo: photo,
                    allPhotos: displayPhotos.map(\.photo),
                    mountPoint: drive.mountPoint,
                    previewPhoto: $previewPhoto
                )
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if let msg = completionBanner {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(msg)
                        .font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: previewPhoto?.id)
        .animation(.spring(duration: 0.35), value: completionBanner)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Label("Drives", systemImage: "chevron.left")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            Divider().frame(height: 16)

            Image(systemName: "externaldrive.fill")
                .foregroundStyle(.secondary)
            Text(drive.label)
                .font(.headline)

            Spacer()

            if !drive.isIndexing && !drive.isGeneratingThumbnails && drive.hasBeenIndexed && !drive.hasThumbnails {
                // Thumbnails not yet generated (or generation was stopped) — offer manual trigger
                Button {
                    drive.startThumbnailGeneration()
                } label: {
                    Label("Generate Thumbnails", systemImage: "photo.stack")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .help("Generate thumbnail previews for all indexed photos")
            } else if !drive.isIndexing && !drive.isGeneratingThumbnails && drive.hasBeenIndexed && drive.hasThumbnails {
                // Thumbnails exist — offer regeneration via context menu only
                Button {
                    drive.startThumbnailGeneration()
                } label: {
                    Label("Regenerate", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
                .help("Re-generate thumbnail previews")
                .contextMenu {
                    Button("Generate Missing") {
                        drive.startThumbnailGeneration()
                    }
                    Button("Clear & Regenerate All") {
                        drive.clearAndRegenerateThumbnails()
                    }
                }
            }

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Search filenames…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 160)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)

            // Duplicates filter chip — only shown when duplicates exist
            if drive.duplicateCount > 0 {
                Button {
                    showOnlyDuplicates.toggle()
                    if showOnlyDuplicates { selectedPhoto = nil; selectedPhotoIDs = [] }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc.fill")
                        Text("\(drive.duplicateCount) dupes")
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(showOnlyDuplicates ? .orange : nil)
            }

            // Sort
            Picker("Sort", selection: $sortOrder) {
                ForEach(SortOrder.allCases) { o in
                    Text(o.rawValue).tag(o)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)

            Text({
                let total = deduplicatedPhotos.count
                let shown = displayPhotos.count
                return shown == total
                    ? "\(shown) photos"
                    : "\(shown) / \(total) photos"
            }())
                .font(.caption)
                .foregroundStyle(.secondary)

            // Scan & Import All — opens the pre-import drive scan preview
            Button {
                showScanPreview = true
            } label: {
                Label("Scan & Import All", systemImage: "magnifyingglass")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .help("Scan the entire drive and preview before importing")
            .sheet(isPresented: $showScanPreview) {
                DriveScanPreviewSheet(
                    drive: drive,
                    onImport: { result, jobName, mode in
                        showScanPreview = false
                        handleScanImportFromGrid(result: result, jobName: jobName, mode: mode)
                    },
                    onDismiss: { showScanPreview = false }
                )
            }

            // Import selected photos (with optional workflow analysis)
            if !selectedPhotoIDs.isEmpty {
                Button {
                    showImportSheet = true
                } label: {
                    Label("Import \(selectedPhotoIDs.count)", systemImage: "square.and.arrow.down")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderedProminent)
                .help("Import selected photos into the library")
                .sheet(isPresented: $showImportSheet) {
                    DriveImportSheet(
                        drive: drive,
                        selectedPhotoIDs: selectedPhotoIDs,
                        onDismiss: {
                            showImportSheet = false
                            selectedPhotoIDs = []
                        }
                    )
                }
            }

            // Inspector toggle — always visible once indexing has run
            if drive.currentStage != .idle {
                Button {
                    showInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(showInspector ? Color.accentColor : .secondary)
                .help("Toggle index inspector")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Grid

    private var photoGrid: some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                // Full-area hit target so drag gestures fire on empty space between cells
                Color.clear.contentShape(Rectangle())

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(displayPhotos) { item in
                        DrivePhotoCell(
                            photo: item.photo,
                            mountPoint: drive.mountPoint,
                            isSelected: selectedPhotoIDs.contains(item.photo.id),
                            copyCount: item.copyCount,
                            formatCount: item.formatCount > 1 ? item.formatCount : nil,
                            isGenerating: drive.isGeneratingThumbnails || drive.isIndexing,
                            onSelect: {
                                let id = item.photo.id
                                if selectedPhotoIDs.contains(id) {
                                    selectedPhotoIDs.remove(id)
                                } else {
                                    selectedPhotoIDs.insert(id)
                                }
                                selectedPhoto = item.photo
                                previewPhoto = item.photo
                            },
                            onPreview: {
                                previewPhoto = item.photo
                            },
                            onExtractFrames: (item.photo.filmFrameCount ?? 0) > 0 ? {
                                photoForExtraction = item.photo
                            } : nil
                        )
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: CellFrameKey.self,
                                    value: [item.photo.id: geo.frame(in: .named("photoGrid"))]
                                )
                            }
                        )
                    }
                }
                .padding(12)

                // Rubber-band selection rect
                if let start = rubberBandStart, let end = rubberBandCurrent {
                    let rect = rubberBandRect(start: start, end: end)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
                        )
                        .frame(width: max(1, rect.width), height: max(1, rect.height))
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "photoGrid")
            .simultaneousGesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named("photoGrid"))
                    .onChanged { value in
                        if rubberBandStart == nil { rubberBandStart = value.startLocation }
                        rubberBandCurrent = value.location
                        updateRubberBandSelection()
                    }
                    .onEnded { _ in
                        rubberBandStart = nil
                        rubberBandCurrent = nil
                    }
            )
        }
        .onPreferenceChange(CellFrameKey.self) { frames in
            cellFrames.merge(frames) { $1 }
        }
        // Suppress SwiftUI's automatic item-reorder animations while thumbnails are
        // being generated. Without this, each DB write triggers a cross-fade between
        // the old and new sorted order, producing visible card-swap flicker.
        .transaction { t in
            if drive.isIndexing || drive.currentStage == .generatingThumbnails {
                t.animation = nil
            }
        }
        .background(
            Group {
                Button("") { selectedPhotoIDs = Set(displayPhotos.map(\.photo.id)) }
                    .keyboardShortcut("a", modifiers: .command)
                Button("") {
                    selectedPhotoIDs = []
                    selectedPhoto = nil
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .hidden()
        )
        // Tap on the scroll background (outside any cell) clears selection
        .onTapGesture {
            selectedPhotoIDs = []
            selectedPhoto = nil
        }
    }

    private func rubberBandRect(start: CGPoint, end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func updateRubberBandSelection() {
        guard let start = rubberBandStart, let end = rubberBandCurrent else { return }
        let rect = rubberBandRect(start: start, end: end)
        selectedPhotoIDs = Set(cellFrames.compactMap { id, frame in
            frame.intersects(rect) ? id : nil
        })
    }

    private var indexingPlaceholder: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Indexing drive…")
                .foregroundStyle(.secondary)
            Text("\(drive.indexedCount) of \(drive.totalFileCount) files scanned")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noPhotosPlaceholder: some View {
        VStack(spacing: 14) {
            if drive.isGeneratingThumbnails {
                ProgressView()
                Text("Generating previews…")
                    .font(.title3.weight(.semibold))
                Text("Photos will appear as previews are ready.")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("Index this drive to browse photos")
                    .font(.title3.weight(.semibold))
                Button("Import") { drive.startIndexing() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var thumbnailProgressBanner: some View {
        HStack(spacing: 10) {
            if drive.isIndexing {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
                Image(systemName: drive.currentStage.systemImage)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
                Text(drive.currentStage.rawValue)
                    .font(.system(size: 11, weight: .medium))
                if drive.totalFileCount > 0 {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(drive.indexedCount) / \(drive.totalFileCount) files")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Stop") { drive.stopIndexing() }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else if drive.isGeneratingThumbnails {
                ProgressView(value: drive.thumbnailsTotal > 0
                    ? Double(drive.thumbnailsDone) / Double(drive.thumbnailsTotal)
                    : 0)
                    .frame(width: 120)
                    .tint(Color.accentColor)
                Image(systemName: "photo.stack")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
                Text("Generating previews")
                    .font(.system(size: 11, weight: .medium))
                if drive.thumbnailsTotal > 0 {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(drive.thumbnailsDone) / \(drive.thumbnailsTotal)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if !drive.currentFilename.isEmpty {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(drive.currentFilename)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 140)
                }
                Spacer()
                Button("Stop") { drive.stopThumbnailGeneration() }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.06))
    }

    // MARK: - Scan-to-import bridge (grid context)

    private func handleScanImportFromGrid(
        result: DriveScanResult,
        jobName: String,
        mode: DriveScanPreviewSheet.ImportMode
    ) {
        let importLogger = Logger(subsystem: "HoehnPhotosOrganizer", category: "DriveScanImport")
        guard let vm = libraryViewModel, let database = db else { return }

        let files: [ScannedFile]
        switch mode {
        case .all:
            files = result.files
            importLogger.info("[DriveScanImport] Mode: all — importing \(result.files.count) file(s)")
        case .newOnly:
            files = result.files.filter { !result.duplicateFilenames.contains($0.deduplicationKey) }
            let skipped = result.files.count - files.count
            importLogger.info("[DriveScanImport] Mode: newOnly — \(result.files.count) total, \(skipped) duplicates skipped, \(files.count) to import")
        }

        guard !files.isEmpty else {
            importLogger.info("[DriveScanImport] No files to import after filtering")
            return
        }

        let urls = files.map(\.url)

        Task {
            await vm.importDigitalPhotosWithJobName(urls, db: database, jobName: jobName)
            importLogger.info("[DriveScanImport] Import complete for job '\(jobName)'")
        }
    }
}

// MARK: - DrivePhotoCell

private struct DrivePhotoCell: View {

    let photo: DrivePhotoRecord
    let mountPoint: URL
    let isSelected: Bool
    let copyCount: Int?      // nil = not a duplicate; ≥2 = number of copies on this drive
    let formatCount: Int?    // nil = only one format; ≥2 = multiple formats (e.g. JPEG + RAW)
    let isGenerating: Bool   // true when thumbnail generation is in progress
    let onSelect: () -> Void
    let onPreview: () -> Void
    var onExtractFrames: (() -> Void)? = nil

    @State private var thumbImage: NSImage? = nil
    @State private var shimmerPhase: Bool = false

    var body: some View {
        VStack(spacing: 4) {
            thumbnailView
                .frame(width: 140, height: 105)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.clear,
                            lineWidth: 2
                        )
                )
                .overlay(alignment: .topLeading) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(4)
                    } else if photo.importedAt != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white, Color.green)
                            .padding(4)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let n = copyCount, n > 1 {
                        Text("×\(n)")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.88))
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                            .padding(5)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let fc = formatCount {
                        Text("\(fc) fmt")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.85))
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                            .padding(5)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if photo.hasWorkflowResults {
                        workflowBadges
                            .padding(5)
                    }
                }

            VStack(spacing: 1) {
                Text(photo.filename)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let date = photo.displayDate {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onPreview() }
        .onTapGesture(count: 1) { onSelect() }
        .contextMenu {
            if let frames = photo.filmFrameCount, frames > 0, let extract = onExtractFrames {
                Button {
                    extract()
                } label: {
                    Label("Extract \(frames) Frame\(frames == 1 ? "" : "s")…", systemImage: "film")
                }
                Divider()
            }
            Button("Preview") { onPreview() }
            Button("Select") { onSelect() }
        }
        .task(id: photo.thumbnailPath) { await loadThumbnail() }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let img = thumbImage {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .separatorColor).opacity(shimmerPhase ? 0.3 : 0.55))
                .overlay {
                    Image(systemName: photo.isRawFile ? "camera.aperture" : "photo")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                }
                .onAppear {
                    guard isGenerating else { return }
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                        shimmerPhase = true
                    }
                }
                .onChange(of: isGenerating) { generating in
                    if generating {
                        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                            shimmerPhase = true
                        }
                    } else {
                        withAnimation(.default) { shimmerPhase = false }
                    }
                }
        }
    }

    @ViewBuilder
    private var workflowBadges: some View {
        HStack(spacing: 4) {
            // Rotation badge — only show when non-zero correction needed
            if let deg = photo.orientationDegrees, deg != 0 {
                badge(icon: "rotate.right", label: "\(deg)°", color: .orange)
            }
            // Scene badge
            if let scene = photo.sceneLabel {
                badge(icon: "photo.badge.magnifyingglass", label: scene, color: .teal)
            }
            // Face badge
            if let faces = photo.faceCount, faces > 0 {
                badge(icon: "person.fill", label: "\(faces)", color: .indigo)
            }
            // Film strip badge
            if let frames = photo.filmFrameCount, frames > 0 {
                badge(icon: "film", label: "\(frames)", color: .purple)
            }
        }
    }

    private func badge(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 7, weight: .semibold))
            Text(label)
                .font(.system(size: 7, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(color.opacity(0.85))
        .clipShape(Capsule())
    }

    private func loadThumbnail() async {
        if let path = photo.thumbnailPath {
            thumbImage = await Task.detached(priority: .utility) {
                NSImage(contentsOfFile: path)
            }.value
        }
    }
}

// MARK: - DrivePhotoQuickLookOverlay

private struct DrivePhotoQuickLookOverlay: View {

    let photo: DrivePhotoRecord
    let allPhotos: [DrivePhotoRecord]
    let mountPoint: URL
    @Binding var previewPhoto: DrivePhotoRecord?

    @State private var image: NSImage? = nil
    @State private var thumbnailMissing = false
    @FocusState private var isFocused: Bool

    private var currentIndex: Int? {
        allPhotos.firstIndex(where: { $0.id == photo.id })
    }

    var body: some View {
        ZStack {
            // Scrim — click outside to dismiss
            Color.black.opacity(0.78)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                // Top bar
                HStack(spacing: 0) {
                    Spacer()
                    Text(photo.filename)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                    Spacer()
                    Button(action: dismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                }
                .padding(.vertical, 10)

                // Image area
                ZStack {
                    if let img = image {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .shadow(color: .black.opacity(0.5), radius: 20)
                    } else if thumbnailMissing {
                        VStack(spacing: 10) {
                            Image(systemName: "photo.badge.clock")
                                .font(.system(size: 44))
                                .foregroundStyle(.white.opacity(0.4))
                            Text("Thumbnail not yet generated")
                                .font(.callout)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    } else {
                        ProgressView()
                            .tint(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 60)
                .allowsHitTesting(false)

                // Bottom metadata bar
                HStack(spacing: 20) {
                    if let date = photo.displayDate {
                        metaBadge("calendar", date.formatted(date: .abbreviated, time: .omitted))
                    }
                    if let w = photo.width, let h = photo.height {
                        metaBadge("aspectratio", "\(w) × \(h)")
                    }
                    // Source indicator — always a local thumbnail, never the original file
                    metaBadge("square.and.arrow.down", "Thumbnail")
                    if photo.isRawFile {
                        metaBadge("camera.aperture", "RAW")
                    }
                    if let idx = currentIndex {
                        metaBadge("photo.stack", "\(idx + 1) / \(allPhotos.count)")
                    }
                }
                .padding(.vertical, 10)
            }

            // Prev / Next arrows
            if let idx = currentIndex {
                HStack {
                    if idx > 0 {
                        navButton("chevron.left.circle.fill") { previewPhoto = allPhotos[idx - 1] }
                            .padding(.leading, 16)
                    }
                    Spacer()
                    if idx < allPhotos.count - 1 {
                        navButton("chevron.right.circle.fill") { previewPhoto = allPhotos[idx + 1] }
                            .padding(.trailing, 16)
                    }
                }
            }
        }
        .focusable()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.escape)     { dismiss();      return .handled }
        .onKeyPress(.leftArrow)  { navigatePrev(); return .handled }
        .onKeyPress(.rightArrow) { navigateNext(); return .handled }
        .task(id: photo.id) { await loadImage() }
    }

    // MARK: - Sub-views

    private func metaBadge(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.6))
    }

    private func navButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white.opacity(0.7))
        }
        .buttonStyle(.plain)
        .cursor(.pointingHand)
    }

    // MARK: - Actions

    private func dismiss() { previewPhoto = nil }

    private func navigatePrev() {
        guard let idx = currentIndex, idx > 0 else { return }
        previewPhoto = allPhotos[idx - 1]
    }

    private func navigateNext() {
        guard let idx = currentIndex, idx < allPhotos.count - 1 else { return }
        previewPhoto = allPhotos[idx + 1]
    }

    // MARK: - Image loading

    private func loadImage() async {
        image = nil
        thumbnailMissing = false
        // Only ever show the locally-cached thumbnail. Never load from the original
        // drive file — originals can be 50–200 MB and require the drive to be mounted.
        guard let path = photo.thumbnailPath else {
            thumbnailMissing = true
            return
        }
        let loaded = await Task.detached(priority: .utility) {
            NSImage(contentsOfFile: path)
        }.value
        if let loaded {
            image = loaded
        } else {
            thumbnailMissing = true
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }
}

// MARK: - IndexingInspectorView

/// Right-side panel showing live indexing progress, file-type stats, and a rolling log.
struct IndexingInspectorView: View {

    @ObservedObject var drive: MountedDriveState
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stageSection
                    statsSection
                    if !drive.logLines.isEmpty {
                        logSection
                    }
                }
                .padding(14)
            }
            Divider()
            Button("Clear Index") {
                drive.forgetIndex()
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .tint(.red)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 260)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Index Progress")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Stage + progress

    private var stageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: drive.currentStage.systemImage)
                    .foregroundStyle(stageColor)
                    .font(.system(size: 12))
                Text(drive.currentStage.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(stageColor)
            }

            stageProgressView

            if !drive.currentFilename.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(drive.currentFilename)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    @ViewBuilder
    private var stageProgressView: some View {
        switch drive.currentStage {

        case .discovering:
            // File count is unknown upfront — show indeterminate bar + rolling count
            ProgressView()
                .progressViewStyle(.linear)
                .tint(stageColor)
            Text("Found \(drive.totalFileCount) files so far…")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

        case .indexing where drive.totalFileCount > 0:
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: max(0.01, drive.indexProgress))
                    .tint(stageColor)
                HStack {
                    Text("\(drive.indexedCount) of \(drive.totalFileCount) files")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(drive.indexProgress * 100))%")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

        case .generatingThumbnails:
            if drive.thumbnailsTotal > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: max(0.01, drive.indexProgress))
                        .tint(stageColor)
                    HStack {
                        Text("\(drive.thumbnailsDone) of \(drive.thumbnailsTotal) thumbnails")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(drive.indexProgress * 100))%")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                // DB query in-flight — total not yet known
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(stageColor)
                Text("Loading file list…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

        case .detectingDuplicates:
            ProgressView()
                .progressViewStyle(.linear)
                .tint(stageColor)
            Text("Analysing \(drive.totalFileCount) files…")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

        case .complete:
            Text("\(drive.totalFileCount) files indexed")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

        default:
            EmptyView()
        }
    }

    private var stageColor: Color {
        switch drive.currentStage {
        case .complete:            return .green
        case .detectingDuplicates: return .orange
        case .idle:                return .secondary
        default:                   return Color.accentColor
        }
    }

    // MARK: - Stats grid

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Statistics")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                alignment: .leading, spacing: 8
            ) {
                statCell(label: "Folders",  value: drive.folderCount,  icon: "folder.fill",        color: .blue)
                statCell(label: "Total",    value: drive.totalFileCount, icon: "doc.fill",          color: .indigo)
                statCell(label: "RAW",      value: drive.rawCount,      icon: "camera.aperture",    color: Color.accentColor)
                statCell(label: "JPEG/HEIC",value: drive.jpegCount,     icon: "photo.fill",         color: .teal)
                statCell(label: "Other",    value: drive.otherCount,    icon: "doc.badge.ellipsis", color: .gray)
                statCell(label: "Cached",   value: drive.skippedCount,  icon: "bolt.horizontal",    color: .green)
                if drive.duplicateCount > 0 {
                    statCell(label: "Dupes", value: drive.duplicateCount, icon: "doc.on.doc.fill",  color: .orange)
                }
            }
        }
    }

    private func statCell(label: String, value: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(color)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(value)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Activity Log")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(drive.logLines.reversed().prefix(15), id: \.self) { line in
                    Text(line)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .cornerRadius(6)
        }
    }
}

// MARK: - DrivePhotoDetailView

/// Right-side inspector panel showing metadata for a selected drive photo.
struct DrivePhotoDetailView: View {

    let photo: DrivePhotoRecord
    let mountPoint: URL
    let onDismiss: () -> Void
    var onExtractFrames: (() -> Void)? = nil

    @State private var thumbImage: NSImage? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Photo Info")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Thumbnail
                    if let img = thumbImage {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .frame(maxWidth: .infinity)
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .separatorColor).opacity(0.4))
                            .frame(maxWidth: .infinity)
                            .frame(height: 130)
                            .overlay {
                                Image(systemName: photo.isRawFile ? "camera.aperture" : "photo")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.tertiary)
                            }
                    }

                    // File info section
                    infoSection

                    // Workflow results section
                    if photo.hasWorkflowResults {
                        workflowSection
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 260)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: photo.thumbnailPath) { await loadThumbnail() }
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("File")

            infoRow(label: "Name", value: photo.filename)

            let ext = (photo.filename as NSString).pathExtension.uppercased()
            HStack {
                infoRowContent(label: "Type", value: ext)
                if photo.isRawFile {
                    Text("RAW")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                }
            }

            infoRow(label: "Size", value: formatBytes(photo.fileSize))

            if let date = photo.displayDate {
                infoRow(label: "Captured",
                        value: date.formatted(date: .abbreviated, time: .shortened))
            }

            if let w = photo.width, let h = photo.height {
                infoRow(label: "Dimensions", value: "\(w) × \(h)")
            }

            infoRow(label: "Path", value: photo.relativePath)

            if let importedAt = photo.importedAt,
               let date = ISO8601DateFormatter().date(from: importedAt) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("In Library")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 12))
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 14))
                }
            }
        }
    }

    private var workflowSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Analysis")

            if let deg = photo.orientationDegrees {
                infoRow(label: "Orientation",
                        value: deg == 0 ? "Correct" : "\(deg)° correction")
            }
            if let scene = photo.sceneLabel {
                infoRow(label: "Scene", value: scene)
            }
            if let faces = photo.faceCount {
                infoRow(label: "Faces", value: faces == 0 ? "None" : "\(faces)")
            }
            if let frames = photo.filmFrameCount, frames > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    infoRow(label: "Film Frames", value: "\(frames)")
                    if let extract = onExtractFrames {
                        Button {
                            extract()
                        } label: {
                            Label("Extract \(frames) Frame\(frames == 1 ? "" : "s")…",
                                  systemImage: "film")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
    }

    private func infoRow(label: String, value: String) -> some View {
        infoRowContent(label: label, value: value)
    }

    private func infoRowContent(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    private func loadThumbnail() async {
        if let path = photo.thumbnailPath {
            thumbImage = await Task.detached(priority: .utility) {
                NSImage(contentsOfFile: path)
            }.value
        }
    }
}

// MARK: - DriveFilmExtractorSheet

/// Sheet that bridges a drive-indexed filmstrip image into `FrameReviewView`.
///
/// If the drive workflow already stored frame rects (`filmFrameRectsJSON`), detection is
/// skipped and the review grid opens immediately. Otherwise a brief YOLO detection pass
/// runs first, then the review grid is shown.
struct DriveFilmExtractorSheet: View {

    let photo: DrivePhotoRecord
    let mountPoint: URL
    let onDismiss: () -> Void

    @Environment(\.appDatabase) private var appDatabase
    @Environment(\.activityEventService) private var activityEventService

    private enum Phase {
        case detecting
        case reviewing([DetectedFrame])
        case failed(String)
    }

    @State private var phase: Phase = .detecting

    var body: some View {
        Group {
            switch phase {
            case .detecting:
                detectingView
            case .reviewing(let frames):
                FrameReviewView(
                    template: .filmScans,
                    frames: frames,
                    onImport: { _ in onDismiss() },
                    onBack: { onDismiss() }
                )
                .frame(minWidth: 800, minHeight: 600)
            case .failed(let msg):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                    Text("Frame Detection Failed")
                        .font(.title3.bold())
                    Text(msg)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Close") { onDismiss() }
                        .buttonStyle(.bordered)
                }
                .padding(40)
            }
        }
        .task { await prepareFrames() }
    }

    private var detectingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Detecting film frames…")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(photo.filename)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(width: 360, height: 240)
    }

    private func prepareFrames() async {
        let sourceURL = photo.absoluteURL(mountPoint: mountPoint)

        // 1. Use stored rects if available (no re-detection needed)
        if let json = photo.filmFrameRectsJSON {
            let rects = DriveWorkflowRunner.decodeRectsJSON(json)
            if !rects.isEmpty {
                let frames = await buildDetectedFrames(from: rects, sourceURL: sourceURL)
                await MainActor.run { phase = .reviewing(frames) }
                return
            }
        }

        // 2. Run YOLO detection (rects not stored or empty)
        guard YOLOFrameDetector.isAvailable else {
            await MainActor.run { phase = .failed("Film frame detection model is not available.") }
            return
        }

        let loadedImage = try? await Task.detached(priority: .userInitiated) {
            try FilmStripFrameExtractor.loadImage(at: sourceURL)
        }.value
        guard let cgImage = loadedImage else {
            await MainActor.run { phase = .failed("Could not load image from drive.") }
            return
        }

        let rects = (try? await YOLOFrameDetector().detectFrames(in: cgImage)) ?? []
        guard !rects.isEmpty else {
            await MainActor.run { phase = .failed("No film frames detected in \(photo.filename).") }
            return
        }

        let frames = await buildDetectedFrames(from: rects, sourceURL: sourceURL)
        await MainActor.run { phase = .reviewing(frames) }
    }

    /// Converts [CGRect] → [DetectedFrame] by cropping thumbnails from the source image.
    /// Uses `FilmStripFrameExtractor.loadImage` for RAW/DNG support and
    /// `FilmStripDetectingView.thumbnail` for correct sRGB + y-flip rendering.
    private func buildDetectedFrames(from rects: [CGRect], sourceURL: URL) async -> [DetectedFrame] {
        await Task.detached(priority: .userInitiated) {
            guard let full = try? FilmStripFrameExtractor.loadImage(at: sourceURL) else { return [] }
            return rects.enumerated().compactMap { index, rect -> DetectedFrame? in
                guard let thumb = FilmStripDetectingView.thumbnail(from: full, rect: rect) else {
                    return nil
                }
                return DetectedFrame(
                    id: UUID(),
                    sourceScanURL: sourceURL,
                    cropRect: rect,
                    thumbnail: thumb,
                    frameIndex: index + 1
                )
            }
        }.value
    }
}
