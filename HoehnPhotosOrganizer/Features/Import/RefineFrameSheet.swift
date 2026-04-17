import AppKit
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers
import GRDB

/// Sheet opened from the library to re-adjust the crop boundary of an already-imported film frame.
///
/// Workflow:
///   1. Load the parent scan via asset_lineage.parent_photo_id.
///   2. Pre-populate the canvas with the stored crop rect (asset_lineage.crop_rect_*).
///   3. User adjusts handles OR taps "Re-detect" to re-run YOLO.
///   4. "Save" re-crops the parent scan, overwrites the clip file, updates the DB, and
///      regenerates the proxy so the library thumbnail reflects the change immediately.
struct RefineFrameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDatabase) private var appDatabase: AppDatabase?

    let clip: PhotoAsset

    @State private var parentURL: URL?
    @State private var previewImage: NSImage?
    @State private var imagePixelSize: CGSize = .zero
    @State private var frameRects: [CGRect] = []
    @State private var selectedFrameIndex: Int = 0
    @State private var rejectedFrameIndices: Set<Int> = []
    @State private var zoomScale: CGFloat = 1.0
    @State private var showOverlay = true
    @State private var isWorking = false
    @State private var statusMessage = "Loading parent scan…"
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // MARK: Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Refine Frame Boundary")
                        .font(.largeTitle.bold())
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let err = errorMessage {
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                }

                Spacer()

                Toggle("Show overlays", isOn: $showOverlay)
                    .toggleStyle(.switch)

                Button("Re-detect") { redetect() }
                    .disabled(parentURL == nil || isWorking)
                    .help("Re-run YOLO on the parent scan to get fresh detection results.")

                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(frameRects.isEmpty || isWorking)

                Button("Cancel") { dismiss() }
            }
            .padding(20)

            Divider()

            // MARK: Canvas
            Group {
                if let previewImage {
                    FilmStripPreviewCanvas(
                        image: previewImage,
                        pixelSize: imagePixelSize,
                        frameRects: $frameRects,
                        selectedFrameIndex: $selectedFrameIndex,
                        rejectedFrameIndices: $rejectedFrameIndices,
                        zoomScale: $zoomScale,
                        showOverlay: showOverlay
                    )
                } else if isWorking {
                    ProgressView("Loading parent scan…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "Cannot Load Parent Scan",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage ?? "The original scan file could not be found.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1000, minHeight: 700)
        .overlay {
            if isWorking {
                ZStack {
                    Color.black.opacity(0.08).ignoresSafeArea()
                    ProgressView(statusMessage)
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .task { await loadParentScan() }
    }

    // MARK: - Load

    private func loadParentScan() async {
        guard let db = appDatabase else { return }
        isWorking = true
        do {
            // 1. Fetch the lineage row for this clip.
            let lineage = try await db.dbPool.read { database in
                try AssetLineage
                    .filter(Column("child_photo_id") == clip.id)
                    .filter(Column("operation") == "film_strip_extract")
                    .fetchOne(database)
            }
            guard let lineage else {
                statusMessage = "No extraction record found for this clip."
                isWorking = false
                return
            }

            // 2. Resolve parent asset → file path.
            guard let parentId = lineage.parentPhotoId else {
                statusMessage = "Parent scan has been deleted from the catalog."
                isWorking = false
                return
            }
            let parent = try await db.dbPool.read { database in
                try PhotoAsset.fetchOne(database, key: parentId)
            }
            guard let parent else {
                statusMessage = "Parent scan asset not found in catalog."
                isWorking = false
                return
            }

            let url = URL(fileURLWithPath: parent.filePath)
            parentURL = url

            statusMessage = "Loading image…"

            // 3. Load and downsample the parent scan for display.
            let cgImage = try await Task.detached(priority: .userInitiated) {
                try FilmStripFrameExtractor.loadImage(at: url)
            }.value

            imagePixelSize = CGSize(width: cgImage.width, height: cgImage.height)
            let displayCG = FilmStripPreviewSheet.downsample(cgImage, maxDimension: 2400)
            previewImage = NSImage(cgImage: displayCG, size: NSSize(width: displayCG.width, height: displayCG.height))

            // 4. Seed canvas with stored crop rect, or a centered fallback.
            if let stored = lineage.cropRect {
                frameRects = [stored]
            } else {
                // Pre-v11 row: fall back to the middle 80% of the scan as a starting point.
                frameRects = [CGRect(
                    x: imagePixelSize.width * 0.1,
                    y: imagePixelSize.height * 0.1,
                    width: imagePixelSize.width * 0.8,
                    height: imagePixelSize.height * 0.8
                )]
            }

            statusMessage = "Adjust the frame boundary, then tap Save."
            isWorking = false
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Failed to load parent scan."
            isWorking = false
        }
    }

    // MARK: - Re-detect

    private func redetect() {
        guard let url = parentURL else { return }
        isWorking = true
        statusMessage = "Running YOLO detection…"
        errorMessage = nil

        Task {
            do {
                let cgImage = try await Task.detached(priority: .userInitiated) {
                    try FilmStripFrameExtractor.loadImage(at: url)
                }.value
                let yolo = YOLOFrameDetector()
                let rects = try await yolo.detectFrames(in: cgImage)
                frameRects = rects
                selectedFrameIndex = 0
                // Keep only the first detected frame selected; reject the rest so the user
                // can explicitly choose which ones to keep.
                rejectedFrameIndices = rects.count > 1 ? Set(1..<rects.count) : []
                statusMessage = rects.isEmpty
                    ? "No frames detected — try adjusting manually."
                    : "Detected \(rects.count) frame(s). Keep the one(s) you want, then tap Save."
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Detection failed."
            }
            isWorking = false
        }
    }

    // MARK: - Save

    private func save() {
        guard let parentURL, !frameRects.isEmpty, let db = appDatabase else { return }
        isWorking = true
        statusMessage = "Re-cropping and saving…"
        errorMessage = nil

        // Use the first non-rejected rect.
        let keptIndex = (0..<frameRects.count).first { !rejectedFrameIndices.contains($0) } ?? 0
        let newRect = frameRects[keptIndex]
        let outputURL = URL(fileURLWithPath: clip.filePath)
        let clipId = clip.id
        let baseName = (clip.canonicalName as NSString).deletingPathExtension

        Task {
            do {
                // 1. Crop from parent scan and overwrite the clip file.
                try await Task.detached(priority: .userInitiated) {
                    let source = try FilmStripFrameExtractor.loadImage(at: parentURL)
                    guard let cropped = source.cropping(to: newRect) else {
                        throw RefineFrameError.cropFailed(newRect)
                    }
                    guard let dest = CGImageDestinationCreateWithURL(
                        outputURL as CFURL,
                        UTType.tiff.identifier as CFString,
                        1, nil
                    ) else {
                        throw RefineFrameError.writeDestinationFailed(outputURL)
                    }
                    CGImageDestinationAddImage(dest, cropped, nil)
                    guard CGImageDestinationFinalize(dest) else {
                        throw RefineFrameError.writeFailed(outputURL)
                    }
                }.value

                // 2. Update DB: new crop rect + reset processing state so proxy is regenerated.
                let now = ISO8601DateFormatter().string(from: .now)
                try await db.dbPool.write { database in
                    try database.execute(
                        sql: """
                            UPDATE asset_lineage
                            SET crop_rect_x = ?, crop_rect_y = ?, crop_rect_w = ?, crop_rect_h = ?
                            WHERE child_photo_id = ? AND operation = 'film_strip_extract'
                            """,
                        arguments: [newRect.origin.x, newRect.origin.y,
                                    newRect.width, newRect.height, clipId]
                    )
                    try database.execute(
                        sql: "UPDATE photo_assets SET processing_state = 'proxyPending', updated_at = ? WHERE id = ?",
                        arguments: [now, clipId]
                    )
                }

                // 3. Delete stale proxy so the library shows a fresh thumbnail.
                let proxyURL = ProxyGenerationActor.proxiesDirectory()
                    .appendingPathComponent(baseName + ".jpg")
                try? FileManager.default.removeItem(at: proxyURL)

                // 4. Re-generate proxy immediately.
                let photoRepo = PhotoRepository(db: db)
                let proxyRepo = ProxyAssetRepository(db: db)
                let proxyActor = ProxyGenerationActor(photoRepo: photoRepo, proxyRepo: proxyRepo)
                for await _ in proxyActor.processLocalQueue() {}

                statusMessage = "Saved."
                try await Task.sleep(nanoseconds: 400_000_000)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                statusMessage = "Save failed."
                isWorking = false
            }
        }
    }
}

// MARK: - Errors

private enum RefineFrameError: LocalizedError {
    case cropFailed(CGRect)
    case writeDestinationFailed(URL)
    case writeFailed(URL)

    var errorDescription: String? {
        switch self {
        case .cropFailed(let r):
            return "Failed to crop image at rect \(r)."
        case .writeDestinationFailed(let url):
            return "Could not create image destination at \(url.lastPathComponent)."
        case .writeFailed(let url):
            return "Failed to write TIFF to \(url.lastPathComponent)."
        }
    }
}
