import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - ImportTemplate

/// Describes which category of files the user is importing.
enum ImportTemplate: String, CaseIterable, Identifiable {
    case digitalPhotos = "digital_photos"
    case filmScans = "film_scans"
    case indexHardDrive = "index_hard_drive"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .digitalPhotos: return "Digital Photos"
        case .filmScans:     return "Film Scans"
        case .indexHardDrive: return "Index Hard Drive"
        }
    }

    var subtitle: String {
        switch self {
        case .digitalPhotos: return "Import JPEG, HEIC, RAW, and DNG files"
        case .filmScans:     return "Import film strip TIFFs and extract frames"
        case .indexHardDrive: return "Browse and index photos on an external drive"
        }
    }

    var iconName: String {
        switch self {
        case .digitalPhotos: return "photo.on.rectangle.angled"
        case .filmScans:     return "film"
        case .indexHardDrive: return "externaldrive.badge.plus"
        }
    }
}

// MARK: - ImportWizardPhase

/// Drives the ImportWizardView state machine.
enum ImportWizardPhase: Equatable {
    case templatePicker
    case dropZone(template: ImportTemplate)
    /// Running detection across all dropped scan files; transitions automatically to `frameReview`.
    case detecting(template: ImportTemplate, fileURLs: [URL])
    /// Lightroom-style confirmation grid; detected frames are stored in `ImportWizardView.detectedFrames`.
    case frameReview(template: ImportTemplate, fileURLs: [URL])
    /// Single-strip adjustment view (kept for direct access from elsewhere in the app).
    case filmStripPreview(template: ImportTemplate, fileURLs: [URL])
    /// Thumbnail confirmation grid for digital photo imports.
    case photoReview(template: ImportTemplate, fileURLs: [URL])
}

// MARK: - ImportWizardView

struct ImportWizardView: View {
    @Environment(\.dismiss) private var dismiss

    let drives: [DriveDB]
    /// Called when the user confirms a digital-photo import. Caller performs the DB write.
    var onImportDigitalPhotos: (([URL]) -> Void)? = nil
    /// Called when the user picks "Index Hard Drive" — caller should navigate to Drives section.
    var onNavigateToDrives: (() -> Void)? = nil

    @State private var phase: ImportWizardPhase = .templatePicker
    /// Frames produced by `FilmStripDetectingView` and consumed by `FrameReviewView`.
    @State private var detectedFrames: [DetectedFrame] = []
    /// CW degrees to rotate each strip image before YOLO detection (0/90/180/270).
    /// Set in the drop zone when the scanner saved a sideways strip with orientation=1.
    @State private var stripRotation: Int = 0

    var body: some View {
        Group {
            switch phase {
            case .templatePicker:
                ImportTemplatePickerView { template in
                    if template == .indexHardDrive {
                        dismiss()
                        onNavigateToDrives?()
                    } else {
                        phase = .dropZone(template: template)
                    }
                }
            case .dropZone(let template):
                ImportDropZoneView(
                    template: template,
                    stripRotation: $stripRotation,
                    onConfirm: { urls in
                        if template == .filmScans {
                            // Film scans: run detection first, then show review grid.
                            phase = .detecting(template: template, fileURLs: urls)
                        } else {
                            // Digital photos: show confirmation grid before importing.
                            phase = .photoReview(template: template, fileURLs: urls)
                        }
                    },
                    onBack: {
                        phase = .templatePicker
                    }
                )
            case .detecting(let template, let fileURLs):
                FilmStripDetectingView(
                    template: template,
                    fileURLs: fileURLs,
                    stripRotationDegrees: stripRotation,
                    onComplete: { frames in
                        detectedFrames = frames
                        phase = .frameReview(template: template, fileURLs: fileURLs)
                    },
                    onBack: {
                        phase = .dropZone(template: template)
                    }
                )
            case .frameReview(let template, let fileURLs):
                FrameReviewView(
                    template: template,
                    frames: detectedFrames,
                    stripRotationDegrees: stripRotation,
                    onImport: { _ in dismiss() },
                    onBack: {
                        phase = .detecting(template: template, fileURLs: fileURLs)
                    }
                )
            case .filmStripPreview(let template, let fileURLs):
                FilmStripPreviewSheetView(
                    template: template,
                    fileURLs: fileURLs,
                    onBack: {
                        phase = .dropZone(template: template)
                    },
                    onDismiss: { dismiss() }
                )
            case .photoReview(let template, let fileURLs):
                PhotoReviewView(
                    template: template,
                    fileURLs: fileURLs,
                    onImport: { selectedURLs in
                        print("[ImportWizard] Importing \(selectedURLs.count) digital photo(s)")
                        onImportDigitalPhotos?(selectedURLs)
                        dismiss()
                    },
                    onBack: {
                        phase = .dropZone(template: template)
                    }
                )
            }
        }
        .padding(24)
        .frame(minWidth: 960, minHeight: 640)
    }

}

// MARK: - ImportTemplatePickerView

struct ImportTemplatePickerView: View {
    let onSelect: (ImportTemplate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What are you importing?")
                    .font(.title.bold())
                Text("Choose a workflow to get started.")
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ],
                spacing: 16
            ) {
                ForEach(ImportTemplate.allCases) { template in
                    ImportTemplateCard(template: template) {
                        onSelect(template)
                    }
                }
            }

            Spacer()
        }
    }
}

// MARK: - ImportTemplateCard

struct ImportTemplateCard: View {
    let template: ImportTemplate
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            onTap()
        } label: {
            VStack(alignment: .center, spacing: 16) {
                Image(systemName: template.iconName)
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .center, spacing: 4) {
                    Text(template.title)
                        .font(.headline.bold())
                        .foregroundStyle(.primary)
                    Text(template.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .opacity(isHovered ? 0.8 : 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: isHovered ? 2 : 0)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - ImportDropZoneView

struct ImportDropZoneView: View {
    let template: ImportTemplate
    /// Only used (and shown) when `template == .filmScans`.
    @Binding var stripRotation: Int
    @State private var isTargeted = false
    @State private var droppedURLs: [URL] = []
    @State private var errorMessage: String?
    let onConfirm: ([URL]) -> Void
    let onBack: () -> Void

    private var isComingSoon: Bool {
        template == .indexHardDrive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: template.iconName)
                            .font(.system(size: 20))
                            .foregroundStyle(Color.accentColor)
                        Text(template.title)
                            .font(.title.bold())
                    }
                    Text(template.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("← Back") {
                    onBack()
                }
                .buttonStyle(.bordered)
            }

            if isComingSoon {
                VStack(alignment: .center, spacing: 12) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Coming Soon")
                        .font(.title2.bold())
                    Text("Hard drive indexing will be available in a future release.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Select Files to Import")
                        .font(.title.bold())
                    Text("Drag photos here or click below to browse.")
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 16) {
                    dropZoneRect

                    HStack {
                        Button("or click to browse") {
                            browseFolders()
                        }
                        .buttonStyle(.bordered)

                        Spacer()
                    }

                    if !droppedURLs.isEmpty {
                        detectionSummary
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

                Spacer()

                HStack {
                    Spacer()
                    Button("Continue") {
                        onConfirm(droppedURLs)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(droppedURLs.isEmpty)
                }
            }
        }
    }

    private var dropZoneRect: some View {
        VStack(spacing: 12) {
            VStack {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Drop photos here")
                    .font(.headline)
                Text("or use the browse button below")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 2, dash: [6])
                )
                .foregroundStyle(isTargeted ? Color.accentColor : Color(nsColor: .separatorColor))
        )
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isTargeted ? Color(red: 0, green: 0.5, blue: 1).opacity(0.08) : Color.clear)
        )
        .scaleEffect(isTargeted ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isTargeted)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDroppedFiles(providers)
            return true
        }
    }

    private var detectionSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(droppedURLs.count) file\(droppedURLs.count == 1 ? "" : "s") selected")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(droppedURLs.prefix(3), id: \.path) { url in
                    Text(url.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if droppedURLs.count > 3 {
                    Text("and \(droppedURLs.count - 3) more…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    private var stripRotationPicker: some View {
        HStack(spacing: 10) {
            Image(systemName: "rotate.right")
                .foregroundStyle(.secondary)
            Text("Strip rotation:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("Strip rotation", selection: $stripRotation) {
                Text("0°").tag(0)
                Text("90° CW").tag(90)
                Text("180°").tag(180)
                Text("270° CW").tag(270)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Text("Apply if your scanner saved the strip sideways.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func browseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true   // allow selecting a folder of scans
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            .tiff, .jpeg, .png, .heic,
            UTType(filenameExtension: "dng") ?? .rawImage,
        ]
        panel.message = "Select scan files or a folder containing them"

        if panel.runModal() == .OK {
            droppedURLs = resolveImageURLs(from: panel.urls)
            errorMessage = nil
            for url in panel.urls {
                Task { await BookmarkStore.shared.store(url) }
            }
        }
    }

    private func handleDroppedFiles(_ providers: [NSItemProvider]) {
        var urls: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            // loadItem returns the original file URL (not a sandbox copy like loadFileRepresentation).
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                // The item arrives as Data containing the URL's absolute string, or as NSURL.
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                } else if let url = item as? URL {
                    urls.append(url)
                } else if let nsurl = item as? NSURL, let url = nsurl as URL? {
                    urls.append(url)
                }
            }
        }

        group.notify(queue: .main) {
            droppedURLs = resolveImageURLs(from: urls)
            errorMessage = nil
            for url in urls {
                Task { await BookmarkStore.shared.store(url) }
            }
        }
    }

    /// Recursively expands directories and returns all image file URLs sorted by path.
    private func resolveImageURLs(from inputs: [URL]) -> [URL] {
        let imageExtensions: Set<String> = ["tif", "tiff", "jpg", "jpeg", "png", "heic", "dng", "raw", "arw", "cr2", "nef"]
        var resolved: [URL] = []
        for url in inputs {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                guard let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for case let fileURL as URL in enumerator {
                    if imageExtensions.contains(fileURL.pathExtension.lowercased()) {
                        resolved.append(fileURL)
                    }
                }
            } else if imageExtensions.contains(url.pathExtension.lowercased()) {
                resolved.append(url)
            }
        }
        return resolved.sorted { $0.path < $1.path }
    }
}

// MARK: - FilmStripPreviewSheetView

/// Wrapper around FilmStripPreviewSheet that auto-loads provided URLs
struct FilmStripPreviewSheetView: View {
    let template: ImportTemplate
    let fileURLs: [URL]
    let onBack: () -> Void
    let onDismiss: () -> Void

    @Environment(\.appDatabase) private var appDatabase: AppDatabase?
    @State private var selectedURL: URL?
    @State private var previewImage: NSImage?
    @State private var imagePixelSize: CGSize = .zero
    @State private var frameRects: [CGRect] = []
    @State private var exportedURLs: [URL] = []
    @State private var statusMessage = ""
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: template.iconName)
                            .font(.system(size: 18))
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Film Strip Preview")
                                .font(.largeTitle.bold())
                            Text("\(fileURLs.count) file\(fileURLs.count == 1 ? "" : "s") imported")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(statusMessage.isEmpty ? "Loading film strip…" : statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Toggle("Show overlays", isOn: $showOverlay)
                    .toggleStyle(.switch)

                Button("← Back") { onBack() }
                    .buttonStyle(.bordered)

                Button("Done") { onDismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(20)

            Divider()

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
                VStack {
                    ProgressView("Loading film strip…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .onAppear {
            loadFirstFile()
        }
    }

    private func loadFirstFile() {
        guard !fileURLs.isEmpty else { return }
        selectedURL = fileURLs.first
        if let url = selectedURL {
            loadPreviewAndDetect(from: url)
        }
    }

    private func loadPreviewAndDetect(from url: URL) {
        isWorking = true
        errorMessage = nil
        progressDetail = "Loading image…"
        pipelineRuns = []
        selectedFrameIndex = 0
        rejectedFrameIndices = []

        Task {
            do {
                let cgImage = try FilmStripFrameExtractor.loadImage(at: url)
                let displayCG = Self.downsample(cgImage, maxDimension: 2400)

                let yolo = YOLOFrameDetector()
                let detectedRects = try await yolo.detectFrames(in: cgImage)

                await MainActor.run {
                    imagePixelSize = CGSize(width: cgImage.width, height: cgImage.height)
                    previewImage = NSImage(cgImage: displayCG, size: NSSize(width: displayCG.width, height: displayCG.height))
                    frameRects = detectedRects
                    statusMessage = "Detected \(frameRects.count) frame\(frameRects.count == 1 ? "" : "s") in \(url.lastPathComponent)."
                    progressDetail = ""
                    isWorking = false
                }
            } catch {
                await MainActor.run {
                    frameRects = []
                    errorMessage = error.localizedDescription
                    statusMessage = "Detection failed."
                    progressDetail = ""
                    isWorking = false
                }
            }
        }
    }

    private static func downsample(_ image: CGImage, maxDimension: Int) -> CGImage {
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
}

// MARK: - PhotoReviewView

/// Lightroom-style confirmation grid for digital photo imports.
/// Shows thumbnails of all dropped/browsed files; user clicks to deselect before importing.
struct PhotoReviewView: View {
    let template: ImportTemplate
    let fileURLs: [URL]
    let onImport: ([URL]) -> Void
    let onBack: () -> Void

    @State private var deselectedURLs: Set<URL> = []

    private var selectedURLs: [URL] { fileURLs.filter { !deselectedURLs.contains($0) } }

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: template.iconName)
                            .font(.system(size: 18))
                            .foregroundStyle(Color.accentColor)
                        Text("Review Photos")
                            .font(.title.bold())
                    }
                    Text("\(fileURLs.count) photo\(fileURLs.count == 1 ? "" : "s") ready to import")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("← Back") { onBack() }
                    .buttonStyle(.bordered)
            }
            .padding(.bottom, 16)

            // Toolbar
            HStack(spacing: 12) {
                Button("Select All") { deselectedURLs = [] }
                    .buttonStyle(.bordered)
                Button("Deselect All") { deselectedURLs = Set(fileURLs) }
                    .buttonStyle(.bordered)
                Spacer()
                Text("\(selectedURLs.count) of \(fileURLs.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 12)

            Divider()

            // Thumbnail grid
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(fileURLs, id: \.path) { url in
                        PhotoReviewCell(
                            url: url,
                            isSelected: !deselectedURLs.contains(url)
                        ) {
                            if deselectedURLs.contains(url) {
                                deselectedURLs.remove(url)
                            } else {
                                deselectedURLs.insert(url)
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
            }

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Import \(selectedURLs.count) Photo\(selectedURLs.count == 1 ? "" : "s")") {
                    onImport(selectedURLs)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedURLs.isEmpty)
            }
            .padding(.top, 12)
        }
    }
}

// MARK: - PhotoReviewCell

private struct PhotoReviewCell: View {
    let url: URL
    let isSelected: Bool
    let onTap: () -> Void

    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Rectangle()
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .overlay(
                                    Image(systemName: "photo")
                                        .foregroundStyle(.secondary)
                                )
                        }
                    }
                    .frame(width: 130, height: 95)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .opacity(isSelected ? 1.0 : 0.3)

                    // Selection badge
                    ZStack {
                        Circle().fill(isSelected ? Color.accentColor : Color.black.opacity(0.3))
                        Image(systemName: isSelected ? "checkmark" : "")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 18, height: 18)
                    .padding(4)
                }

                Text(url.lastPathComponent)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 130)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .task {
            thumbnail = await loadThumbnail(url: url)
        }
    }

    private func loadThumbnail(url: URL) async -> NSImage? {
        await Task.detached(priority: .utility) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 260,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value
    }
}
