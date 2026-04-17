import AppKit
import GRDB
import SwiftUI
import Foundation

// MARK: - FramePositionKey

private struct FramePositionKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - FrameReviewView

/// Lightroom-style confirmation screen shown after frame detection.
///
/// All detected frames are shown as thumbnails in a grid. The user clicks or rubber-band
/// drags to select frames to discard, then presses "Import" to commit the rest.
struct FrameReviewView: View {
    let template: ImportTemplate
    let frames: [DetectedFrame]
    /// CW degrees the entire strip was rotated before detection.  Must be mirrored in the exporter
    /// so it re-loads and crops from the rotated pixel space rather than the original TIFF.
    var stripRotationDegrees: Int = 0
    let onImport: ([DetectedFrame]) -> Void
    let onBack: () -> Void

    @Environment(\.appDatabase) private var appDatabase: AppDatabase?
    @Environment(\.activityEventService) private var activityEventService: ActivityEventService?

    // keep/discard state per frame id — defaults to `true` (keep)
    @State private var keepStates: [UUID: Bool] = [:]
    // currently rubber-band-selected frame ids (shown with a blue ring)
    @State private var selectedIDs: Set<UUID> = []
    // card positions in the named "reviewGrid" coordinate space
    @State private var cardPositions: [UUID: CGRect] = [:]
    // rubber band drag rect in the "reviewGrid" coordinate space
    @State private var rubberBandRect: CGRect? = nil
    @State private var gridColumns: Double = 5
    @State private var exportFormat: FilmStripFrameExtractor.ExportFormat = .tiff
    @State private var rotations: [UUID: Int] = [:]   // CW degrees per frame
    @State private var isImporting = false
    @State private var importError: String? = nil

    private var keptFrames: [DetectedFrame] { frames.filter { keepStates[$0.id] ?? true } }
    private var discardedCount: Int { frames.count - keptFrames.count }
    private var scanCount: Int { Set(frames.map(\.sourceScanURL)).count }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            reviewGrid
        }
        .onAppear {
            keepStates = Dictionary(uniqueKeysWithValues: frames.map { ($0.id, true) })
        }
        .overlay {
            if isImporting { importingOverlay }
        }
        .alert("Import Failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(spacing: 0) {
            // Primary row: navigation + title + import action
            HStack(spacing: 12) {
                Button("← Back") { onBack() }
                    .buttonStyle(.bordered)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Review Frames")
                        .font(.title2.bold())
                    Text("\(frames.count) frame\(frames.count == 1 ? "" : "s") detected across \(scanCount) scan\(scanCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if discardedCount > 0 {
                    Text("\(discardedCount) discarded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    runImport()
                } label: {
                    Label("Import \(keptFrames.count) Frame\(keptFrames.count == 1 ? "" : "s")",
                          systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(keptFrames.isEmpty || isImporting)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Secondary row: selection controls + grid density
            HStack(spacing: 10) {
                Button("Check All") {
                    keepStates = Dictionary(uniqueKeysWithValues: frames.map { ($0.id, true) })
                    selectedIDs = []
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Uncheck All") {
                    keepStates = Dictionary(uniqueKeysWithValues: frames.map { ($0.id, false) })
                    selectedIDs = []
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if !selectedIDs.isEmpty {
                    Button("Discard Selected (\(selectedIDs.count))") {
                        for id in selectedIDs { keepStates[id] = false }
                        selectedIDs = []
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                }

                Spacer()

                // Export format — menu picker stays compact regardless of option count
                HStack(spacing: 4) {
                    Text("Format:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Picker("Format", selection: $exportFormat) {
                        ForEach(FilmStripFrameExtractor.ExportFormat.allCases, id: \.self) { fmt in
                            Text(fmt.rawValue).tag(fmt)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                }

                // Grid density slider
                HStack(spacing: 5) {
                    Image(systemName: "square.grid.2x2")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Slider(value: $gridColumns, in: 2...8, step: 1)
                        .frame(width: 80)
                    Image(systemName: "square.grid.3x3")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    // MARK: - Review Grid

    private var reviewGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: Int(gridColumns))

        return ScrollView {
            ZStack(alignment: .topLeading) {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(frames) { frame in
                        FrameThumbnailCard(
                            frame: frame,
                            isKept: keepStates[frame.id] ?? true,
                            isSelected: selectedIDs.contains(frame.id),
                            rotation: rotations[frame.id] ?? 0
                        )
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: FramePositionKey.self,
                                    value: [frame.id: geo.frame(in: .named("reviewGrid"))]
                                )
                            }
                        )
                        .onTapGesture {
                            // Tap toggles the keep state and clears rubber-band selection.
                            selectedIDs = []
                            keepStates[frame.id] = !(keepStates[frame.id] ?? true)
                        }
                    }
                }
                .padding(12)

                // Rubber band rectangle overlay
                if let rect = rubberBandRect, rect.width > 2 || rect.height > 2 {
                    Rectangle()
                        .stroke(Color.accentColor, lineWidth: 1.5)
                        .background(Color.accentColor.opacity(0.08))
                        .frame(width: max(1, rect.width), height: max(1, rect.height))
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .coordinateSpace(name: "reviewGrid")
            // Use simultaneousGesture so the drag fires even when starting over a card.
            .simultaneousGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named("reviewGrid"))
                    .onChanged { value in
                        let rect = CGRect(
                            x: min(value.startLocation.x, value.location.x),
                            y: min(value.startLocation.y, value.location.y),
                            width: abs(value.location.x - value.startLocation.x),
                            height: abs(value.location.y - value.startLocation.y)
                        )
                        rubberBandRect = rect
                        // Update selection in real time.
                        selectedIDs = Set(cardPositions.compactMap { id, cardRect in
                            rect.intersects(cardRect) ? id : nil
                        })
                    }
                    .onEnded { _ in
                        rubberBandRect = nil
                        // Selection persists so user can act on it via toolbar.
                    }
            )
            .onPreferenceChange(FramePositionKey.self) { positions in
                cardPositions = positions
            }
        }
    }

    // MARK: - Importing overlay

    private var importingOverlay: some View {
        ZStack {
            Color.black.opacity(0.08).ignoresSafeArea()
            ProgressView("Importing \(keptFrames.count) frame\(keptFrames.count == 1 ? "" : "s")…")
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - Import logic

    private func runImport() {
        guard let db = appDatabase else { return }
        isImporting = true
        let toImport = keptFrames
        let capturedRotations = rotations
        let capturedActivityService = activityEventService
        Task {
            do {
                try await importFrames(toImport, rotations: capturedRotations, db: db, activityService: capturedActivityService)
                await MainActor.run {
                    isImporting = false
                    onImport(toImport)
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    importError = error.localizedDescription
                }
            }
        }
    }

    private func importFrames(_ kept: [DetectedFrame], rotations: [UUID: Int], db: AppDatabase, activityService: ActivityEventService?) async throws {
        // Create a job record for logging.
        let job = BackgroundJob.new(type: .filmScanImport)
        try await db.dbPool.write { database in try job.insert(database) }

        do {
            // Emit a top-level importBatch event for this import run (fire-and-forget).
            // The returned event ID is passed to FilmScanIngestionService so per-frame
            // events are stored as children of this batch.
            let batchEventId: String? = await {
                guard let service = activityService else { return nil }
                return try? await service.emitImportBatch(
                    title: "Film scan import",
                    fileCount: kept.count
                ).id
            }()

            // Group kept frames by source scan so we export each scan in one pass.
            let grouped = Dictionary(grouping: kept, by: \.sourceScanURL)

            for (scanURL, scanFrames) in grouped {
                let preferredOutputDirectory = scanURL.deletingLastPathComponent()
                    .appendingPathComponent(
                        scanURL.deletingPathExtension().lastPathComponent + "_frames",
                        isDirectory: true
                    )
                let sortedRects = scanFrames
                    .sorted { $0.frameIndex < $1.frameIndex }
                    .map(\.cropRect)

                var config = FilmStripFrameExtractor.Configuration()
                config.trimBordersAfterExport = true
                config.exportFormat = exportFormat
                config.stripRotationDegrees = stripRotationDegrees
                config.frameRotations = Dictionary(
                    uniqueKeysWithValues: scanFrames.compactMap { f -> (Int, Int)? in
                        guard let deg = rotations[f.id], deg != 0 else { return nil }
                        return (f.frameIndex, deg)
                    }
                )
                let exporter = FilmStripFrameExtractor(configuration: config)

                // Try the preferred sibling directory first; fall back to App Support
                // when the sandbox blocks writes to the source folder (e.g. ~/Pictures).
                let result: FilmStripExtractionResult
                do {
                    result = try await Task.detached(priority: .userInitiated) {
                        try exporter.exportFrames(from: scanURL, frameRects: sortedRects, to: preferredOutputDirectory)
                    }.value
                } catch {
                    let fallback = Self.fallbackExportDirectory(for: scanURL)
                    result = try await Task.detached(priority: .userInitiated) {
                        try exporter.exportFrames(from: scanURL, frameRects: sortedRects, to: fallback)
                    }.value
                }

                // Look up the parent scan's photo_assets.id so lineage records are complete
                // and "Refine Frame Boundary" can find the original scan.
                let sourcePhotoId = try? await db.dbPool.read { database in
                    try PhotoAsset
                        .filter(Column("file_path") == scanURL.path)
                        .fetchOne(database)?
                        .id
                }

                try await FilmScanIngestionService().persist(
                    result,
                    sourcePhotoId: sourcePhotoId,
                    orientation: FilmStripOrientation.vertical.rawValue,
                    detectorMethod: "yolo",
                    batchLabel: nil,
                    toolLogs: result.toolRuns,
                    db: db,
                    activityService: activityService,
                    parentBatchEventId: batchEventId
                )
            }

            // Mark job complete.
            let now = ISO8601DateFormatter().string(from: .now)
            try await db.dbPool.write { database in
                try database.execute(
                    sql: "UPDATE background_jobs SET status = 'completed', updated_at = ? WHERE id = ?",
                    arguments: [now, job.id]
                )
            }

            // Generate proxies so thumbnails appear immediately in the library.
            let photoRepo = PhotoRepository(db: db)
            let proxyRepo = ProxyAssetRepository(db: db)
            let proxyActor = ProxyGenerationActor(photoRepo: photoRepo, proxyRepo: proxyRepo)
            for await _ in proxyActor.processLocalQueue() {}

            // Background face indexing for the newly imported frames.
            // Uses fetchNeedingFaceIndex to only process photos without faceIndexedAt set.
            let faceRepo = FaceEmbeddingRepository(db: db)
            let unindexed = (try? await photoRepo.fetchNeedingFaceIndex()) ?? []
            for photo in unindexed {
                let baseName = (photo.canonicalName as NSString).deletingPathExtension
                let proxyURL = ProxyGenerationActor.proxiesDirectory()
                    .appendingPathComponent(baseName + ".jpg")
                guard FileManager.default.fileExists(atPath: proxyURL.path) else {
                    try? await photoRepo.markFaceIndexed(id: photo.id)
                    continue
                }

                let crops = await Task.detached(priority: .utility) {
                    FaceChipGrid.detectAndCropWithBounds(from: proxyURL)
                }.value

                let now = ISO8601DateFormatter().string(from: Date())
                for (index, pair) in crops.enumerated() {
                    let (cropImage, bbox) = pair
                    guard let cgImage = cropImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
                          let featureData = FaceEmbeddingService.generateFeaturePrint(for: cgImage) else { continue }
                    let record = FaceEmbedding(
                        id: UUID().uuidString,
                        photoId: photo.id,
                        faceIndex: index,
                        bboxX: bbox.minX, bboxY: bbox.minY, bboxWidth: bbox.width, bboxHeight: bbox.height,
                        featureData: featureData,
                        createdAt: now,
                        personId: nil,
                        labeledBy: nil,
                        needsReview: false
                    )
                    try? await faceRepo.upsert(record)
                }

                try? await photoRepo.markFaceIndexed(id: photo.id)
            }
        } catch {
            let now = ISO8601DateFormatter().string(from: .now)
            let msg = error.localizedDescription
            try? await db.dbPool.write { database in
                try database.execute(
                    sql: "UPDATE background_jobs SET status = 'failed', error_message = ?, updated_at = ? WHERE id = ?",
                    arguments: [msg, now, job.id]
                )
            }
            throw error
        }
    }

    private static func fallbackExportDirectory(for sourceURL: URL) -> URL {
        let fileManager = FileManager.default
        let appSupportBase = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let root = appSupportBase
            .appendingPathComponent("HoehnPhotosOrganizer", isDirectory: true)
            .appendingPathComponent("Exports", isDirectory: true)
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return root.appendingPathComponent(
            "\(sourceURL.deletingPathExtension().lastPathComponent)_frames_\(timestamp)",
            isDirectory: true
        )
    }
}

// MARK: - FrameThumbnailCard

private struct FrameThumbnailCard: View {
    let frame: DetectedFrame
    let isKept: Bool
    let isSelected: Bool
    let rotation: Int           // CW degrees: 0, 90, 180, 270

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Thumbnail image — fixed 2:3 portrait cell (35mm frame aspect ratio).
            GeometryReader { geo in
                Image(nsImage: frame.thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .rotationEffect(.degrees(Double(rotation)))
                    // For 90/270° rotation, scale down so the rotated image fits the cell
                    .scaleEffect(rotation % 180 == 0 ? 1 : min(
                        geo.size.width / geo.size.height,
                        geo.size.height / geo.size.width
                    ))
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .cornerRadius(6)
            .opacity(isKept ? 1.0 : 0.4)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.red.opacity(isKept ? 0 : 0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isSelected ? Color.accentColor : isKept ? Color.clear : Color.red,
                        lineWidth: isSelected ? 2.5 : isKept ? 0 : 1.5
                    )
            )

            // Discard badge
            if !isKept {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.red)
                    .padding(4)
            }

            // Selection ring badge
            if isSelected && isKept {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.accentColor)
                    .padding(4)
            }

            // Bottom row: frame label
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    Text(frame.scanLabel.count > 12
                         ? "…\(frame.scanLabel.suffix(8))_\(String(format: "%02d", frame.frameIndex))"
                         : "\(frame.scanLabel)_\(String(format: "%02d", frame.frameIndex))")
                        .font(.caption2.bold())
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())

                    Spacer()
                }
            }
            .padding(4)
        }
        .contentShape(Rectangle())
    }
}
