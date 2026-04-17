import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - PaintByNumbersViewModel

@MainActor
class PaintByNumbersViewModel: ObservableObject {
    @Published var config: PBNConfig = .default
    @Published var displayMode: PBNDisplayMode = .colorFill
    @Published var regions: [PBNRegion] = []
    @Published var highlightedRegionIndex: Int? = nil
    @Published var selectedRegionIndices: Set<Int> = []
    @Published var renderedImage: NSImage? = nil
    @Published var isRendering: Bool = false
    @Published var renderProgress: Double = 0
    @Published var showExportOptions: Bool = false
    @Published var activePreset: PBNPreset? = nil
    @Published var minShapeSize: Int = 50
    @Published var smoothKernel: Int = 3
    @Published var shapeAnalysis: [Int: [PBNShape]] = [:]  // region -> shapes
    @Published var totalShapeCount: Int = 0
    @Published var numberAssignment: PBNNumberAssignment?

    // Region index map — CPU-side copy for hover detection
    @Published var regionIndexMap: [UInt8] = []
    @Published var regionMapWidth: Int = 0
    @Published var regionMapHeight: Int = 0

    // Preview-first workflow
    @Published var isPreviewQuality: Bool = true
    @Published var isRenderingFullQuality: Bool = false

    private let renderer = PaintByNumbersRenderer()
    private let shapeAnalyzer = PBNShapeAnalyzer()
    private var renderTask: Task<Void, Never>?
    private var debounceCancellable: AnyCancellable?
    private let debounceSubject = PassthroughSubject<Void, Never>()

    /// Cached downscaled source for fast preview (1/4 resolution)
    private var previewSource: NSImage?
    /// Scale factor used for preview — lower = faster interactive drag response.
    /// Full-quality render happens on mouse-up via renderFullQuality().
    private let previewScale: CGFloat = 0.35

    var sourceImage: NSImage? {
        didSet {
            // Pre-compute downscaled preview source
            if let source = sourceImage {
                previewSource = downsample(source, scale: previewScale)
            } else {
                previewSource = nil
            }
            scheduleRender()
        }
    }

    init() {
        // Preview render: 150ms debounce → renders at preview size (0.35x)
        // Also auto-refreshes region coverage after each render.
        debounceCancellable = debounceSubject
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.render()
                self?.analyzeRegions()
            }
    }

    // MARK: - Render (uses preview-size source for speed)

    func render() {
        guard let source = previewSource ?? sourceImage else { return }
        cancelRender()

        isRendering = true
        renderProgress = 0

        let currentConfig = config
        let currentMode = displayMode
        let currentHighlight = highlightedRegionIndex
        let currentSelection = selectedRegionIndices

        let renderer = self.renderer
        renderTask = Task.detached(priority: .userInitiated) {
            do {
                let progressCb: (Double) -> Void = { value in
                    Task { @MainActor in self.renderProgress = value }
                }

                // Try Metal first, fall back to CPU
                let output: NSImage
                var assignment: PBNNumberAssignment?
                let metalAvailable = MetalImageProcessor.shared != nil
                if metalAvailable {
                    if currentConfig.useKMeans {
                        let result = try await renderer.renderMetalV2(
                            source: source,
                            config: currentConfig,
                            displayMode: currentMode,
                            highlightedRegion: currentHighlight,
                            selectedRegions: currentSelection,
                            progress: progressCb
                        )
                        output = result.image
                        assignment = result.numberAssignment
                    } else {
                        let result = try await renderer.renderMetal(
                            source: source,
                            config: currentConfig,
                            displayMode: currentMode,
                            highlightedRegion: currentHighlight,
                            selectedRegions: currentSelection,
                            progress: progressCb
                        )
                        output = result.image
                    }
                } else {
                    output = try await renderer.render(
                        source: source,
                        config: currentConfig,
                        displayMode: currentMode,
                        highlightedRegion: currentHighlight,
                        selectedRegions: currentSelection,
                        progress: progressCb
                    )
                }

                guard !Task.isCancelled else {
                    await MainActor.run { self.isRendering = false; self.renderTask = nil }
                    return
                }

                // Build region index map for hover detection
                let indexMap = renderer.buildRegionIndexMap(
                    source: source,
                    config: currentConfig
                )

                await MainActor.run {
                    self.renderedImage = output
                    self.isPreviewQuality = true
                    self.regionIndexMap = indexMap.map
                    self.regionMapWidth = indexMap.width
                    self.regionMapHeight = indexMap.height
                    if let assignment = assignment {
                        self.numberAssignment = assignment
                    }
                }
            } catch is CancellationError {
                // Render was cancelled
            } catch {
                print("[PBNRender] Error: \(error.localizedDescription)")
            }

            await MainActor.run {
                self.isRendering = false
                self.renderTask = nil
            }
        }
    }

    func cancelRender() {
        renderTask?.cancel()
        renderTask = nil
        isRendering = false
    }

    // MARK: - Full Quality Render

    func renderFullQuality() {
        guard let source = sourceImage else { return }
        cancelRender()

        isRenderingFullQuality = true
        renderProgress = 0

        let currentConfig = config
        let currentMode = displayMode
        let currentHighlight = highlightedRegionIndex
        let currentSelection = selectedRegionIndices

        let renderer = self.renderer
        renderTask = Task.detached(priority: .userInitiated) {
            do {
                let progressCb: (Double) -> Void = { value in
                    Task { @MainActor in self.renderProgress = value }
                }

                let output: NSImage
                var assignment: PBNNumberAssignment?
                let metalAvailable = MetalImageProcessor.shared != nil
                if metalAvailable {
                    if currentConfig.useKMeans {
                        let result = try await renderer.renderMetalV2(
                            source: source,
                            config: currentConfig,
                            displayMode: currentMode,
                            highlightedRegion: currentHighlight,
                            selectedRegions: currentSelection,
                            progress: progressCb
                        )
                        output = result.image
                        assignment = result.numberAssignment
                    } else {
                        let result = try await renderer.renderMetal(
                            source: source,
                            config: currentConfig,
                            displayMode: currentMode,
                            highlightedRegion: currentHighlight,
                            selectedRegions: currentSelection,
                            progress: progressCb
                        )
                        output = result.image
                    }
                } else {
                    output = try await renderer.render(
                        source: source,
                        config: currentConfig,
                        displayMode: currentMode,
                        highlightedRegion: currentHighlight,
                        selectedRegions: currentSelection,
                        progress: progressCb
                    )
                }

                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isRenderingFullQuality = false
                        self.renderTask = nil
                    }
                    return
                }

                // Build full-res region index map
                let indexMap = renderer.buildRegionIndexMap(
                    source: source,
                    config: currentConfig
                )

                await MainActor.run {
                    self.renderedImage = output
                    self.isPreviewQuality = false
                    self.isRenderingFullQuality = false
                    self.regionIndexMap = indexMap.map
                    self.regionMapWidth = indexMap.width
                    self.regionMapHeight = indexMap.height
                    if let assignment = assignment {
                        self.numberAssignment = assignment
                    }
                }
            } catch is CancellationError {
                // Render was cancelled
            } catch {
                print("[PBNRender] Full quality error: \(error.localizedDescription)")
            }

            await MainActor.run {
                self.isRenderingFullQuality = false
                self.renderTask = nil
            }
        }
    }

    // MARK: - Region Analysis

    func analyzeRegions() {
        guard let source = previewSource ?? sourceImage else { return }
        let currentConfig = config
        let currentAssignment = numberAssignment
        Task {
            var analyzed = await renderer.analyzeRegions(source: source, config: currentConfig)
            if let assignment = currentAssignment {
                for i in analyzed.indices {
                    analyzed[i].recipe = assignment.recipeByColorIndex[i]
                }
            }
            regions = analyzed
        }
    }

    // MARK: - Region Highlighting

    func highlightRegion(_ index: Int?) {
        let previousHighlight = highlightedRegionIndex
        highlightedRegionIndex = index

        if index != nil {
            displayMode = .highlightRegion
        } else if displayMode == .highlightRegion {
            displayMode = .colorWithContour
        }

        // Fast path: if we already have a rendered image and region map,
        // just re-render the display step (tint+boundary+highlight) without
        // re-running k-means and facet building.
        if let metal = MetalImageProcessor.shared,
           let regionMap = renderer.currentRegionMap,
           renderedImage != nil {
            let cfg = config
            let highlight = highlightedRegionIndex
            Task { @MainActor in
                let regionCount = cfg.thresholds.regionCount
                let expandedColors = cfg.palette.expandedColors(toCount: regionCount)
                let paletteSimd = expandedColors.map {
                    SIMD4<Float>(Float($0.red), Float($0.green), Float($0.blue), 1.0)
                }
                let lineColor = SIMD4<Float>(0, 0, 0, 1)
                let lineWeight = UInt32(cfg.contourSettings.lineWeight)
                let w = regionMap.width
                let h = regionMap.height

                guard let tinted = metal.pbnTintAndBoundary(
                    regionMap: regionMap,
                    paletteColors: paletteSimd,
                    lineColor: lineColor,
                    lineWeight: lineWeight,
                    width: w, height: h
                ) else { return }

                let finalTex: MTLTexture
                if let hi = highlight {
                    guard let highlighted = metal.pbnHoverHighlight(
                        regionMap: regionMap,
                        baseImage: tinted,
                        highlightedRegion: UInt32(hi),
                        dimAlpha: 0.3
                    ) else { return }
                    finalTex = highlighted
                } else {
                    finalTex = tinted
                }

                guard let image = metal.imageFromTexture(finalTex) else { return }
                self.renderedImage = image
            }
            return
        }

        // Fallback: full re-render
        scheduleRender()
    }

    // MARK: - Instant Region Selection (fast LUT path)

    func toggleRegionSelection(_ index: Int) {
        if selectedRegionIndices.contains(index) {
            selectedRegionIndices.remove(index)
        } else {
            selectedRegionIndices.insert(index)
        }
        scheduleRender()
    }

    func clearRegionSelection() {
        selectedRegionIndices.removeAll()
        scheduleRender()
    }

    // MARK: - Threshold Management

    func updateThreshold(at index: Int, value: Int) {
        guard index >= 0, index < config.thresholds.thresholds.count else { return }

        var thresholds = config.thresholds.thresholds
        let minVal = index > 0 ? thresholds[index - 1] + 1 : 1
        let maxVal = index < thresholds.count - 1 ? thresholds[index + 1] - 1 : 254
        thresholds[index] = max(minVal, min(maxVal, value))
        config.thresholds = PBNThresholdSet(thresholds: thresholds)
        scheduleRender()
    }

    func addThreshold() {
        var thresholds = config.thresholds.thresholds
        guard thresholds.count < 12 else { return }

        // Insert a new threshold midway between last threshold and 255
        let lastVal = thresholds.last ?? 0
        let newVal = (lastVal + 255) / 2
        guard newVal > lastVal, newVal < 255 else { return }
        thresholds.append(newVal)
        config.thresholds = PBNThresholdSet(thresholds: thresholds)
        scheduleRender()
    }

    func removeThreshold(at index: Int) {
        var thresholds = config.thresholds.thresholds
        guard thresholds.count > 1, index >= 0, index < thresholds.count else { return }
        thresholds.remove(at: index)
        config.thresholds = PBNThresholdSet(thresholds: thresholds)
        scheduleRender()
    }

    // MARK: - Palette

    func selectPalette(_ palette: PBNPalette) {
        config.palette = palette
        scheduleRender()
    }

    func updateRegionColor(regionIndex: Int, color: PBNColor) {
        guard regionIndex >= 0, regionIndex < config.palette.colors.count else { return }
        config.palette.colors[regionIndex] = color
        scheduleRender()
    }

    /// Re-sort the palette colors dark-to-light by luminance.
    /// This enforces the convention that index 0 = darkest shadow,
    /// last index = lightest highlight / paper color.
    func sortPaletteDarkToLight() {
        config.palette = config.palette.sortedByLuminance()
        scheduleRender()
    }

    /// Whether the current palette is properly ordered dark-to-light.
    var isPaletteOrdered: Bool {
        config.palette.isDarkToLight
    }

    // MARK: - Presets

    func applyPreset(_ preset: PBNPreset) {
        config = preset.config
        activePreset = preset
        scheduleRender()
    }

    // MARK: - Refinement

    func cleanUpSmallShapes(minPixels: Int) {
        guard let source = previewSource ?? sourceImage else { return }
        self.minShapeSize = minPixels
        isRendering = true

        let currentConfig = config
        let analyzer = shapeAnalyzer

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let renderer = await self?.renderer else { return }

            // 1. Build grayscale + masks
            guard let cgSource = try? renderer.cgImage(from: source) else {
                await MainActor.run { self?.isRendering = false }
                return
            }
            let width = cgSource.width
            let height = cgSource.height
            guard var gray = try? renderer.grayscalePixelBuffer(from: cgSource) else {
                await MainActor.run { self?.isRendering = false }
                return
            }

            if currentConfig.posterizationLevels > 1 {
                renderer.posterize(buffer: &gray, levels: currentConfig.posterizationLevels)
            }
            if currentConfig.blurRadius > 0 {
                renderer.gaussianBlur(buffer: &gray, width: width, height: height, radius: currentConfig.blurRadius)
            }

            // 2. Build masks
            guard var masks = try? renderer.buildRegionMasks(
                grayscale: gray, thresholds: currentConfig.thresholds,
                width: width, height: height, progress: { _ in }
            ) else {
                await MainActor.run { self?.isRendering = false }
                return
            }

            // 3. Remove small shapes
            analyzer.removeSmallShapes(masks: &masks, width: width, height: height, minPixels: minPixels)

            // 4. Rebuild color fill from cleaned masks
            let colorFill = renderer.buildColorFill(masks: masks, palette: currentConfig.palette, width: width, height: height)

            await MainActor.run {
                self?.renderedImage = colorFill
                self?.isRendering = false
            }
        }
    }

    func smoothBoundaries(kernelSize: Int) {
        guard let source = previewSource ?? sourceImage else { return }
        self.smoothKernel = kernelSize
        isRendering = true

        let currentConfig = config
        let analyzer = shapeAnalyzer

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let renderer = await self?.renderer else { return }

            guard let cgSource = try? renderer.cgImage(from: source) else {
                await MainActor.run { self?.isRendering = false }
                return
            }
            let width = cgSource.width
            let height = cgSource.height
            guard var gray = try? renderer.grayscalePixelBuffer(from: cgSource) else {
                await MainActor.run { self?.isRendering = false }
                return
            }

            if currentConfig.posterizationLevels > 1 {
                renderer.posterize(buffer: &gray, levels: currentConfig.posterizationLevels)
            }
            if currentConfig.blurRadius > 0 {
                renderer.gaussianBlur(buffer: &gray, width: width, height: height, radius: currentConfig.blurRadius)
            }

            // Build masks
            guard var masks = try? renderer.buildRegionMasks(
                grayscale: gray, thresholds: currentConfig.thresholds,
                width: width, height: height, progress: { _ in }
            ) else {
                await MainActor.run { self?.isRendering = false }
                return
            }

            // Smooth boundaries
            let ksize = max(3, kernelSize | 1) // ensure odd
            analyzer.smoothBoundaries(masks: &masks, width: width, height: height, kernelSize: ksize)

            // Rebuild from smoothed masks
            let colorFill = renderer.buildColorFill(masks: masks, palette: currentConfig.palette, width: width, height: height)

            await MainActor.run {
                self?.renderedImage = colorFill
                self?.isRendering = false
            }
        }
    }

    /// Count shapes per region using the shape analyzer.
    /// Renders each region mask image, converts to binary pixel data, then runs
    /// connected-component analysis.
    func analyzeShapes() {
        guard let source = sourceImage else { return }
        let currentConfig = config
        let regionCount = currentConfig.thresholds.regionCount

        Task {
            var masks: [[UInt8]] = []
            var maskWidth = 0
            var maskHeight = 0

            for i in 0..<regionCount {
                let maskImage = await renderer.renderRegionMask(
                    source: source, config: currentConfig, regionIndex: i
                )
                guard let tiff = maskImage.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff) else { continue }

                let w = bitmap.pixelsWide
                let h = bitmap.pixelsHigh
                if maskWidth == 0 { maskWidth = w; maskHeight = h }

                // Extract grayscale mask: treat any non-black pixel as "in region"
                var mask = [UInt8](repeating: 0, count: w * h)
                for y in 0..<h {
                    for x in 0..<w {
                        let color = bitmap.colorAt(x: x, y: y)
                        let brightness = (color?.redComponent ?? 0) + (color?.greenComponent ?? 0) + (color?.blueComponent ?? 0)
                        mask[y * w + x] = brightness > 0.1 ? 255 : 0
                    }
                }
                masks.append(mask)
            }

            guard !masks.isEmpty, maskWidth > 0, maskHeight > 0 else { return }

            let analysis = shapeAnalyzer.analyzeShapes(
                masks: masks, width: maskWidth, height: maskHeight
            )
            shapeAnalysis = analysis
            totalShapeCount = analysis.values.reduce(0) { $0 + $1.count }
        }
    }

    /// Shape count for a specific region index.
    func shapeCount(for regionIndex: Int) -> Int {
        shapeAnalysis[regionIndex]?.count ?? 0
    }

    @Sendable
    private nonisolated func _noop() {}

    // MARK: - Template Export

    func exportTemplate() {
        guard let source = sourceImage else { return }

        let panel = NSSavePanel()
        panel.title = "Export Print Template"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "PBN-Template"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let currentConfig = config

        Task {
            // Render the numbered contour view as the template
            guard let templateImage = try? await renderer.render(
                source: source,
                config: currentConfig,
                displayMode: .numbered,
                highlightedRegion: nil,
                progress: { _ in }
            ) else { return }

            // Convert to PDF via NSImage drawing into a PDF graphics context
            guard let tiff = templateImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) else { return }

            let imageSize = NSSize(
                width: bitmap.pixelsWide,
                height: bitmap.pixelsHigh
            )

            let pdfData = NSMutableData()
            guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else { return }

            var mediaBox = CGRect(origin: .zero, size: imageSize)
            guard let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }

            pdfContext.beginPDFPage(nil)

            if let cgImage = bitmap.cgImage {
                pdfContext.draw(cgImage, in: mediaBox)
            }

            // Draw palette legend at the bottom
            let swatchSize: CGFloat = 20
            let spacing: CGFloat = 6
            let startX: CGFloat = 20
            let startY: CGFloat = 10

            for (index, color) in currentConfig.palette.colors.enumerated() {
                let x = startX + CGFloat(index) * (swatchSize + spacing + 30)
                guard x + swatchSize < imageSize.width - 20 else { break }

                // Color swatch
                pdfContext.setFillColor(CGColor(
                    red: color.red, green: color.green, blue: color.blue, alpha: 1
                ))
                pdfContext.fill(CGRect(x: x, y: startY, width: swatchSize, height: swatchSize))

                // Region number
                pdfContext.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                let numStr = "\(index + 1)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: NSColor.black
                ]
                numStr.draw(
                    at: NSPoint(x: x + swatchSize + 3, y: startY + 4),
                    withAttributes: attrs
                )
            }

            pdfContext.endPDFPage()
            pdfContext.closePDF()

            try? pdfData.write(to: url, options: .atomic)
        }
    }

    // MARK: - Export

    func exportImage(format: PBNExportFormat) {
        guard let source = sourceImage else { return }

        let panel = NSSavePanel()
        panel.title = "Export Paint by Numbers"
        panel.canCreateDirectories = true

        switch format {
        case .colorFillPNG, .contoursPNG, .numberedPNG, .regionMaskPNG:
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "PBN-\(format.rawValue)"
        case .paletteSwatch:
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "PBN-Palette"
        case .fullKit:
            panel.allowedContentTypes = [.folder]
            panel.nameFieldStringValue = "PBN-Kit"
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let currentConfig = config
        let currentHighlight = highlightedRegionIndex

        Task {
            switch format {
            case .colorFillPNG:
                if let image = try? await renderer.render(
                    source: source, config: currentConfig,
                    displayMode: .colorFill, highlightedRegion: nil,
                    progress: { _ in }
                ) {
                    saveImageAsPNG(image, to: url)
                }

            case .contoursPNG:
                if let image = try? await renderer.render(
                    source: source, config: currentConfig,
                    displayMode: .contourOnly, highlightedRegion: nil,
                    progress: { _ in }
                ) {
                    saveImageAsPNG(image, to: url)
                }

            case .numberedPNG:
                if let image = try? await renderer.render(
                    source: source, config: currentConfig,
                    displayMode: .numbered, highlightedRegion: nil,
                    progress: { _ in }
                ) {
                    saveImageAsPNG(image, to: url)
                }

            case .regionMaskPNG:
                if let idx = currentHighlight {
                    let mask = await renderer.renderRegionMask(
                        source: source, config: currentConfig, regionIndex: idx
                    )
                    saveImageAsPNG(mask, to: url)
                }

            case .paletteSwatch:
                let swatch = renderer.renderPaletteSwatch(
                    palette: currentConfig.palette, size: NSSize(width: 800, height: 200)
                )
                saveImageAsPNG(swatch, to: url)

            case .fullKit:
                let fm = FileManager.default
                try? fm.createDirectory(at: url, withIntermediateDirectories: true)

                // Color fill
                if let img = try? await renderer.render(
                    source: source, config: currentConfig,
                    displayMode: .colorFill, highlightedRegion: nil,
                    progress: { _ in }
                ) {
                    saveImageAsPNG(img, to: url.appendingPathComponent("color-fill.png"))
                }

                // Contours
                if let img = try? await renderer.render(
                    source: source, config: currentConfig,
                    displayMode: .contourOnly, highlightedRegion: nil,
                    progress: { _ in }
                ) {
                    saveImageAsPNG(img, to: url.appendingPathComponent("contours.png"))
                }

                // Numbered
                if let img = try? await renderer.render(
                    source: source, config: currentConfig,
                    displayMode: .numbered, highlightedRegion: nil,
                    progress: { _ in }
                ) {
                    saveImageAsPNG(img, to: url.appendingPathComponent("numbered.png"))
                }

                // Palette swatch
                let swatch = renderer.renderPaletteSwatch(
                    palette: currentConfig.palette, size: NSSize(width: 800, height: 200)
                )
                saveImageAsPNG(swatch, to: url.appendingPathComponent("palette-swatch.png"))

                // Individual region masks
                for i in 0..<currentConfig.thresholds.regionCount {
                    let mask = await renderer.renderRegionMask(
                        source: source, config: currentConfig, regionIndex: i
                    )
                    saveImageAsPNG(mask, to: url.appendingPathComponent("region-\(i + 1).png"))
                }
            }
        }
    }

    // MARK: - Reset

    func resetToDefaults() {
        config = .default
        displayMode = .colorFill
        highlightedRegionIndex = nil
        regions = []
        renderedImage = nil
        activePreset = nil
        minShapeSize = 50
        smoothKernel = 3
        shapeAnalysis = [:]
        totalShapeCount = 0
        regionIndexMap = []
        regionMapWidth = 0
        regionMapHeight = 0
        isPreviewQuality = true
        isRenderingFullQuality = false
    }

    // MARK: - Private

    private func scheduleRender() {
        debounceSubject.send()
    }

    /// Downsample an image by a scale factor (0.25 = quarter size)
    private func downsample(_ image: NSImage, scale: CGFloat) -> NSImage {
        let newW = max(1, Int(image.size.width * scale))
        let newH = max(1, Int(image.size.height * scale))
        let newSize = NSSize(width: newW, height: newH)
        let resized = NSImage(size: newSize)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        resized.unlockFocus()
        return resized
    }

    private func saveImageAsPNG(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return }
        try? pngData.write(to: url, options: .atomic)
    }
}

// MARK: - PaintByNumbersView

struct PaintByNumbersView: View {

    @ObservedObject var viewModel: PaintByNumbersViewModel
    var sourceMedium: ArtMedium = .oil

    @State private var showAdvanced = false
    @State private var showDisplayMode = false
    @State private var showPresets = false
    @State private var showConfig = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Palette always visible (most used)
                paletteSection

                Divider()

                // Display Mode — collapsed by default
                DisclosureGroup("Display Mode", isExpanded: $showDisplayMode) {
                    displayModeSection.padding(.top, 4)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                if let preset = viewModel.activePreset {
                    presetIndicator(preset)
                }

                Divider()

                // Presets — collapsed by default
                DisclosureGroup("Presets", isExpanded: $showPresets) {
                    presetsSection.padding(.top, 4)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

                Divider()

                // Configuration (bilateral, color space, prune, etc.) — collapsed
                DisclosureGroup("Configuration", isExpanded: $showConfig) {
                    VStack(alignment: .leading, spacing: 12) {
                        pipelineSection
                        Divider()
                        processingSection
                        Divider()
                        contoursSection
                    }
                    .padding(.top, 4)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

                Divider()

                actionsSection

                // Advanced (thresholds, refinement, regions)
                Divider()
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        thresholdsSection
                        Divider()
                        refinementSection
                        Divider()
                        regionsSection
                    }
                    .padding(.top, 4)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Pipeline

    private var pipelineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PIPELINE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            Picker("", selection: $viewModel.config.useKMeans) {
                Text("Simple").tag(false)
                Text("Color K-Means").tag(true)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            if viewModel.config.useKMeans {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Min region size")
                            .font(.system(size: 10))
                        Spacer()
                        Text("\(viewModel.config.minFacetPixels) px")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(viewModel.config.minFacetPixels) },
                            set: { viewModel.config.minFacetPixels = Int($0) }
                        ),
                        in: 5...200,
                        step: 5
                    )
                    .controlSize(.small)

                    Toggle("Snap to palette colors", isOn: $viewModel.config.restrictToPalette)
                        .font(.system(size: 10))
                        .toggleStyle(.checkbox)

                    Toggle("Pre-filter noise", isOn: $viewModel.config.bilateralPreFilter)
                        .font(.system(size: 10))
                        .toggleStyle(.checkbox)
                }
            }
        }
    }

    // MARK: - Display Mode

    private var displayModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DISPLAY MODE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                ForEach(PBNDisplayMode.allCases, id: \.rawValue) { mode in
                    Button {
                        viewModel.displayMode = mode
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: mode.icon)
                                .font(.system(size: 13))
                                .frame(height: 18)
                            Text(mode.rawValue)
                                .font(.system(size: 8))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(viewModel.displayMode == mode
                                      ? Color.accentColor.opacity(0.15)
                                      : Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(viewModel.displayMode == mode
                                              ? Color.accentColor.opacity(0.4)
                                              : Color.secondary.opacity(0.15), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(viewModel.displayMode == mode ? Color.accentColor : .secondary)
                }
            }
        }
    }

    // MARK: - Preset Indicator

    private func presetIndicator(_ preset: PBNPreset) -> some View {
        HStack(spacing: 6) {
            Image(systemName: preset.icon)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(preset.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                viewModel.activePreset = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 0.5)
        )
    }

    // MARK: - Presets

    /// PBN preset categories relevant to each art medium.
    private var drawingMediums: Set<ArtMedium> {
        [.troisCrayon, .charcoal, .graphite, .penAndInk]
    }

    private var printmakingMediums: Set<ArtMedium> {
        [.penAndInk, .inkWash]
    }

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PRESETS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            if drawingMediums.contains(sourceMedium) {
                presetCategoryGroup("Drawing", presets: [
                    PBNPreset.troisCrayonClassic,
                    PBNPreset.troisCrayonDetailed,
                    PBNPreset.charcoalStudy,
                    PBNPreset.sanguineSketch,
                    PBNPreset.sepiaPortrait,
                ])
            }

            if printmakingMediums.contains(sourceMedium) {
                presetCategoryGroup("Printmaking", presets: [
                    PBNPreset.aquatintEtch,
                    PBNPreset.woodcutBold,
                ])
            }

            presetCategoryGroup("Paint-by-Numbers", presets: [
                PBNPreset.classicPBN,
                PBNPreset.kidsPBN,
                PBNPreset.advancedPBN,
            ])

            presetCategoryGroup("Tonal", presets: [
                PBNPreset.highKey,
                PBNPreset.lowKey,
                PBNPreset.fullRange,
            ])
        }
    }

    private func presetCategoryGroup(_ title: String, presets: [PBNPreset]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(presets, id: \.id) { preset in
                        presetCard(preset)
                    }
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 1)
            }
        }
    }

    private func presetCard(_ preset: PBNPreset) -> some View {
        let isActive = viewModel.activePreset?.id == preset.id

        return Button {
            viewModel.applyPreset(preset)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: preset.icon)
                    .font(.system(size: 12))
                    .frame(height: 16)
                Text(preset.name)
                    .font(.system(size: 8))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 64)
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive
                          ? Color.accentColor.opacity(0.15)
                          : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isActive
                                  ? Color.accentColor.opacity(0.4)
                                  : Color.secondary.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.accentColor : .secondary)
        .help(preset.description)
    }

    // MARK: - Palette

    private var paletteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PALETTE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            // Palette picker
            Picker("Palette", selection: Binding(
                get: { viewModel.config.palette.name },
                set: { newName in
                    if let palette = PBNPalette.builtIn.first(where: { $0.name == newName }) {
                        viewModel.selectPalette(palette)
                    }
                }
            )) {
                ForEach(PBNPalette.builtIn, id: \.name) { palette in
                    HStack(spacing: 4) {
                        ForEach(palette.colors.prefix(5), id: \.id) { color in
                            Circle()
                                .fill(color.color)
                                .frame(width: 8, height: 8)
                        }
                        Text(palette.name)
                    }
                    .tag(palette.name)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .labelsHidden()

            // Color swatch strip
            HStack(spacing: 3) {
                ForEach(Array(viewModel.config.palette.colors.enumerated()), id: \.element.id) { index, pbnColor in
                    ColorPicker(
                        "",
                        selection: Binding(
                            get: { pbnColor.color },
                            set: { newColor in
                                let resolved = NSColor(newColor)
                                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                                resolved.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
                                let updated = PBNColor(
                                    id: pbnColor.id,
                                    red: Double(r),
                                    green: Double(g),
                                    blue: Double(b),
                                    name: pbnColor.name
                                )
                                viewModel.updateRegionColor(regionIndex: index, color: updated)
                            }
                        ),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                    .frame(width: 20, height: 20)
                }
                Spacer()
            }

        }
    }

    // MARK: - Thresholds

    private var thresholdsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("REGIONS (\(viewModel.config.thresholds.regionCount))")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    viewModel.addThreshold()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(viewModel.config.thresholds.thresholds.count >= 12)
            }

            Text("Each threshold divides the grayscale range into one more region. Add/remove thresholds to control region count.")
                .font(.system(size: 8))
                .foregroundStyle(.quaternary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(viewModel.config.thresholds.thresholds.enumerated()), id: \.offset) { index, threshold in
                HStack(spacing: 6) {
                    Text("T\(index + 1)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .trailing)

                    // Colored track indicator
                    if index < viewModel.config.palette.colors.count {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(viewModel.config.palette.colors[index].color)
                            .frame(width: 8, height: 8)
                    }

                    Slider(
                        value: Binding(
                            get: { Double(threshold) },
                            set: { viewModel.updateThreshold(at: index, value: Int($0)) }
                        ),
                        in: 1...254
                    )
                    .controlSize(.small)

                    Text("\(threshold)")
                        .font(.system(size: 9, design: .monospaced))
                        .frame(width: 28)
                        .foregroundStyle(.secondary)

                    Button {
                        viewModel.removeThreshold(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(viewModel.config.thresholds.thresholds.count <= 1)
                }
            }
        }
    }

    // MARK: - Processing

    private var processingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PROCESSING")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("Pre-processing applied to the source before region thresholding.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                paramSlider(
                    "Tonal bands",
                    value: Binding(
                        get: { Double(viewModel.config.posterizationLevels) },
                        set: { viewModel.config.posterizationLevels = Int($0) }
                    ),
                    range: 0...20,
                    format: "%.0f"
                )
                Text("Quantizes grayscale into discrete bands before thresholding. 0 = smooth input. Does not change region count.")
                    .font(.system(size: 8))
                    .foregroundStyle(.quaternary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            paramSlider(
                "Pre-blur",
                value: $viewModel.config.blurRadius,
                range: 0...10,
                format: "%.1f"
            )
        }
    }

    // MARK: - Refinement

    private var refinementSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("REFINEMENT")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            // Remove small shapes
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Remove small shapes")
                        .font(.system(size: 10))
                    Spacer()
                    Text("\(viewModel.minShapeSize) px")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: Binding(
                        get: { Double(viewModel.minShapeSize) },
                        set: { viewModel.minShapeSize = Int($0) }
                    ),
                    in: 0...500,
                    step: 10
                )
                .controlSize(.small)

                Button {
                    viewModel.cleanUpSmallShapes(minPixels: viewModel.minShapeSize)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                        Text("Clean Up")
                    }
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.sourceImage == nil)
            }

            Divider()
                .padding(.vertical, 2)

            // Smooth boundaries
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Smooth boundaries")
                        .font(.system(size: 10))
                    Spacer()
                    Text("\(viewModel.smoothKernel)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: Binding(
                        get: { Double(viewModel.smoothKernel) },
                        set: { viewModel.smoothKernel = max(0, min(7, Int($0))) }
                    ),
                    in: 0...7,
                    step: 1
                )
                .controlSize(.small)

                Button {
                    viewModel.smoothBoundaries(kernelSize: viewModel.smoothKernel)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "circle.dotted")
                        Text("Smooth")
                    }
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.sourceImage == nil)
            }

            // Shape stats summary
            if viewModel.totalShapeCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "puzzlepiece")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text("\(viewModel.totalShapeCount) total shapes")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Contours

    private var contoursSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CONTOURS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            Toggle(isOn: $viewModel.config.contourSettings.showContours) {
                Text("Show contour lines")
                    .font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            if viewModel.config.contourSettings.showContours {
                paramSlider(
                    "Line weight",
                    value: $viewModel.config.contourSettings.lineWeight,
                    range: 1...5,
                    format: "%.1f"
                )

                paramSlider(
                    "Smoothing",
                    value: $viewModel.config.contourSettings.smoothing,
                    range: 0...1,
                    format: "%.2f"
                )
            }

            Toggle(isOn: $viewModel.config.contourSettings.showNumbers) {
                Text("Show numbers")
                    .font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            if viewModel.config.contourSettings.showNumbers {
                paramSlider(
                    "Font size",
                    value: $viewModel.config.contourSettings.numberFontSize,
                    range: 8...24,
                    format: "%.0f"
                )
            }
        }
    }

    // MARK: - Regions

    private var regionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("REGIONS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !viewModel.regions.isEmpty {
                    Text("\(viewModel.regions.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            if viewModel.regions.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "square.grid.3x3.topleft.filled")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                        Text("Render to see regions")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 12)
                    Spacer()
                }
            } else {
                ForEach(viewModel.regions, id: \.id) { region in
                    regionRow(region)
                }
            }
        }
    }

    private func regionRow(_ region: PBNRegion) -> some View {
        let isHighlighted = viewModel.highlightedRegionIndex == region.id

        return HStack(spacing: 8) {
            // Color swatch
            RoundedRectangle(cornerRadius: 3)
                .fill(region.color.color)
                .frame(width: 16, height: 16)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5)
                )

            // Label
            VStack(alignment: .leading, spacing: 2) {
                Text(region.label)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)

                // Coverage bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.1))
                            .frame(height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(region.color.color.opacity(0.7))
                            .frame(width: max(0, geo.size.width * region.coveragePercent / 100), height: 4)
                    }
                }
                .frame(height: 4)
            }

            Spacer()

            // Coverage percentage
            Text(String(format: "%.1f%%", region.coveragePercent))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)

            // Shape count
            let shapes = viewModel.shapeCount(for: region.id)
            if shapes > 0 {
                Text("[\(shapes) shapes]")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHighlighted ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isHighlighted ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isHighlighted {
                viewModel.highlightRegion(nil)
            } else {
                viewModel.highlightRegion(region.id)
            }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(spacing: 8) {
            // Render / progress
            if viewModel.isRendering {
                VStack(spacing: 6) {
                    ProgressView(value: viewModel.renderProgress)
                        .tint(.accentColor)
                    Text("Rendering...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button(role: .destructive) {
                        viewModel.cancelRender()
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.red)
                }
            } else {
                HStack(spacing: 8) {
                    Button {
                        viewModel.render()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "paintpalette.fill")
                            Text("Render")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.sourceImage == nil)

                    // Export menu
                    Menu {
                        ForEach(PBNExportFormat.allCases, id: \.rawValue) { format in
                            Button {
                                viewModel.exportImage(format: format)
                            } label: {
                                Text(exportLabel(for: format))
                            }
                            .disabled(format == .regionMaskPNG && viewModel.highlightedRegionIndex == nil)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up")
                            Text("Export")
                        }
                        .font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 80)
                    .disabled(viewModel.renderedImage == nil)
                }
            }

            // Print Template
            Button {
                viewModel.exportTemplate()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.richtext")
                    Text("Print Template")
                }
                .font(.system(size: 11))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.renderedImage == nil)

            // Reset
            Button {
                viewModel.resetToDefaults()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Reset to Defaults")
                }
                .font(.system(size: 11))
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Helpers

    private func paramSlider(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String = "%.1f"
    ) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .frame(width: 65, alignment: .trailing)
            Slider(value: value, in: range)
                .controlSize(.small)
            Text(String(format: format, value.wrappedValue))
                .font(.system(size: 9, design: .monospaced))
                .frame(width: 28)
                .foregroundStyle(.secondary)
        }
    }

    private func exportLabel(for format: PBNExportFormat) -> String {
        switch format {
        case .colorFillPNG:    return "Color Fill (PNG)"
        case .contoursPNG:     return "Contours (PNG)"
        case .numberedPNG:     return "Numbered (PNG)"
        case .regionMaskPNG:   return "Region Mask (PNG)"
        case .paletteSwatch:   return "Palette Swatch"
        case .fullKit:         return "Full Kit (All Files)"
        }
    }
}
