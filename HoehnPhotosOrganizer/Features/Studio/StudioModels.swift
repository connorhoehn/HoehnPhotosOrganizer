import SwiftUI
import Foundation
import Combine
import UniformTypeIdentifiers

// MARK: - StudioPage

enum StudioPage: String, CaseIterable, Identifiable {
    case canvas = "Canvas"
    case mediums = "Mediums"
    case history = "History"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .canvas:  return "paintbrush.pointed.fill"
        case .mediums: return "paintpalette"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

// MARK: - ArtMedium

enum ArtMedium: String, CaseIterable, Identifiable, Codable {
    case oil = "Oil Painting"
    case watercolor = "Watercolor"
    case charcoal = "Charcoal"
    case troisCrayon = "Trois Crayon"
    case graphite = "Graphite"
    case inkWash = "Ink Wash"
    case pastel = "Pastel"
    case penAndInk = "Pen & Ink"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .oil:         return "drop.fill"
        case .watercolor:  return "drop.triangle"
        case .charcoal:    return "scribble"
        case .troisCrayon: return "pencil.and.outline"
        case .graphite:    return "pencil"
        case .inkWash:     return "paintbrush"
        case .pastel:      return "circle.lefthalf.filled"
        case .penAndInk:   return "pencil.tip"
        }
    }

    var description: String {
        switch self {
        case .oil:         return "Rich, textured brushstrokes with visible impasto and blended edges"
        case .watercolor:  return "Transparent washes, wet-on-wet bleeding, granulation, and paper texture"
        case .charcoal:    return "Deep blacks, soft gradations, expressive marks on textured paper"
        case .troisCrayon: return "Three-color crayon technique: sanguine, sepia, and white chalk on toned paper"
        case .graphite:    return "Precise pencil rendering with fine hatching and smooth tonal gradation"
        case .inkWash:     return "East Asian brush painting style with ink dilution for tonal range"
        case .pastel:      return "Soft, chalky color with visible strokes and blended passages"
        case .penAndInk:   return "Cross-hatching, stippling, and line work in black ink"
        }
    }

    var defaultParams: MediumParameters {
        switch self {
        case .oil:         return MediumParameters(brushSize: 8, detail: 0.6, texture: 0.7, colorSaturation: 0.8, contrast: 0.5)
        case .watercolor:  return MediumParameters(brushSize: 12, detail: 0.4, texture: 0.8, colorSaturation: 0.6, contrast: 0.3)
        case .charcoal:    return MediumParameters(brushSize: 6, detail: 0.7, texture: 0.9, colorSaturation: 0.0, contrast: 0.8)
        case .troisCrayon: return MediumParameters(brushSize: 5, detail: 0.6, texture: 0.7, colorSaturation: 0.3, contrast: 0.6)
        case .graphite:    return MediumParameters(brushSize: 3, detail: 0.8, texture: 0.5, colorSaturation: 0.0, contrast: 0.6)
        case .inkWash:     return MediumParameters(brushSize: 10, detail: 0.5, texture: 0.6, colorSaturation: 0.0, contrast: 0.7)
        case .pastel:      return MediumParameters(brushSize: 9, detail: 0.5, texture: 0.8, colorSaturation: 0.7, contrast: 0.4)
        case .penAndInk:   return MediumParameters(brushSize: 2, detail: 0.9, texture: 0.3, colorSaturation: 0.0, contrast: 0.9)
        }
    }

    var paperColor: Color {
        switch self {
        case .troisCrayon: return Color(red: 0.76, green: 0.70, blue: 0.62) // toned paper
        case .charcoal:    return Color(red: 0.92, green: 0.90, blue: 0.87) // off-white
        case .inkWash:     return Color(red: 0.95, green: 0.93, blue: 0.88) // rice paper
        default:           return .white
        }
    }
}

// MARK: - MediumParameters

struct MediumParameters: Equatable, Codable {
    var brushSize: Double       // 1–20 (relative)
    var detail: Double          // 0–1 (0=abstract, 1=photorealistic)
    var texture: Double         // 0–1 (paper/canvas texture intensity)
    var colorSaturation: Double // 0–1 (0=monochrome, 1=vivid)
    var contrast: Double        // 0–1
}

// MARK: - StudioVersion

struct StudioVersion: Identifiable, Codable {
    let id: UUID
    var name: String
    let medium: ArtMedium
    let params: MediumParameters
    let createdAt: Date
    /// Filename of the JPEG thumbnail stored alongside the JSON metadata.
    var thumbnailFilename: String?
    /// In-memory thumbnail; not persisted in JSON.
    var thumbnail: NSImage?
    /// On-disk JPEG file size in bytes.
    var fileSizeBytes: Int64?

    enum CodingKeys: String, CodingKey {
        case id, name, medium, params, createdAt, thumbnailFilename, fileSizeBytes
    }

    init(id: UUID = UUID(), name: String, medium: ArtMedium, params: MediumParameters, thumbnail: NSImage? = nil) {
        self.id = id
        self.name = name
        self.medium = medium
        self.params = params
        self.createdAt = Date()
        self.thumbnailFilename = thumbnail != nil ? "\(id.uuidString).jpg" : nil
        self.thumbnail = thumbnail
    }
}

// MARK: - VersionSortOrder

enum VersionSortOrder: String, CaseIterable, Identifiable {
    case dateNewest = "Newest First"
    case dateOldest = "Oldest First"
    case mediumName = "By Medium"

    var id: String { rawValue }
}

// MARK: - StudioViewModel

@MainActor
class StudioViewModel: ObservableObject {
    @Published var currentPage: StudioPage = .canvas
    @Published var sourceImage: NSImage?
    @Published var croppedImage: NSImage?
    @Published var renderedImage: NSImage?
    @Published var selectedMedium: ArtMedium = .oil
    @Published var params: MediumParameters = ArtMedium.oil.defaultParams
    /// Type-safe params set by toolbar controls. When non-nil, takes precedence for rendering.
    @Published var typedParams: MediumParams?

    /// Bridge: return typedParams if set, otherwise convert legacy params.
    var mediumParams: MediumParams {
        typedParams ?? MediumParams.fromLegacy(
            medium: selectedMedium,
            brushSize: params.brushSize,
            detail: params.detail,
            texture: params.texture,
            colorSaturation: params.colorSaturation,
            contrast: params.contrast
        )
    }
    @Published var isRendering: Bool = false
    @Published var isFullRendering: Bool = false
    @Published var renderProgress: Double = 0
    @Published var fullRenderProgress: Double = 0
    @Published var renderStartTime: Date? = nil
    @Published var renderStepName: String = ""
    @Published var isPreview: Bool = true
    @Published var versions: [StudioVersion] = []
    @Published var showingCropTool: Bool = false

    // Contour/number overlay toggles (used by StudioToolbar + StudioCanvasView)
    @Published var showContours: Bool = false
    @Published var showNumbers: Bool = false

    // Overlay image generated from contour/number rendering
    @Published var overlayImage: NSImage?
    @Published var overlayRegions: [PBNRegion] = []
    @Published var isGeneratingOverlay: Bool = false
    @Published var overlayPalette: PBNPalette = .classic

    /// Undo/redo command stack for canvas parameter changes.
    let commandStack = CommandStack()

    /// Stored so callers can cancel an in-progress render.
    private(set) var renderTask: Task<Void, Never>? = nil

    /// Pluggable renderer — OpenCV backend for production-quality artistic output.
    private let renderer: StudioRenderer = OpenCVStudioRenderer()

    /// Activity event service — set by the host view via environment injection.
    var activityEventService: ActivityEventService?

    // Chat
    let chatService = StudioChatService()
    @Published var chatMessages: [StudioChatMessage] = []
    @Published var chatInput: String = ""
    @Published var chatLoading: Bool = false

    /// Send a chat message through the real Claude API and append the response.
    func sendChatMessage(_ text: String) {
        let userMsg = StudioChatMessage(role: .user, text: text)
        chatMessages.append(userMsg)
        chatLoading = true

        Task {
            do {
                let result = try await chatService.send(
                    message: text,
                    history: Array(chatMessages.dropLast()),
                    medium: selectedMedium,
                    params: params,
                    hasImage: sourceImage != nil || croppedImage != nil,
                    hasRender: renderedImage != nil
                )
                chatMessages.append(StudioChatMessage(role: .assistant, text: result.reply))
                for suggestion in result.suggestions {
                    applySuggestion(suggestion)
                }
            } catch {
                let errorText = error.localizedDescription
                chatMessages.append(StudioChatMessage(role: .assistant, text: errorText))
            }
            chatLoading = false
        }
    }

    private func applySuggestion(_ suggestion: StudioChatService.ParameterSuggestion) {
        switch suggestion.parameterName {
        case "brushSize":       params.brushSize = min(20, max(1, suggestion.value))
        case "detail":          params.detail = min(1, max(0, suggestion.value))
        case "texture":         params.texture = min(1, max(0, suggestion.value))
        case "colorSaturation": params.colorSaturation = min(1, max(0, suggestion.value))
        case "contrast":        params.contrast = min(1, max(0, suggestion.value))
        default: break
        }
    }

    /// The photo_assets.id of the source photo loaded from the library (nil when loaded from file/drop).
    @Published var sourcePhotoId: String?

    /// Database-backed revisions for the current source photo.
    @Published var dbRevisions: [StudioRevision] = []

    /// Repository for persisting studio revisions. Injected via `configure(db:)`.
    private var revisionRepo: StudioRevisionRepository?

    /// Call once after init to wire up database persistence.
    func configure(db: AppDatabase) {
        self.revisionRepo = StudioRevisionRepository(db: db)
        self.canvasRepo = StudioCanvasRepository(db: db)
        Task { await loadAllCanvases() }
    }

    /// Load a source image from the library, tracking the photo ID for revision persistence.
    func loadFromLibrary(photo: PhotoAsset, image: NSImage) {
        sourcePhotoId = photo.id
        sourceImage = image
        renderedImage = nil
        croppedImage = nil
        Task { await loadRevisions(for: photo.id) }
    }

    // MARK: - Persistence

    private static let versionsDirectoryName = "StudioVersions"

    /// Root directory for persisted studio versions.
    private var versionsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("HoehnPhotosOrganizer", isDirectory: true)
            .appendingPathComponent(Self.versionsDirectoryName, isDirectory: true)
    }

    init() {
        loadVersionsFromDisk()
    }

    // MARK: - Actions

    func selectMedium(_ medium: ArtMedium) {
        let oldMedium = selectedMedium
        let oldParams = params
        let oldTyped = typedParams
        let newTyped = MediumParams.defaults(for: medium)
        let command = ClosureCommand(
            name: "Change Medium to \(medium.rawValue)",
            execute: { [weak self] in
                self?.selectedMedium = medium
                self?.params = medium.defaultParams
                self?.typedParams = newTyped
            },
            undo: { [weak self] in
                self?.selectedMedium = oldMedium
                self?.params = oldParams
                self?.typedParams = oldTyped
            }
        )
        commandStack.execute(command)
        render()
    }

    /// Execute a parameter change through the command stack so it is undoable.
    func setParameter(_ name: String, keyPath: WritableKeyPath<MediumParameters, Double>, value: Double) {
        let oldValue = params[keyPath: keyPath]
        guard oldValue != value else { return }
        let command = PropertyChangeCommand(
            name: "Change \(name)",
            oldValue: oldValue,
            newValue: value,
            setter: { [weak self] val in
                self?.params[keyPath: keyPath] = val
            }
        )
        commandStack.execute(command)
    }

    /// Preview a previous undo state on hover.
    func previewUndoState(at index: Int) {
        isPreviewingUndo = true
        commandStack.jumpTo(index: index)
    }

    /// Restore params after dismissing undo history hover preview.
    func restoreFromUndoPreview() {
        isPreviewingUndo = false
    }

    /// Whether an undo preview is currently being displayed.
    @Published var isPreviewingUndo: Bool = false

    /// Source image resolution info for display.
    struct ResolutionInfo {
        let width: Int
        let height: Int
        var megapixels: Double { Double(width * height) / 1_000_000.0 }
        var isLowRes: Bool { megapixels < 2.0 }
    }

    struct RenderResolutionInfo {
        let label: String
        let isPreview: Bool
        let width: Int
        let height: Int
    }

    var renderResolutionInfo: RenderResolutionInfo? {
        guard let img = renderedImage else { return nil }
        let w = Int(img.size.width)
        let h = Int(img.size.height)
        let isPreview = sourceImage.map { w < Int($0.size.width) } ?? false
        return RenderResolutionInfo(
            label: "\(w)×\(h)\(isPreview ? " Preview" : "")",
            isPreview: isPreview,
            width: w,
            height: h
        )
    }

    var sourceResolutionInfo: ResolutionInfo? {
        guard let img = sourceImage else { return nil }
        return ResolutionInfo(width: Int(img.size.width), height: Int(img.size.height))
    }

    /// Schedule a debounced preview render.
    func schedulePreview() {
        render()
    }

    /// Task for overlay generation (cancellable).
    private var overlayTask: Task<Void, Never>?
    private var cachedOverlaySourceId: ObjectIdentifier?

    /// Generation counter — incremented each time generateOverlay() is called.
    /// Background tasks check this to bail out if a newer generation has started.
    private var overlayGeneration: Int = 0

    /// Cached overlay renders keyed by display mode, invalidated when source/palette changes.
    private var cachedContourImage: NSImage?
    private var cachedNumberedImage: NSImage?
    private var cachedOverlayRegionsData: [PBNRegion] = []
    private var cachedOverlayPalette: PBNPalette?

    /// Invalidate cached overlays (call when the source image changes).
    func invalidateOverlayCache() {
        cachedOverlaySourceId = nil
        cachedContourImage = nil
        cachedNumberedImage = nil
        cachedOverlayRegionsData = []
        cachedOverlayPalette = nil
    }

    /// Trigger overlay regeneration from the contour/number toolbar toggles.
    /// Visibility is controlled by showContours/showNumbers flags in the view —
    /// this method only handles rendering, not hiding.
    func generateOverlay() {
        overlayTask?.cancel()
        overlayGeneration += 1
        let myGeneration = overlayGeneration

        guard let source = renderedImage ?? croppedImage ?? sourceImage else { return }

        let mode: PBNDisplayMode = showNumbers ? .numbered : .colorWithContour
        let sourceId = ObjectIdentifier(source)
        let palette = overlayPalette

        // Check cache — if source and palette match, use cached result instantly
        if sourceId == cachedOverlaySourceId, palette == cachedOverlayPalette {
            if mode == .numbered, let cached = cachedNumberedImage {
                overlayImage = cached
                overlayRegions = cachedOverlayRegionsData
                return
            } else if mode == .colorWithContour, let cached = cachedContourImage {
                overlayImage = cached
                overlayRegions = cachedOverlayRegionsData
                return
            }
        } else {
            // Source or palette changed — invalidate both caches
            cachedContourImage = nil
            cachedNumberedImage = nil
            cachedOverlayRegionsData = []
        }

        var config = PBNConfig(
            name: "Overlay",
            palette: palette,
            thresholds: .evenlySpaced(regions: palette.colors.count),
            contourSettings: .default,
            posterizationLevels: 0,
            blurRadius: 2
        )
        config.useKMeans = true
        config.restrictToPalette = true
        config.minFacetPixels = 20
        config.bilateralPreFilter = true
        let renderer = PaintByNumbersRenderer()

        isGeneratingOverlay = true

        // Use Task.detached so heavy PBN work doesn't run on the main actor.
        // Show the overlay image ASAP — defer region analysis to background.
        overlayTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result: NSImage
                if MetalImageProcessor.shared != nil {
                    let metalResult = try await renderer.renderMetalV2(
                        source: source, config: config, displayMode: mode, progress: { _ in }
                    )
                    result = metalResult.image
                } else {
                    result = try await renderer.render(
                        source: source, config: config, displayMode: mode, progress: { _ in }
                    )
                }

                guard !Task.isCancelled else {
                    await MainActor.run { self?.isGeneratingOverlay = false }
                    return
                }

                // Show overlay immediately — don't block on region analysis
                await MainActor.run {
                    guard self?.overlayGeneration == myGeneration else {
                        self?.isGeneratingOverlay = false
                        return
                    }
                    self?.overlayImage = result
                    self?.isGeneratingOverlay = false
                    self?.cachedOverlaySourceId = sourceId
                    self?.cachedOverlayPalette = palette
                    if mode == .numbered {
                        self?.cachedNumberedImage = result
                    } else {
                        self?.cachedContourImage = result
                    }
                }

                // Region analysis deferred — low priority, doesn't block UI
                guard !Task.isCancelled else { return }
                let regions = await renderer.analyzeRegions(source: source, config: config)
                await MainActor.run {
                    guard self?.overlayGeneration == myGeneration else { return }
                    self?.overlayRegions = regions
                    self?.cachedOverlayRegionsData = regions
                }
            } catch {
                await MainActor.run { self?.isGeneratingOverlay = false }
            }
        }
    }

    /// Update medium-specific params through the command stack.
    /// NOTE: `params` is still the legacy `MediumParameters` type.
    /// This accepts the new `MediumParams` enum for forward-compatibility
    /// with toolbar views that already use the typed params.
    func updateParams(_ newParams: MediumParams, commandName: String) {
        let oldParams = typedParams ?? mediumParams
        let command = ClosureCommand(
            name: commandName,
            execute: { [weak self] in
                self?.typedParams = newParams
                self?.selectedMedium = newParams.medium
            },
            undo: { [weak self] in
                self?.typedParams = oldParams
                self?.selectedMedium = oldParams.medium
            }
        )
        commandStack.execute(command)
        render()
    }

    // MARK: - Canvas Gallery (stubs for StudioGalleryView)

    @Published var canvases: [StudioCanvas] = []
    private(set) var canvasRepo: StudioCanvasRepository?
    @Published var activeCanvasId: String?

    func loadAllCanvases() async {
        guard let repo = canvasRepo else { return }
        do { canvases = try await repo.allCanvases() } catch { }
    }

    func resumeCanvas(_ canvas: StudioCanvas) {
        activeCanvasId = canvas.id
        if let medium = ArtMedium(rawValue: canvas.lastMedium) {
            selectedMedium = medium
            params = medium.defaultParams
        }
        currentPage = .canvas
    }

    func deleteCanvas(_ canvas: StudioCanvas) {
        Task {
            guard let repo = canvasRepo else { return }
            try? await repo.delete(id: canvas.id)
            await loadAllCanvases()
        }
    }

    func renameCanvas(id: String, newName: String) {
        Task {
            guard let repo = canvasRepo else { return }
            guard var c = try? await repo.canvas(id: id) else { return }
            c.name = newName
            try? await repo.update(c)
            await loadAllCanvases()
        }
    }

    func render() {
        guard let input = croppedImage ?? sourceImage else { return }
        isRendering = true
        renderProgress = 0
        renderStartTime = Date()

        let medium = selectedMedium
        let currentParams = params
        let currentTypedParams = mediumParams
        let photoId = sourcePhotoId
        let capturedActivityService = activityEventService

        let hasTypedParams = typedParams != nil
        let capturedRenderer = renderer

        renderTask = Task.detached(priority: .userInitiated) { [weak self] in
            let startTime = Date()
            let inputSize = input.size
            print("[StudioRender] Starting \(medium.rawValue) render: \(Int(inputSize.width))×\(Int(inputSize.height)), typedParams=\(hasTypedParams)")
            do {
                let output: NSImage
                if hasTypedParams {
                    output = try await capturedRenderer.render(
                        image: input,
                        typedParams: currentTypedParams,
                        progress: { value in
                            Task { @MainActor in self?.renderProgress = value }
                        }
                    )
                } else {
                    output = try await capturedRenderer.render(
                        image: input,
                        medium: medium,
                        params: currentParams,
                        progress: { value in
                            Task { @MainActor in self?.renderProgress = value }
                        }
                    )
                }
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self?.isRendering = false
                        self?.renderStartTime = nil
                        self?.renderTask = nil
                    }
                    return
                }

                await MainActor.run {
                    self?.renderedImage = output
                    self?.isRendering = false
                    self?.renderStartTime = nil
                    self?.renderTask = nil

                    // Auto-save version
                    if let rendered = self?.renderedImage {
                        let version = StudioVersion(
                            name: "\(medium.rawValue) — \(Date().formatted(date: .abbreviated, time: .shortened))",
                            medium: medium,
                            params: currentParams,
                            thumbnail: rendered
                        )
                        self?.versions.insert(version, at: 0)
                        self?.saveVersionToDisk(version)
                    }
                }

                // DB + activity events (async, off main thread)
                if let photoId {
                    let name = "\(medium.rawValue) — \(Date().formatted(date: .abbreviated, time: .shortened))"
                    await self?.saveRevisionToDatabase(
                        photoId: photoId, name: name,
                        medium: medium, params: currentParams
                    )
                }
                let duration = Date().timeIntervalSince(startTime)
                try? await capturedActivityService?.emitStudioRenderCompleted(
                    medium: medium.rawValue,
                    durationSeconds: duration,
                    photoAssetId: photoId
                )
            } catch is CancellationError {
                // Render was cancelled
            } catch {
                print("[StudioRender] Error: \(error.localizedDescription)")
            }

            await MainActor.run {
                if self?.isRendering == true {
                    self?.isRendering = false
                    self?.renderStartTime = nil
                    self?.renderTask = nil
                }
            }
        }
    }

    /// Full-resolution render (no downsampling).
    func renderFull() {
        guard let input = sourceImage else { return }
        isFullRendering = true
        fullRenderProgress = 0
        isPreview = false

        let medium = selectedMedium
        let currentParams = params
        let currentTypedParams = mediumParams

        renderTask = Task {
            do {
                let output: NSImage
                if typedParams != nil {
                    output = try await renderer.render(
                        image: input,
                        typedParams: currentTypedParams,
                        progress: { [weak self] value in
                            Task { @MainActor in self?.fullRenderProgress = value }
                        }
                    )
                } else {
                    output = try await renderer.render(
                        image: input,
                        medium: medium,
                        params: currentParams,
                        progress: { [weak self] value in
                            Task { @MainActor in self?.fullRenderProgress = value }
                        }
                    )
                }
                renderedImage = output
            } catch {
                print("[StudioRender] Full render error: \(error)")
            }
            isFullRendering = false
            renderTask = nil
        }
    }

    func cancelRender() {
        renderTask?.cancel()
        renderTask = nil
        isRendering = false
        renderStartTime = nil
    }

    func saveVersion(name: String) {
        let version = StudioVersion(
            name: name,
            medium: selectedMedium,
            params: params,
            thumbnail: renderedImage ?? croppedImage ?? sourceImage
        )
        versions.insert(version, at: 0)
        saveVersionToDisk(version)

        // Persist to database when tied to a library photo
        if let photoId = sourcePhotoId {
            let medium = selectedMedium
            let currentParams = params
            Task {
                await saveRevisionToDatabase(
                    photoId: photoId, name: name,
                    medium: medium, params: currentParams
                )
            }
        }

        // Emit activity event
        let capturedMedium = selectedMedium.rawValue
        let capturedService = activityEventService
        Task {
            try? await capturedService?.emitStudioVersionSaved(
                versionName: name, medium: capturedMedium
            )
        }
    }

    func restoreVersion(_ version: StudioVersion) {
        selectedMedium = version.medium
        params = version.params
        renderedImage = version.thumbnail
    }

    // MARK: - Export

    /// Present an NSSavePanel and export the rendered image as PNG or TIFF.
    func exportRenderedImage() {
        guard let image = renderedImage else { return }

        let panel = NSSavePanel()
        panel.title = "Export Rendered Image"
        panel.allowedContentTypes = [.png, .tiff]
        panel.nameFieldStringValue = "\(selectedMedium.rawValue) Export"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return }

        let data: Data?
        if url.pathExtension.lowercased() == "tiff" || url.pathExtension.lowercased() == "tif" {
            data = bitmap.representation(using: .tiff, properties: [:])
        } else {
            data = bitmap.representation(using: .png, properties: [:])
        }

        if let data {
            try? data.write(to: url, options: .atomic)

            // Emit activity event
            let format = url.pathExtension
            let path = url.path
            let capturedService = activityEventService
            Task {
                try? await capturedService?.emitStudioExported(
                    format: format, filePath: path
                )
            }
        }
    }

    // MARK: - Delete Version

    func deleteVersion(_ version: StudioVersion) {
        versions.removeAll { $0.id == version.id }
        let fm = FileManager.default
        let baseName = version.id.uuidString
        let jsonURL = versionsDirectory.appendingPathComponent("\(baseName).json")
        let jpegURL = versionsDirectory.appendingPathComponent("\(baseName).jpg")
        try? fm.removeItem(at: jsonURL)
        try? fm.removeItem(at: jpegURL)
    }

    // MARK: - Rename Version

    func renameVersion(id: UUID, newName: String) {
        guard let idx = versions.firstIndex(where: { $0.id == id }) else { return }
        versions[idx].name = newName
        // Re-save to disk
        saveVersionToDisk(versions[idx])
    }

    // MARK: - Batch Export

    func batchExport(versionIDs: Set<UUID>) {
        let toExport = versions.filter { versionIDs.contains($0.id) }
        guard !toExport.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to export \(toExport.count) version(s)"
        panel.prompt = "Export Here"

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        for version in toExport {
            guard let image = version.thumbnail else { continue }
            let sanitizedName = version.name
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let fileURL = folderURL.appendingPathComponent("\(sanitizedName).jpg")

            if let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) {
                try? jpegData.write(to: fileURL)
            }
        }
    }

    // MARK: - Version Persistence Helpers

    private func ensureVersionsDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: versionsDirectory.path) {
            try? fm.createDirectory(at: versionsDirectory, withIntermediateDirectories: true)
        }
    }

    private func saveVersionToDisk(_ version: StudioVersion) {
        ensureVersionsDirectory()
        let dir = versionsDirectory
        let versionId = version.id.uuidString
        let thumbnail = version.thumbnail

        // Capture TIFF data on main thread (needs NSImage), then do the rest off-thread
        let tiffData = thumbnail?.tiffRepresentation

        // Encode JSON on main thread (fast, small data)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try? encoder.encode(version)

        // All I/O and JPEG encoding off the main thread
        DispatchQueue.global(qos: .utility).async {
            if let jsonData {
                let jsonURL = dir.appendingPathComponent("\(versionId).json")
                try? jsonData.write(to: jsonURL, options: .atomic)
            }
            if let tiffData,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                let thumbURL = dir.appendingPathComponent("\(versionId).jpg")
                try? jpegData.write(to: thumbURL, options: .atomic)
            }
        }
    }

    private func loadVersionsFromDisk() {
        let fm = FileManager.default
        let dir = versionsDirectory
        guard fm.fileExists(atPath: dir.path) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let jsonFiles = files.filter { $0.pathExtension == "json" }

        var loaded: [StudioVersion] = []
        for jsonURL in jsonFiles {
            guard let data = try? Data(contentsOf: jsonURL),
                  var version = try? decoder.decode(StudioVersion.self, from: data) else { continue }

            // Load thumbnail from companion JPEG file
            if let thumbFilename = version.thumbnailFilename {
                let thumbURL = dir.appendingPathComponent(thumbFilename)
                if fm.fileExists(atPath: thumbURL.path) {
                    version.thumbnail = NSImage(contentsOf: thumbURL)
                }
            }
            loaded.append(version)
        }

        // Sort newest first
        versions = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Database Persistence

    private func saveRevisionToDatabase(
        photoId: String,
        name: String,
        medium: ArtMedium,
        params: MediumParameters,
        thumbnailPath: String? = nil,
        fullResPath: String? = nil
    ) async {
        guard let repo = revisionRepo else { return }
        let revision = StudioRevision(
            id: UUID().uuidString,
            photoId: photoId,
            name: name,
            medium: medium.rawValue,
            brushSize: params.brushSize,
            detail: params.detail,
            texture: params.texture,
            colorSaturation: params.colorSaturation,
            contrast: params.contrast,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            thumbnailPath: thumbnailPath,
            fullResPath: fullResPath
        )
        do {
            try await repo.insertRevision(revision)
            await loadRevisions(for: photoId)
            NotificationCenter.default.post(name: .cloudSyncStudioRendered, object: nil, userInfo: ["revisionId": revision.id])
        } catch {
            print("[StudioViewModel] Failed to save revision: \(error)")
        }
    }

    private func loadRevisions(for photoId: String) async {
        guard let repo = revisionRepo else { return }
        do {
            dbRevisions = try await repo.revisionsForPhoto(id: photoId)
        } catch {
            print("[StudioViewModel] Failed to load revisions: \(error)")
        }
    }

    /// Delete a database-persisted revision.
    func deleteDBRevision(_ revision: StudioRevision) {
        Task {
            guard let repo = revisionRepo else { return }
            do {
                try await repo.deleteRevision(id: revision.id)
                if let photoId = sourcePhotoId {
                    await loadRevisions(for: photoId)
                }
            } catch {
                print("[StudioViewModel] Failed to delete revision: \(error)")
            }
        }
    }
}

// MARK: - StudioChatMessage

struct StudioChatMessage: Identifiable {
    let id: UUID
    let role: Role
    let text: String
    let timestamp: Date

    enum Role: String { case user, assistant }

    init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}
