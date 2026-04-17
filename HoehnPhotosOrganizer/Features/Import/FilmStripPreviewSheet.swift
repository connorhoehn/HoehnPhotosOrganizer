import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FilmStripPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDatabase) private var appDatabase: AppDatabase?
    @Environment(\.activityEventService) private var activityEventService: ActivityEventService?

    /// The photo_assets.id of the parent scan that was opened to launch this sheet.
    /// Optional because the sheet can also be opened without a pre-selected source photo
    /// (e.g., from ImportWizardView before any photo is selected in the grid).
    let sourcePhotoId: String?

    @State private var selectedURL: URL?
    @State private var previewImage: NSImage?        // downsampled display copy
    @State private var imagePixelSize: CGSize = .zero // original pixel dimensions
    @State private var frameRects: [CGRect] = []
    @State private var exportedURLs: [URL] = []
    @State private var statusMessage = "Choose a film strip image to preview frame detection."
    @State private var progressDetail = ""
    @State private var errorMessage: String?
    @State private var showOverlay = true
    @State private var isWorking = false
    @State private var exportRootDirectory: URL?
    @State private var trimBordersEnabled: Bool = true
    @State private var trimResults: [FrameTrimResult] = []
    @State private var pipelineRuns: [PipelineToolRun] = []
    @State private var rollLabel: String = ""
    @State private var showingPersistError = false
    @State private var selectedFrameIndex: Int = 0
    @State private var rejectedFrameIndices: Set<Int> = []
    @State private var zoomScale: CGFloat = 1.0
    @State private var stripRotationDegrees: Int = 0

    init(sourcePhotoId: String? = nil) {
        self.sourcePhotoId = sourcePhotoId
    }

    private let minimumFrameWidth: CGFloat = 220

    private var latestExportDirectory: URL? {
        exportedURLs.first?.deletingLastPathComponent()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Film Strip Preview")
                        .font(.largeTitle.bold())
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if isWorking || !progressDetail.isEmpty {
                        Text(progressDetail)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }

                Spacer()

                Toggle("Show overlays", isOn: $showOverlay)
                    .toggleStyle(.switch)

                Button("Choose Image") {
                    chooseTIFF()
                }

                Button("Detect Again") {
                    detectFrames()
                }
                .disabled(selectedURL == nil || isWorking)

                Button("Export Frames") {
                    exportFrames()
                }
                .buttonStyle(.borderedProminent)
                .disabled(frameRects.isEmpty || selectedURL == nil || isWorking)

                Button("Reveal in Finder") {
                    revealInFinder()
                }
                .disabled(latestExportDirectory == nil)

                Button("Done") {
                    dismiss()
                }
            }
            .padding(20)

            Divider()

            HStack(spacing: 0) {
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
                    } else {
                        ContentUnavailableView(
                            "No Image Selected",
                            systemImage: "photo.stack",
                            description: Text("Choose a film strip image to see detected crop overlays before export.")
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Detection")
                        .font(.headline)

                    SettingsRow(title: "Selected file", value: selectedURL?.lastPathComponent ?? "None")
                    SettingsRow(title: "Detected frames", value: "\(frameRects.count)")
                    SettingsRow(title: "Preview size", value: imagePixelSize == .zero ? "—" : "\(Int(imagePixelSize.width)) × \(Int(imagePixelSize.height))")
                    SettingsRow(title: "Detector", value: "YOLO")
                    SettingsRow(title: "Export folder", value: exportRootDirectory?.lastPathComponent ?? "Source folder")

                    Button("Choose Export Folder") {
                        chooseExportFolder()
                    }
                    .disabled(isWorking)

                    Toggle("Trim frame borders", isOn: $trimBordersEnabled)
                        .toggleStyle(.switch)
                        .help("Automatically remove the dark film-rebate border on all four sides after cropping.")

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "rotate.right")
                                .foregroundStyle(.secondary)
                            Text("Strip rotation")
                                .font(.subheadline)
                        }
                        Picker("Strip rotation", selection: $stripRotationDegrees) {
                            Text("0°").tag(0)
                            Text("90°").tag(90)
                            Text("180°").tag(180)
                            Text("270°").tag(270)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: stripRotationDegrees) {
                            // Re-detect with the new rotation applied to the raw image.
                            if let url = selectedURL { loadPreviewAndDetect(from: url) }
                        }
                        Text("Use if your scanner saved the strip sideways (orientation=1).")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Roll Label")
                            .font(.headline)
                        TextField("Roll / batch label (optional)", text: $rollLabel)
                            .textFieldStyle(.roundedBorder)
                        Text("Tags all exported frames with this roll or sleeve identifier.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if !trimResults.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Frame Trim Stats")
                                .font(.headline)
                            ForEach(Array(trimResults.enumerated()), id: \.offset) { _, result in
                                HStack {
                                    Image(systemName: result.passed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(result.passed ? .green : .orange)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Frame \(result.frameIndex)")
                                            .font(.caption.bold())
                                        Text(String(format: "Conf: %.0f%%  AR: %.2f",
                                                    result.confidence * 100, result.detectedAspectRatio))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        if !result.passed {
                                            Text(result.validationNotes.last ?? "Low confidence.")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                    }

                    if !exportedURLs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Exported")
                                .font(.headline)

                            Button("Reveal in Finder") {
                                revealInFinder()
                            }

                            ForEach(exportedURLs, id: \.path) { url in
                                Text(url.lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.red.opacity(0.08))
                            )
                    }

                }
                .padding(20)
                } // end ScrollView
                .frame(width: 300)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDroppedFiles(providers)
            return true
        }
        .frame(minWidth: 1100, minHeight: 760)
        .overlay {
            if isWorking {
                ZStack {
                    Color.black.opacity(0.08).ignoresSafeArea()
                    ProgressView("Processing strip…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .alert("Export Error", isPresented: $showingPersistError) {
            Button("OK", role: .cancel) { showingPersistError = false }
        } message: {
            Text(errorMessage ?? "An unknown error occurred while writing to the catalog.")
        }
    }

    /// Reduces a full-res CGImage to a display-safe size so the UI stays responsive.
    /// Frame-rect coordinates always use `imagePixelSize` (original), not the display copy.
    static func downsample(_ image: CGImage, maxDimension: Int) -> CGImage {
        let w = image.width, h = image.height
        guard w > maxDimension || h > maxDimension else { return image }
        let scale = Double(maxDimension) / Double(max(w, h))
        let newW = max(1, Int(Double(w) * scale))
        let newH = max(1, Int(Double(h) * scale))
        let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: space,
            bitmapInfo: bitmapInfo
        ) else { return image }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage() ?? image
    }

    private func chooseTIFF() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.tiff, .png, .jpeg, .heic, .heif]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        selectedURL = url
        let parentDir = url.deletingLastPathComponent()
        if exportRootDirectory == nil {
            exportRootDirectory = parentDir
        }
        exportedURLs = []
        // Persist sandbox access for the film strip file and its directory
        Task { await BookmarkStore.shared.store(url) }
        Task { await BookmarkStore.shared.store(parentDir) }
        loadPreviewAndDetect(from: url)
    }

    private func handleDroppedFiles(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadDataRepresentation(for: .fileURL) { data, _ in
                guard let data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    handleDroppedFile(url)
                }
            }
        }
    }

    private func handleDroppedFile(_ url: URL) {
        let pathExtension = url.pathExtension.lowercased()

        // Check if it's a file or directory
        var isDir: ObjCBool = false
        let fileExists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

        guard fileExists else { return }

        if isDir.boolValue {
            // Handle folder drop - count images and offer import
            let imageExtensions = ["tiff", "tif", "png", "jpg", "jpeg", "heic", "heif"]
            let fileManager = FileManager.default
            if let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                let imageFiles = contents.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
                if !imageFiles.isEmpty {
                    statusMessage = "Found \(imageFiles.count) image\(imageFiles.count == 1 ? "" : "s") in folder."
                    progressDetail = "Folder import not yet implemented in this view."
                }
            }
        } else if pathExtension == "tiff" || pathExtension == "tif" || pathExtension == "png" || pathExtension == "jpg" || pathExtension == "jpeg" {
            // Film strip image - load it
            selectedURL = url
            if exportRootDirectory == nil {
                exportRootDirectory = url.deletingLastPathComponent()
            }
            exportedURLs = []
            loadPreviewAndDetect(from: url)
        } else if pathExtension == "dng" || pathExtension == "raw" || pathExtension == "cr2" || pathExtension == "arw" {
            // Raw file - show message for now
            statusMessage = "Raw file dropped"
            progressDetail = "Raw file handling requires database lookup (not yet implemented)."
        } else {
            // Unsupported format
            statusMessage = "Unsupported file type"
            progressDetail = "Please drop TIFF, PNG, JPEG, or HEIC files."
            errorMessage = "Unsupported file type: \(pathExtension). Expected film strip images (TIFF, PNG, JPEG, HEIC)."
        }
    }

    private func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        guard panel.runModal() == .OK, let folder = panel.url else { return }
        exportRootDirectory = folder
        // Persist sandbox access for the chosen export directory
        Task { await BookmarkStore.shared.store(folder) }
    }

    private func loadPreviewAndDetect(from url: URL) {
        isWorking = true
        errorMessage = nil
        progressDetail = "Loading image…"
        pipelineRuns = []
        selectedFrameIndex = 0
        rejectedFrameIndices = []

        let capturedRotation = stripRotationDegrees

        Task {
            do {
                let rawImage = try await withForegroundProcessingActivity("Film strip load") {
                    try await Task.detached(priority: .userInitiated) {
                        try FilmStripFrameExtractor.loadImage(at: url)
                    }.value
                }
                let cgImage: CGImage = capturedRotation != 0
                    ? (FilmStripFrameExtractor.rotateStatic(rawImage, clockwiseDegrees: capturedRotation) ?? rawImage)
                    : rawImage

                imagePixelSize = CGSize(width: cgImage.width, height: cgImage.height)
                let displayCG = Self.downsample(cgImage, maxDimension: 2400)
                previewImage = NSImage(cgImage: displayCG, size: NSSize(width: displayCG.width, height: displayCG.height))

                progressDetail = "Running YOLO detection…"
                let yolo = YOLOFrameDetector()
                let detectedRects = try await yolo.detectFrames(in: cgImage)
                frameRects = detectedRects

                if frameRects.isEmpty {
                    statusMessage = "No frames detected in \(url.lastPathComponent)."
                    errorMessage = "YOLO detection found no frames."
                    progressDetail = ""
                } else {
                    statusMessage = "Detected \(frameRects.count) frame\(frameRects.count == 1 ? "" : "s") in \(url.lastPathComponent)."
                    progressDetail = ""
                }
            } catch {
                frameRects = []
                errorMessage = error.localizedDescription
                statusMessage = "Detection failed."
                progressDetail = ""
            }

            isWorking = false
        }
    }

    private func detectFrames() {
        guard let selectedURL else { return }
        loadPreviewAndDetect(from: selectedURL)
    }

    private func exportFrames() {
        guard let selectedURL else { return }

        isWorking = true
        errorMessage = nil
        trimResults = []
        progressDetail = "Exporting cropped TIFF frames\(trimBordersEnabled ? " + trimming borders" : "")…"

        Task {
            do {
                let baseDirectory = exportRootDirectory ?? selectedURL.deletingLastPathComponent()
                let outputDirectory = baseDirectory
                    .appendingPathComponent(selectedURL.deletingPathExtension().lastPathComponent + "_frames", isDirectory: true)

                let exportRects = frameRects
                let shouldTrim = trimBordersEnabled

                let result = try await exportWithFallback(
                    sourceURL: selectedURL,
                    rects: exportRects,
                    preferredOutputDirectory: outputDirectory,
                    trimBorders: shouldTrim
                )

                exportedURLs = result.exportedURLs
                trimResults = result.trimResults
                pipelineRuns.append(contentsOf: result.toolRuns)
                let outputFolder = result.exportedURLs.first?.deletingLastPathComponent()
                statusMessage = "Exported \(result.exportedURLs.count) frame\(result.exportedURLs.count == 1 ? "" : "s") to \(outputFolder?.lastPathComponent ?? outputDirectory.lastPathComponent)."
                progressDetail = "Export complete."
                revealInFinder()

                // Persist extraction result to catalog.
                // Capture values needed inside the inner Task before any state mutation.
                let extractionResult = result
                let capturedSourcePhotoId = sourcePhotoId
                let capturedRollLabel = rollLabel.isEmpty ? nil : rollLabel
                let capturedPixelSize = imagePixelSize
                if let db = appDatabase {
                    let capturedActivityService = activityEventService
                    let frameCount = extractionResult.exportedURLs.count
                    Task {
                        do {
                            let orient = capturedPixelSize.height > capturedPixelSize.width * 1.2
                                ? FilmStripOrientation.vertical.rawValue
                                : FilmStripOrientation.horizontal.rawValue

                            // Emit importBatch event (fire-and-forget — never blocks ingestion).
                            let batchEventId: String? = try? await capturedActivityService?.emitImportBatch(
                                title: "Film scan import",
                                fileCount: frameCount
                            ).id

                            try await FilmScanIngestionService().persist(
                                extractionResult,
                                sourcePhotoId: capturedSourcePhotoId,
                                orientation: orient,
                                detectorMethod: "yolo",
                                batchLabel: capturedRollLabel,
                                toolLogs: extractionResult.toolRuns,
                                db: db,
                                activityService: capturedActivityService,
                                parentBatchEventId: batchEventId
                            )
                        } catch {
                            // Persist failure shows an alert but does not crash or undo the export.
                            await MainActor.run {
                                errorMessage = "Catalog write failed: \(error.localizedDescription)"
                                showingPersistError = true
                            }
                        }
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
                progressDetail = "Export failed."
            }

            isWorking = false
        }
    }

    private func revealInFinder() {
        guard !exportedURLs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(exportedURLs)
    }

    private func exportWithFallback(sourceURL: URL, rects: [CGRect], preferredOutputDirectory: URL, trimBorders: Bool) async throws -> FilmStripExtractionResult {
        var config = FilmStripFrameExtractor.Configuration()
        config.trimBordersAfterExport = trimBorders
        config.stripRotationDegrees = stripRotationDegrees
        let trimmedExtractor = FilmStripFrameExtractor(configuration: config)
        do {
            return try await withForegroundProcessingActivity("Film strip export") {
                try await Task.detached(priority: .userInitiated) {
                    try trimmedExtractor.exportFrames(from: sourceURL, frameRects: rects, to: preferredOutputDirectory)
                }.value
            }
        } catch {
            let fallbackDirectory = fallbackExportDirectory(for: sourceURL)
            let fallbackResult = try await withForegroundProcessingActivity("Film strip export fallback") {
                try await Task.detached(priority: .userInitiated) {
                    try trimmedExtractor.exportFrames(from: sourceURL, frameRects: rects, to: fallbackDirectory)
                }.value
            }
            await MainActor.run {
                exportRootDirectory = fallbackDirectory.deletingLastPathComponent()
                progressDetail = "No write access to source folder — exported to App Support."
            }
            return fallbackResult
        }
    }

    private func withForegroundProcessingActivity<T>(_ reason: String, operation: () async throws -> T) async throws -> T {
        let token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .automaticTerminationDisabled],
            reason: reason
        )
        defer { ProcessInfo.processInfo.endActivity(token) }
        return try await operation()
    }

    private func fallbackExportDirectory(for sourceURL: URL) -> URL {
        let fileManager = FileManager.default
        let appSupportBase = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        let root = appSupportBase
            .appendingPathComponent("HoehnPhotosOrganizer", isDirectory: true)
            .appendingPathComponent("Exports", isDirectory: true)

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return root.appendingPathComponent("\(sourceURL.deletingPathExtension().lastPathComponent)_frames_\(timestamp)", isDirectory: true)
    }
}

struct FilmStripPreviewCanvas: View {
    let image: NSImage
    let pixelSize: CGSize
    @Binding var frameRects: [CGRect]
    @Binding var selectedFrameIndex: Int
    @Binding var rejectedFrameIndices: Set<Int>
    @Binding var zoomScale: CGFloat
    let showOverlay: Bool

    @State private var draggingIndex: Int? = nil
    @State private var dragStartRect: CGRect = .zero

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let zoom: CGFloat = max(1.0, zoomScale)
                // Compute fit scale: how much to scale the pixel-size image to fit the container
                let fitScale = min(
                    geometry.size.width / pixelSize.width,
                    geometry.size.height / pixelSize.height
                )
                // Full display scale = fit scale * zoom
                let displayScale = fitScale * zoom
                let scaledSize = CGSize(width: pixelSize.width * displayScale, height: pixelSize.height * displayScale)

                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        Color(nsColor: .windowBackgroundColor)

                        Image(nsImage: image)
                            .resizable()
                            .frame(width: scaledSize.width, height: scaledSize.height)

                        if showOverlay {
                            ForEach(Array(frameRects.enumerated()), id: \.offset) { index, rect in
                                let isSelected = index == selectedFrameIndex
                                let isRejected = rejectedFrameIndices.contains(index)

                                let strokeColor = isRejected ? Color.red : Color.orange
                                let strokeWidth: CGFloat = isSelected ? 4 : 2
                                let fillOpacity: Double = isRejected ? 0.15 : 0.08

                                // -- whole-box move handle --
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(strokeColor, lineWidth: strokeWidth)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(strokeColor.opacity(fillOpacity))
                                    )
                                    .frame(width: rect.width * displayScale, height: rect.height * displayScale)
                                    .offset(x: rect.minX * displayScale, y: rect.minY * displayScale)
                                    .gesture(
                                        DragGesture()
                                            .onChanged { value in
                                                if draggingIndex != index {
                                                    draggingIndex = index
                                                    dragStartRect = frameRects[index]
                                                }
                                                let dx = value.translation.width / displayScale
                                                let dy = value.translation.height / displayScale
                                                var updated = dragStartRect
                                                updated.origin.x = dragStartRect.origin.x + dx
                                                updated.origin.y = dragStartRect.origin.y + dy
                                                // Clamp to image bounds
                                                updated.origin.x = max(0, min(pixelSize.width - updated.width, updated.origin.x))
                                                updated.origin.y = max(0, min(pixelSize.height - updated.height, updated.origin.y))
                                                frameRects[index] = updated
                                            }
                                            .onEnded { _ in draggingIndex = nil }
                                    )

                                // -- frame number badge --
                                Text("\(index + 1)")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.thinMaterial, in: Capsule())
                                    .offset(x: rect.minX * displayScale + 18, y: rect.minY * displayScale + 16)

                                // -- corner resize handles --
                                let handleSize: CGFloat = 16
                                let corners: [(dx: CGFloat, dy: CGFloat, tag: String)] = [
                                    (0, 0, "tl"),
                                    (rect.width, 0, "tr"),
                                    (0, rect.height, "bl"),
                                    (rect.width, rect.height, "br"),
                                ]

                                ForEach(corners, id: \.tag) { corner in
                                    Circle()
                                        .fill(Color.white)
                                        .overlay(Circle().stroke(strokeColor, lineWidth: 2))
                                        .frame(width: handleSize, height: handleSize)
                                        .offset(
                                            x: (rect.minX + corner.dx) * displayScale - handleSize / 2,
                                            y: (rect.minY + corner.dy) * displayScale - handleSize / 2
                                        )
                                        .gesture(
                                            DragGesture()
                                                .onChanged { value in
                                                    if draggingIndex != index {
                                                        draggingIndex = index
                                                        dragStartRect = frameRects[index]
                                                    }
                                                    let dx = value.translation.width / displayScale
                                                    let dy = value.translation.height / displayScale
                                                    var r = dragStartRect
                                                    switch corner.tag {
                                                    case "tl":
                                                        r.origin.x = min(dragStartRect.maxX - 20, dragStartRect.origin.x + dx)
                                                        r.origin.y = min(dragStartRect.maxY - 20, dragStartRect.origin.y + dy)
                                                        r.size.width = dragStartRect.maxX - r.origin.x
                                                        r.size.height = dragStartRect.maxY - r.origin.y
                                                    case "tr":
                                                        r.size.width = max(20, dragStartRect.width + dx)
                                                        r.origin.y = min(dragStartRect.maxY - 20, dragStartRect.origin.y + dy)
                                                        r.size.height = dragStartRect.maxY - r.origin.y
                                                    case "bl":
                                                        r.origin.x = min(dragStartRect.maxX - 20, dragStartRect.origin.x + dx)
                                                        r.size.width = dragStartRect.maxX - r.origin.x
                                                        r.size.height = max(20, dragStartRect.height + dy)
                                                    case "br":
                                                        r.size.width = max(20, dragStartRect.width + dx)
                                                        r.size.height = max(20, dragStartRect.height + dy)
                                                    default: break
                                                    }
                                                    // Clamp origin to image bounds
                                                    r.origin.x = max(0, r.origin.x)
                                                    r.origin.y = max(0, r.origin.y)
                                                    frameRects[index] = r
                                                }
                                                .onEnded { _ in draggingIndex = nil }
                                        )
                                }
                            }
                        }
                    }
                    .frame(width: scaledSize.width, height: scaledSize.height)
                }
                .focusable()
                .onKeyPress(.leftArrow) {
                    selectedFrameIndex = max(0, selectedFrameIndex - 1)
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    selectedFrameIndex = min(frameRects.count - 1, selectedFrameIndex + 1)
                    return .handled
                }
                .onKeyPress(.space) {
                    let idx = selectedFrameIndex
                    if rejectedFrameIndices.contains(idx) {
                        rejectedFrameIndices.remove(idx)
                    } else {
                        rejectedFrameIndices.insert(idx)
                    }
                    return .handled
                }
            }
            .frame(maxHeight: .infinity)

            Divider()

            HStack(spacing: 12) {
                Text("Zoom")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 36)
                Slider(value: $zoomScale, in: 1...4, step: 0.1)
                    .help("Zoom in to inspect frame boundaries")
                Text(String(format: "%.1f×", zoomScale))
                    .font(.caption.monospaced())
                    .frame(width: 40)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }
}
