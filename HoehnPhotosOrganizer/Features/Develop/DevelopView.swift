import CoreImage
import GRDB
import SwiftUI
import UniformTypeIdentifiers

// MARK: - DevelopView

struct DevelopView: View {

    @ObservedObject var viewModel: LibraryViewModel
    @Binding var isPresented: Bool
    @Environment(\.appDatabase) private var appDatabase: AppDatabase?
    @Environment(\.activityEventService) private var activityEventService: ActivityEventService?

    // Tool selection
    enum Tool: String, CaseIterable {
        case adjust = "Adjust"
        case masks = "Masks"
        case inpaint = "Inpaint"
        case assistant = "Assistant"
        case history = "History"

        var icon: String {
            switch self {
            case .adjust:    return "slider.horizontal.3"
            case .masks:     return "circle.dashed"
            case .inpaint:   return "paintbrush.pointed"
            case .assistant: return "sparkles"
            case .history:   return "clock.arrow.circlepath"
            }
        }

        var helpText: String {
            switch self {
            case .adjust:    return "Adjustments — Tone, color, and exposure controls (A)"
            case .masks:     return "Masks — Create layer masks for regional adjustments (M)"
            case .inpaint:   return "Inpaint — Remove objects or repair areas with AI (I)"
            case .assistant: return "Assistant — Chat with Claude for editing guidance (C)"
            case .history:   return "History — Browse and restore saved version checkpoints (H)"
            }
        }

        var keyboardShortcut: String {
            switch self {
            case .adjust:    return "A"
            case .masks:     return "M"
            case .inpaint:   return "I"
            case .assistant: return "C"
            case .history:   return "H"
            }
        }
    }

    @State private var selectedTool: Tool = .adjust

    // Layout
    @State private var showRightPanel = true
    @State private var showFilmstrip = true
    @State private var rightPanelWidth: CGFloat = 340

    // Image
    @State private var displayImage: NSImage? = nil
    @State private var zoomScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero

    // Adjustments
    @State private var exposure: Double = 0
    @State private var contrast: Int = 0
    @State private var highlights: Int = 0
    @State private var shadows: Int = 0
    @State private var whites: Int = 0
    @State private var blacks: Int = 0
    @State private var saturation: Int = 0
    @State private var vibrance: Int = 0
    @State private var temperature: Double = 0
    @State private var tint: Double = 0
    @State private var clarity: Double = 0
    @State private var dehaze: Double = 0

    // Masks
    @State private var maskLayers: [AdjustmentLayer] = []
    @State private var selectedMaskId: String? = nil
    @State private var showMaskOverlay = false
    @State private var maskInteractionMode: MaskInteractionMode = .none
    @State private var autoSegments: [AppleVisionSegment] = []
    @State private var isAutoSegmenting = false
    private static let visionMaskService = AppleVisionMaskService()

    // Preview
    @State private var previewBaseCG: CGImage? = nil
    @State private var previewImage: NSImage? = nil
    @State private var previewTrigger: Int = 0
    @State private var debounceTask: Task<Void, Never>? = nil
    @State private var showingOriginal = false
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: true])

    // Tone curve
    @State private var curvePoints: [CurvePoint] = []

    // Advanced color (color grading, HSL, calibration)
    @State private var adj = PhotoAdjustments()  // carries nested complex fields only
    @State private var advancedExpanded = false
    @State private var colorGradingExp = false
    @State private var hslExpanded = false
    @State private var calibrationExp = false
    @State private var selectedHSL: HSLChannelName = .red

    private enum HSLChannelName: String, CaseIterable, Identifiable {
        case red, orange, yellow, green, aqua, blue, purple, magenta
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    // Photo context for assistant
    @State private var cachedPhotoContext: String = ""

    // Save
    @State private var isSaving = false
    @State private var saveMessage: String? = nil

    // Load error
    @State private var loadError: String? = nil

    // In-memory undo/redo stacks (cleared on photo change)
    @State private var undoStack: [PhotoAdjustments] = []
    @State private var redoStack: [PhotoAdjustments] = []

    private var canUndo: Bool { !undoStack.isEmpty }
    private var canRedo: Bool { !redoStack.isEmpty }

    // Version history (checkpoints)
    @State private var versionSnapshots: [AdjustmentSnapshot] = []
    @State private var showSaveVersionSheet = false
    @State private var versionLabelInput = ""
    @State private var restoreConfirmSnapshot: AdjustmentSnapshot? = nil
    @State private var renameTarget: AdjustmentSnapshot? = nil
    @State private var renameLabelInput = ""

    /// Base64 JPEG of the proxy image for the chat assistant
    private var proxyImageBase64: String? {
        guard let photo = currentPhoto else { return nil }
        let baseName = (photo.canonicalName as NSString).deletingPathExtension
        let proxyURL = ProxyGenerationActor.proxiesDirectory().appendingPathComponent(baseName + ".jpg")
        guard let data = try? Data(contentsOf: proxyURL) else { return nil }
        // Downscale if too large (keep under ~200KB for fast API calls)
        if data.count > 200_000, let img = NSImage(data: data) {
            let scale = min(1.0, 512.0 / max(img.size.width, img.size.height))
            let newW = Int(img.size.width * scale), newH = Int(img.size.height * scale)
            guard let tiff = img.tiffRepresentation,
                  let bmp = NSBitmapImageRep(data: tiff) else { return data.base64EncodedString() }
            bmp.size = NSSize(width: newW, height: newH)
            if let jpeg = bmp.representation(using: .jpeg, properties: [.compressionFactor: 0.5]) {
                return jpeg.base64EncodedString()
            }
        }
        return data.base64EncodedString()
    }

    /// CGImage for the histogram — prefer the rendered preview so it reflects adjustments
    private var histogramCG: CGImage? {
        if let preview = previewImage,
           let cg = preview.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cg
        }
        return previewBaseCG
    }

    private var hasEditableSourceInSelectedLayer: Bool {
        guard let id = selectedMaskId,
              let layer = maskLayers.first(where: { $0.id == id }) else { return false }
        return layer.sources.contains { src in
            switch src.sourceType {
            case .linearGradient, .radialGradient, .ellipse, .rectangle: return true
            case .bitmap: return false
            }
        }
    }

    private var currentPhoto: PhotoAsset? { viewModel.developPhoto }
    /// The sequence used for prev/next navigation. Jobs pass staged photos via
    /// viewModel.developSequence; normal library use falls back to filteredPhotos.
    private var developPhotos: [PhotoAsset] { viewModel.developSequence ?? viewModel.filteredPhotos }
    private var currentIndex: Int? {
        guard let p = currentPhoto else { return nil }
        return developPhotos.firstIndex(where: { $0.id == p.id })
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            developToolbar
            Divider()

            HStack(spacing: 0) {
                // Center image
                imagePane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showRightPanel {
                    // Drag handle for resizing
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 5)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { NSCursor.resizeLeftRight.push() }
                            else { NSCursor.pop() }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    let newWidth = rightPanelWidth - value.translation.width
                                    rightPanelWidth = max(280, min(600, newWidth))
                                }
                        )
                    // Right panel — changes based on selected tool
                    rightPanel
                        .frame(width: rightPanelWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }

            if showFilmstrip {
                Divider()
                filmstripBar
            }
        }
        .background(Color.black)
        .focusable()
        .focusEffectDisabled()
        .task(id: currentPhoto?.id) {
            loadError = nil
            undoStack.removeAll()
            redoStack.removeAll()
            await loadImage()
            await loadAdjustmentsFromDB()
            await loadMasksFromDB()
            await loadPhotoContext()
            await loadVersionSnapshots()
        }
        .task(id: previewTrigger) { await rebuildPreview() }
        .onChange(of: adj) { nudgePreview() }
        .onKeyPress(.escape) {
            withAnimation { isPresented = false }
            return .handled
        }
        .onChange(of: isPresented) { _, newVal in
            if !newVal { viewModel.developSequence = nil }
        }
        .onKeyPress(.leftArrow) {
            navigatePhoto(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            navigatePhoto(by: 1)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "\\"), phases: .all) { press in
            let before = press.phase == .down || press.phase == .repeat
            if showingOriginal != before { showingOriginal = before }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "[")) { _ in
            if selectedTool == .inpaint {
                inpaintBrushSize = max(5, inpaintBrushSize - 5)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "]")) { _ in
            if selectedTool == .inpaint {
                inpaintBrushSize = min(150, inpaintBrushSize + 5)
                return .handled
            }
            return .ignored
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "amich")) { press in
            switch press.characters {
            case "a": withAnimation(.easeInOut(duration: 0.15)) { selectedTool = .adjust;    showRightPanel = true }
            case "m": withAnimation(.easeInOut(duration: 0.15)) { selectedTool = .masks;     showRightPanel = true }
            case "i": withAnimation(.easeInOut(duration: 0.15)) { selectedTool = .inpaint;   showRightPanel = true }
            case "c": withAnimation(.easeInOut(duration: 0.15)) { selectedTool = .assistant; showRightPanel = true }
            case "h": withAnimation(.easeInOut(duration: 0.15)) { selectedTool = .history;   showRightPanel = true }
            default:  return .ignored
            }
            return .handled
        }
    }

    // MARK: - Left Tool Rail

    private var toolRail: some View {
        VStack(spacing: 2) {
            ForEach(Tool.allCases, id: \.self) { tool in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedTool = tool
                        showRightPanel = true
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tool.icon)
                            .font(.system(size: 16))
                        Text(tool.rawValue)
                            .font(.system(size: 9, weight: .medium))
                        Text(tool.keyboardShortcut)
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color(nsColor: .controlColor).opacity(0.5))
                            .cornerRadius(2)
                    }
                    .frame(width: 56, height: 56)
                    .foregroundStyle(selectedTool == tool ? .white : .secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selectedTool == tool ? Color.accentColor.opacity(0.3) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .help(tool.helpText)
            }

            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(width: 64)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Toolbar

    private var developToolbar: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isPresented = false }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Library")
                }.font(.callout)
            }
            .buttonStyle(.borderless)

            Divider().frame(height: 20)

            Text(currentPhoto?.canonicalName ?? "")
                .font(.callout.weight(.medium)).lineLimit(1)

            if let idx = currentIndex {
                Text("\(idx + 1) / \(developPhotos.count)")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Spacer()

            // Undo / Redo buttons
            HStack(spacing: 2) {
                Button {
                    performUndo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Undo last adjustment (⌘Z)")
                .disabled(!canUndo)

                Button {
                    performRedo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .buttonStyle(.borderless)
                .help("Redo (⇧⌘Z)")
                .disabled(!canRedo)
            }

            Divider().frame(height: 20)

            // Save Version button
            Button {
                versionLabelInput = ""
                showSaveVersionSheet = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "camera.fill")
                    Text("Save Version")
                }
                .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Save a named checkpoint of the current adjustments")

            Divider().frame(height: 20)

            Button { navigatePhoto(by: -1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).disabled(currentIndex == nil || currentIndex == 0)
            Button { navigatePhoto(by: 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .disabled(currentIndex == nil || currentIndex == developPhotos.count - 1)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showSaveVersionSheet) {
            saveVersionSheet
        }
        .alert("Restore Version?", isPresented: Binding(
            get: { restoreConfirmSnapshot != nil },
            set: { if !$0 { restoreConfirmSnapshot = nil } }
        )) {
            Button("Cancel", role: .cancel) { restoreConfirmSnapshot = nil }
            Button("Restore", role: .destructive) {
                if let snap = restoreConfirmSnapshot {
                    Task { await restoreVersion(snap) }
                }
            }
        } message: {
            if let snap = restoreConfirmSnapshot {
                Text("This will overwrite your current adjustments with the checkpoint \"\(snap.label ?? "Untitled")\".")
            }
        }
    }

    // MARK: - Image Pane

    private var imagePane: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if let img = (showingOriginal ? displayImage : nil) ?? previewImage ?? displayImage {
                    let imgRect = Self.computeImageRect(imageSize: img.size, containerSize: geo.size, padding: 16)

                    Image(nsImage: showingOriginal ? (displayImage ?? img) : img)
                        .resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(16)
                        .scaleEffect(zoomScale)
                        .offset(panOffset)
                        .gesture(maskInteractionMode == .none ? magnifyGesture : nil)
                        .gesture(maskInteractionMode == .none && zoomScale > 1.0 ? panGesture : nil)
                        .onTapGesture(count: 2) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if zoomScale > 1.0 { zoomScale = 1.0; panOffset = .zero }
                                else { zoomScale = 2.0 }
                            }
                        }
                        .onTapGesture {
                            if !maskLayers.isEmpty { showMaskOverlay.toggle() }
                        }
                        .id(currentPhoto?.id)
                        .transition(.opacity.animation(.easeInOut(duration: 0.2)))

                    if showMaskOverlay || selectedMaskId != nil {
                        MaskOverlayView(maskLayers: $maskLayers, selectedMaskId: $selectedMaskId,
                                        displayedImageRect: imgRect)
                    }

                    // Inpaint mask painting overlay
                    if selectedTool == .inpaint {
                        InpaintMaskOverlay(
                            displayedImageRect: imgRect,
                            strokes: $inpaintMaskStrokes,
                            currentStroke: $inpaintCurrentStroke,
                            brushSize: $inpaintBrushSize,
                            brushSoftness: $inpaintBrushSoftness
                        )
                    }

                    // Gradient placement + handle editing overlay
                    if maskInteractionMode != .none || (selectedMaskId != nil && hasEditableSourceInSelectedLayer) {
                        GradientInteractionOverlay(
                            mode: $maskInteractionMode,
                            maskLayers: $maskLayers,
                            selectedMaskId: $selectedMaskId,
                            displayedImageRect: imgRect,
                            onSourcePlaced: { sourceType in
                                addMaskSource(sourceType)
                                showMaskOverlay = true
                            },
                            onNudgePreview: { nudgePreview() }
                        )
                    }
                } else {
                    ProgressView().scaleEffect(1.2).tint(.white.opacity(0.5))
                }

                // Before/after badge
                if showingOriginal {
                    VStack {
                        HStack {
                            Text("BEFORE")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.black.opacity(0.6), in: Capsule())
                                .padding(.leading, 12).padding(.top, 12)
                            Spacer()
                        }
                        Spacer()
                    }
                }

                // Floating overlay buttons (top-right)
                VStack { HStack { Spacer()
                    HStack(spacing: 2) {
                        overlayButton(icon: showMaskOverlay ? "circle.dashed.inset.filled" : "circle.dashed",
                                      help: "Toggle mask overlay", disabled: maskLayers.isEmpty) {
                            showMaskOverlay.toggle()
                        }
                        overlayButton(icon: "arrow.left.arrow.right", help: "Hold \\ for before/after") {
                            showingOriginal.toggle()
                        }
                        overlayButton(icon: "rectangle.split.1x2", help: "Toggle filmstrip") {
                            withAnimation(.easeInOut(duration: 0.15)) { showFilmstrip.toggle() }
                        }
                        overlayButton(icon: "sidebar.right", help: "Toggle panel") {
                            withAnimation(.easeInOut(duration: 0.15)) { showRightPanel.toggle() }
                        }
                    }
                    .padding(4)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(12)
                }; Spacer() }

                // Zoom indicator
                if zoomScale > 1.0 {
                    VStack { Spacer(); HStack { Spacer()
                        Text("\(Int(zoomScale * 100))%")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.black.opacity(0.6), in: Capsule())
                            .foregroundStyle(.white).padding(16)
                    }}
                }

                // Save feedback
                if let msg = saveMessage {
                    VStack { Spacer()
                        Text(msg).font(.callout.weight(.medium)).foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(.black.opacity(0.75), in: Capsule())
                            .padding(.bottom, 24)
                    }
                    .transition(.opacity)
                    .onAppear { Task { try? await Task.sleep(for: .seconds(2)); withAnimation { saveMessage = nil } } }
                }

                // Load error banner
                if let err = loadError {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.yellow)
                            Text(err)
                                .font(.caption)
                            Spacer()
                            Button("Dismiss") { loadError = nil }
                                .font(.caption)
                        }
                        .padding(8)
                        .background(.ultraThinMaterial)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in zoomScale = max(1.0, min(10.0, value.magnification)) }
            .onEnded { _ in if zoomScale < 1.05 { withAnimation { zoomScale = 1.0; panOffset = .zero } } }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { v in panOffset = CGSize(width: lastPanOffset.width + v.translation.width,
                                                  height: lastPanOffset.height + v.translation.height) }
            .onEnded { _ in lastPanOffset = panOffset }
    }

    // MARK: - Right Panel (switches by tool)

    private var rightPanel: some View {
        VStack(spacing: 0) {
            // Tool selector tabs
            HStack(spacing: 0) {
                ForEach(Tool.allCases, id: \.self) { tool in
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) { selectedTool = tool }
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: tool.icon)
                                .font(.system(size: 12))
                            Text(tool.rawValue)
                                .font(.system(size: 9, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .foregroundStyle(selectedTool == tool ? Color.accentColor : .secondary)
                        .background(selectedTool == tool ? Color.accentColor.opacity(0.1) : Color.clear)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Tool-specific content
            if selectedTool == .assistant {
                // Assistant gets full height (has its own scroll)
                assistantToolContent
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        switch selectedTool {
                        case .adjust:  adjustToolContent
                        case .masks:   masksToolContent
                        case .inpaint: inpaintToolContent
                        case .history: historyToolContent
                        case .assistant: EmptyView()
                        }
                    }
                    .padding(16)
                }

                Divider()

                // Action bar (always visible for adjust/masks)
                if selectedTool == .adjust || selectedTool == .masks || selectedTool == .inpaint {
                    actionBar.padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Tool: Adjust (default)

    private var adjustToolContent: some View {
        VStack(spacing: 16) {
            // Tone curve + histogram — click to add points, drag to adjust, double-click to remove
            ToneCurveEditorView(image: histogramCG, curvePoints: $curvePoints)
                .onChange(of: curvePoints) { nudgePreview() }

            adjustmentCard("White Balance") {
                adjustmentSlider("Temperature", value: $temperature, range: -100...100, step: 1, format: "%.0f")
                adjustmentSlider("Tint", value: $tint, range: -100...100, step: 1, format: "%.0f")
            }

            adjustmentCardWithAction("Levels", action: { autoAdjustLevels() }) {
                adjustmentSlider("Exposure", value: $exposure, range: -5...5, step: 0.05, format: "%+.2f")
                adjustmentSlider("Contrast", value: intBinding($contrast), range: -100...100)
                adjustmentSlider("Highlights", value: intBinding($highlights), range: -100...100)
                adjustmentSlider("Shadows", value: intBinding($shadows), range: -100...100)
                adjustmentSlider("Whites", value: intBinding($whites), range: -100...100)
                adjustmentSlider("Blacks", value: intBinding($blacks), range: -100...100)
                Divider().padding(.vertical, 2)
                adjustmentSlider("Clarity", value: $clarity, range: -100...100, step: 1, format: "%.0f")
                adjustmentSlider("Dehaze", value: $dehaze, range: -100...100, step: 1, format: "%.0f")
            }

            adjustmentCard("Color") {
                adjustmentSlider("Saturation", value: intBinding($saturation), range: -100...100)
                adjustmentSlider("Vibrance", value: intBinding($vibrance), range: -100...100)
            }

            // Advanced (collapsible)
            advancedSection
        }
    }

    // MARK: - Advanced Section

    private var advancedSection: some View {
        DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
            VStack(spacing: 12) {
                colorGradingSection
                hslSection
                calibrationSection
            }
            .padding(.top, 8)
        }
        .font(.subheadline.weight(.semibold))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    // MARK: - Color Grading

    private var colorGradingSection: some View {
        DisclosureGroup("Color Grading", isExpanded: $colorGradingExp) {
            VStack(spacing: 4) {
                Text("Shadows").font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
                adjustmentSlider("Hue",        value: intBinding($adj.colorGrading.shadows.hue),        range: 0...360)
                adjustmentSlider("Saturation", value: intBinding($adj.colorGrading.shadows.saturation), range: 0...100)
                adjustmentSlider("Luminance",  value: intBinding($adj.colorGrading.shadows.luminance),  range: -100...100)

                Text("Midtones").font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                adjustmentSlider("Hue",        value: intBinding($adj.colorGrading.midtones.hue),        range: 0...360)
                adjustmentSlider("Saturation", value: intBinding($adj.colorGrading.midtones.saturation), range: 0...100)
                adjustmentSlider("Luminance",  value: intBinding($adj.colorGrading.midtones.luminance),  range: -100...100)

                Text("Highlights").font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                adjustmentSlider("Hue",        value: intBinding($adj.colorGrading.highlights.hue),        range: 0...360)
                adjustmentSlider("Saturation", value: intBinding($adj.colorGrading.highlights.saturation), range: 0...100)
                adjustmentSlider("Luminance",  value: intBinding($adj.colorGrading.highlights.luminance),  range: -100...100)

                Divider().padding(.vertical, 2)
                adjustmentSlider("Balance",  value: intBinding($adj.colorGrading.balance),  range: -100...100)
                adjustmentSlider("Blending", value: intBinding($adj.colorGrading.blending), range: 0...100)
            }
        }
        .font(.caption.weight(.medium))
    }

    // MARK: - HSL

    private var hslSection: some View {
        DisclosureGroup("HSL", isExpanded: $hslExpanded) {
            VStack(spacing: 4) {
                Picker("Channel", selection: $selectedHSL) {
                    ForEach(HSLChannelName.allCases) { ch in Text(ch.label).tag(ch) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(.bottom, 4)

                let ch = hslChannelBinding(selectedHSL)
                adjustmentSlider("Hue",        value: intBinding(ch.hue),        range: -100...100)
                adjustmentSlider("Saturation", value: intBinding(ch.saturation), range: -100...100)
                adjustmentSlider("Luminance",  value: intBinding(ch.luminance),  range: -100...100)
            }
        }
        .font(.caption.weight(.medium))
    }

    private func hslChannelBinding(_ name: HSLChannelName) -> Binding<PhotoAdjustments.HSLChannel> {
        switch name {
        case .red:     return $adj.hsl.red
        case .orange:  return $adj.hsl.orange
        case .yellow:  return $adj.hsl.yellow
        case .green:   return $adj.hsl.green
        case .aqua:    return $adj.hsl.aqua
        case .blue:    return $adj.hsl.blue
        case .purple:  return $adj.hsl.purple
        case .magenta: return $adj.hsl.magenta
        }
    }

    // MARK: - Calibration

    private var calibrationSection: some View {
        DisclosureGroup("Calibration", isExpanded: $calibrationExp) {
            VStack(spacing: 4) {
                Text("Red Primary").font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
                adjustmentSlider("Hue",        value: intBinding($adj.calibration.red.hue),        range: -100...100)
                adjustmentSlider("Saturation", value: intBinding($adj.calibration.red.saturation), range: -100...100)

                Text("Green Primary").font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                adjustmentSlider("Hue",        value: intBinding($adj.calibration.green.hue),        range: -100...100)
                adjustmentSlider("Saturation", value: intBinding($adj.calibration.green.saturation), range: -100...100)

                Text("Blue Primary").font(.caption2).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                adjustmentSlider("Hue",        value: intBinding($adj.calibration.blue.hue),        range: -100...100)
                adjustmentSlider("Saturation", value: intBinding($adj.calibration.blue.saturation), range: -100...100)
            }
        }
        .font(.caption.weight(.medium))
    }

    // MARK: - Tool: Masks

    private var masksToolContent: some View {
        VStack(spacing: 12) {
            maskLayerBar

            if let selectedId = selectedMaskId,
               let idx = maskLayers.firstIndex(where: { $0.id == selectedId }) {
                MaskAdjustmentPanel(
                    layer: $maskLayers[idx],
                    onDelete: {
                        maskLayers.remove(at: idx)
                        selectedMaskId = nil
                        nudgePreview()
                        Task { await persistToDB() }
                    },
                    onAddLinearGradient: {
                        maskInteractionMode = .placingLinearGradient
                    },
                    onAddRadialGradient: {
                        maskInteractionMode = .placingRadialGradient
                    },
                    onAddMaskSource: { sourceType in
                        addMaskSource(sourceType)
                    }
                )
                .onChange(of: maskLayers[idx].adjustments) { nudgePreview() }
                .onChange(of: maskLayers[idx].opacity) { nudgePreview() }
                .onChange(of: maskLayers[idx].sources) { nudgePreview() }
            }
        }
    }

    // MARK: - Tool: Assistant (merged Editorial + Chat)

    private func loadPhotoContext() async {
        guard let photo = currentPhoto else { cachedPhotoContext = ""; return }
        var parts: [String] = []
        if let date = photo.dateModified ?? Optional(photo.createdAt) {
            parts.append("DATE: \(date)")
        }
        if let scene = photo.sceneType { parts.append("SCENE: \(scene)") }
        // Parse EXIF
        if let exif = photo.rawExifJson,
           let data = exif.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let lat = dict["latitude"] as? Double, let lon = dict["longitude"] as? Double {
                parts.append("GPS: \(lat), \(lon)")
            }
            if let loc = dict["location"] as? String { parts.append("LOCATION: \(loc)") }
            if let cam = dict["cameraMake"] as? String { parts.append("CAMERA: \(cam) \(dict["cameraModel"] as? String ?? "")") }
            if let iso = dict["iso"] as? Int { parts.append("ISO: \(iso)") }
            if let ss = dict["shutterSpeed"] as? Double { parts.append("SHUTTER: \(ss)s") }
            if let ap = dict["aperture"] as? Double { parts.append("APERTURE: f/\(ap)") }
            if let fl = dict["focalLength"] as? Double { parts.append("FOCAL: \(fl)mm") }
        }
        // People from face embeddings (async-safe)
        if let db = appDatabase {
            do {
                let (names, faceCount) = try await db.dbPool.read { d -> ([String], Int) in
                    let nameRows = try Row.fetchAll(d, sql: """
                        SELECT DISTINCT p.name FROM face_embeddings fe
                        JOIN person_identities p ON p.id = fe.person_id
                        WHERE fe.photo_id = ? AND p.name IS NOT NULL AND p.name != ''
                    """, arguments: [photo.id])
                    let names = nameRows.map { $0["name"] as String }
                    let count = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM face_embeddings WHERE photo_id = ?",
                                                 arguments: [photo.id]) ?? 0
                    return (names, count)
                }
                if !names.isEmpty {
                    parts.append("PEOPLE IN PHOTO: \(names.joined(separator: ", "))")
                }
                if faceCount > 0 && names.isEmpty {
                    parts.append("FACES DETECTED: \(faceCount) (not yet identified)")
                } else if faceCount > names.count {
                    parts.append("FACES DETECTED: \(faceCount) (\(faceCount - names.count) unidentified)")
                }
            } catch {
                print("[DevelopView] People query failed: \(error)")
            }
        }
        print("[DevelopView] photoContext for \(photo.canonicalName): \(parts.joined(separator: " | "))")
        cachedPhotoContext = parts.joined(separator: "\n")
    }

    private var assistantToolContent: some View {
        DevelopChatView(
            photoId: currentPhoto?.id ?? "",
            photoName: currentPhoto?.canonicalName ?? "Photo",
            proxyImageBase64: proxyImageBase64,
            photoContext: cachedPhotoContext,
            currentAdjustments: {
                var a = PhotoAdjustments()
                a.exposure = exposure; a.contrast = contrast
                a.highlights = highlights; a.shadows = shadows
                a.whites = whites; a.blacks = blacks
                a.saturation = saturation; a.vibrance = vibrance
                return a
            },
            onApplyAdjustments: { adj in
                withAnimation(.easeOut(duration: 0.25)) {
                    if let e = adj.exposure { exposure = e }
                    if let c = adj.contrast { contrast = c }
                    if let h = adj.highlights { highlights = h }
                    if let s = adj.shadows { shadows = s }
                    if let w = adj.whites { whites = w }
                    if let b = adj.blacks { blacks = b }
                    if let s = adj.saturation { saturation = s }
                    if let v = adj.vibrance { vibrance = v }
                }
                nudgePreview()
            },
            onUndoAdjustments: { snapshot in
                withAnimation(.easeOut(duration: 0.25)) {
                    exposure = snapshot.exposure; contrast = snapshot.contrast
                    highlights = snapshot.highlights; shadows = snapshot.shadows
                    whites = snapshot.whites; blacks = snapshot.blacks
                    saturation = snapshot.saturation; vibrance = snapshot.vibrance
                }
                nudgePreview()
            },
            onRequestEditorial: {
                guard let photo = currentPhoto else { return }
                Task { await viewModel.requestEditorialFeedback(for: photo.id, db: appDatabase) }
            },
            onAutoAdjust: { [self] in
                autoAdjustLevels()
            },
            onDetectMasks: { [self] in
                Task { await autoSegmentWithVision() }
                selectedTool = .masks
            },
            onSwitchTool: { [self] toolName in
                switch toolName {
                case "masks": selectedTool = .masks
                case "adjust": selectedTool = .adjust
                case "history": selectedTool = .history
                default: break
                }
            },
            onSearchByFace: { faceIndex, faceImage in
                guard let photo = currentPhoto, let db = appDatabase else { return }
                Task {
                    await viewModel.searchByFace(
                        photoId: photo.id, faceIndex: faceIndex,
                        faceImage: faceImage, db: db
                    )
                    withAnimation { isPresented = false }
                }
            },
            photo: currentPhoto,
            editorialFeedback: viewModel.editorialFeedbackPhotoId == currentPhoto?.id ? viewModel.editorialFeedback : nil,
            editorialLoading: viewModel.editorialFeedbackLoading
        )
        .id(currentPhoto?.id)
    }



    // MARK: - Tool: Inpaint

    @State private var inpaintBrushSize: CGFloat = 30
    @State private var inpaintBrushSoftness: CGFloat = 0.5
    @State private var inpaintMaskImage: NSImage?
    @State private var inpaintResultImage: NSImage?
    @State private var inpaintIsRunning: Bool = false
    @State private var inpaintShowResult: Bool = false
    @State private var inpaintMaskStrokes: [[CGPoint]] = []
    @State private var inpaintCurrentStroke: [CGPoint] = []

    private var inpaintToolContent: some View {
        VStack(spacing: 16) {
            // Brush settings
            VStack(alignment: .leading, spacing: 10) {
                Text("BRUSH")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Size")
                        .font(.system(size: 11))
                        .frame(width: 55, alignment: .trailing)
                    Slider(value: $inpaintBrushSize, in: 5...150, step: 1)
                    Text("\(Int(inpaintBrushSize)) px")
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: 42)
                }

                HStack {
                    Text("Softness")
                        .font(.system(size: 11))
                        .frame(width: 55, alignment: .trailing)
                    Slider(value: $inpaintBrushSoftness, in: 0...1, step: 0.05)
                    Text(String(format: "%.0f%%", inpaintBrushSoftness * 100))
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: 42)
                }

                // Brush preview
                HStack {
                    Spacer()
                    ZStack {
                        Circle()
                            .fill(
                                RadialGradient(
                                    gradient: Gradient(colors: [
                                        Color.red.opacity(0.8),
                                        Color.red.opacity(0.8 * (1.0 - inpaintBrushSoftness))
                                    ]),
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: min(inpaintBrushSize, 60) / 2
                                )
                            )
                            .frame(
                                width: min(inpaintBrushSize, 60),
                                height: min(inpaintBrushSize, 60)
                            )

                        Circle()
                            .strokeBorder(Color.white.opacity(0.6), lineWidth: 1)
                            .frame(
                                width: min(inpaintBrushSize, 60),
                                height: min(inpaintBrushSize, 60)
                            )
                    }
                    .frame(height: 70)
                    Spacer()
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            // Mask info
            VStack(alignment: .leading, spacing: 8) {
                Text("MASK")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(inpaintMaskStrokes.count) stroke\(inpaintMaskStrokes.count == 1 ? "" : "s")")
                            .font(.system(size: 12))
                        if !inpaintMaskStrokes.isEmpty {
                            Text("Paint on the image to mark areas to remove")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    if !inpaintMaskStrokes.isEmpty {
                        Button("Clear Mask") {
                            inpaintMaskStrokes.removeAll()
                            inpaintMaskImage = nil
                            inpaintResultImage = nil
                            inpaintShowResult = false
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if inpaintMaskStrokes.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "paintbrush.pointed")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                        Text("Paint over areas to remove — dust, scratches, unwanted objects. Use a soft brush for natural edges.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.03))
                    )
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            // Run inpainting
            VStack(alignment: .leading, spacing: 8) {
                Text("INPAINT")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text("Uses LaMa (CoreML) to fill masked areas with generated content that matches the surrounding image.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if inpaintIsRunning {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Running inpainting model...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                }

                if let _ = inpaintResultImage {
                    // Result controls
                    HStack(spacing: 8) {
                        Toggle("Show Result", isOn: $inpaintShowResult)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .font(.system(size: 11))
                    }

                    HStack(spacing: 8) {
                        Button("Accept") {
                            applyInpaintResult()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button("Reject") {
                            inpaintResultImage = nil
                            inpaintShowResult = false
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer()

                        Button("Re-run") {
                            runInpainting()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else {
                    Button {
                        runInpainting()
                    } label: {
                        HStack {
                            Image(systemName: "wand.and.stars")
                            Text("Run Inpainting")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(inpaintMaskStrokes.isEmpty || inpaintIsRunning)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            // Saved masks
            VStack(alignment: .leading, spacing: 8) {
                Text("SAVED MASKS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                if inpaintMaskStrokes.isEmpty {
                    Text("No masks saved yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Button {
                        saveInpaintMask()
                    } label: {
                        Label("Save Current Mask", systemImage: "square.and.arrow.down")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            // Keyboard shortcuts
            VStack(alignment: .leading, spacing: 4) {
                Text("SHORTCUTS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                shortcutRow("[", "Decrease brush size")
                shortcutRow("]", "Increase brush size")
                shortcutRow("\\", "Toggle before/after")
                shortcutRow("⌘Z", "Undo last stroke")
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }

    private func shortcutRow(_ key: String, _ desc: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.08))
                )
            Text(desc)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func runInpainting() {
        guard !inpaintMaskStrokes.isEmpty else { return }
        inpaintIsRunning = true

        // TODO: Replace with real CoreML LaMa inference
        // For now, simulate processing delay
        Task {
            try? await Task.sleep(for: .seconds(2))
            // Placeholder: return the original image as "result"
            // Real implementation will:
            // 1. Render mask strokes to a binary mask CGImage
            // 2. Pass image + mask to LaMa CoreML model
            // 3. Return inpainted result
            inpaintResultImage = previewImage
            inpaintIsRunning = false
            inpaintShowResult = true
        }
    }

    private func applyInpaintResult() {
        guard let result = inpaintResultImage else { return }
        // Apply the inpainted result as the new base image
        // TODO: Save to adjustment snapshot before applying
        previewImage = result
        inpaintResultImage = nil
        inpaintShowResult = false
        inpaintMaskStrokes.removeAll()
        inpaintMaskImage = nil
    }

    private func saveInpaintMask() {
        // TODO: Serialize mask strokes to JSON and persist
        // Will save brush size, softness, and stroke points per mask
    }

    // MARK: - Tool: History

    @State private var historyEvents: [ActivityEvent] = []
    @State private var showActivityLog = false

    private var historyToolContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Version checkpoints section
            versionBrowserSection

            Divider()

            // Collapsible activity log
            DisclosureGroup("Activity Log", isExpanded: $showActivityLog) {
                if historyEvents.isEmpty {
                    Text("No activity recorded for this photo yet.")
                        .font(.caption).foregroundStyle(.tertiary)
                        .padding(.top, 8)
                } else {
                    ForEach(historyEvents) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Image(systemName: iconForEvent(event))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(event.title)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                Spacer()
                                Text(event.occurredAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .font(.system(size: 9)).foregroundStyle(.quaternary)
                            }
                            if let detail = event.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.caption2).foregroundStyle(.tertiary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
            .font(.subheadline.weight(.semibold))
        }
        .task(id: currentPhoto?.id) {
            await loadHistory()
            await loadVersionSnapshots()
        }
    }

    // MARK: - Version Browser

    private var versionBrowserSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Versions").font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    versionLabelInput = ""
                    showSaveVersionSheet = true
                } label: {
                    Image(systemName: "plus.circle").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Save a new version checkpoint")

                Button { Task { await loadVersionSnapshots() } } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.borderless)
            }

            if versionSnapshots.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.title3).foregroundStyle(.tertiary)
                        Text("No saved versions yet.")
                            .font(.caption).foregroundStyle(.tertiary)
                        Text("Use \"Save Version\" to create a checkpoint.")
                            .font(.caption2).foregroundStyle(.quaternary)
                    }
                    .padding(.vertical, 12)
                    Spacer()
                }
            } else {
                ForEach(versionSnapshots.reversed()) { snapshot in
                    versionRow(snapshot)
                }
            }
        }
    }

    private func versionRow(_ snapshot: AdjustmentSnapshot) -> some View {
        let isCurrent = snapshot.isCurrentState
        return HStack(alignment: .top, spacing: 8) {
            // Thumbnail preview
            if let thumbPath = snapshot.thumbnailPath,
               let thumbImage = NSImage(contentsOfFile: thumbPath) {
                Image(nsImage: thumbImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 36)
                    .clipped()
                    .cornerRadius(4)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 48, height: 36)
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 12))
                            .foregroundStyle(.quaternary)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                        .font(.caption)
                        .foregroundStyle(isCurrent ? .green : .secondary)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(snapshot.label ?? "Auto-save")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(snapshot.label != nil ? .primary : .secondary)
                            .lineLimit(1)
                        Text(snapshot.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.system(size: 9)).foregroundStyle(.quaternary)
                    }

                    Spacer()

                    if !isCurrent {
                        Button {
                            restoreConfirmSnapshot = snapshot
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .help("Restore this version")
                    }
                }

                // Adjustment summary
                if let adj = PhotoAdjustments.decode(from: snapshot.adjustmentJSON) {
                    Text(adjSummary(adj))
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isCurrent ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .contextMenu {
            Button("Rename...") {
                renameLabelInput = snapshot.label ?? ""
                renameTarget = snapshot
            }
            if !isCurrent {
                Button("Restore") {
                    restoreConfirmSnapshot = snapshot
                }
            }
            Divider()
            Button("Delete", role: .destructive) {
                Task { await deleteVersion(snapshot) }
            }
        }
        .popover(isPresented: Binding(
            get: { renameTarget?.id == snapshot.id },
            set: { if !$0 { renameTarget = nil } }
        )) {
            VStack(spacing: 8) {
                Text("Rename Version").font(.caption.weight(.semibold))
                TextField("Label", text: $renameLabelInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                HStack {
                    Button("Cancel") { renameTarget = nil }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button("Save") {
                        Task {
                            await renameVersion(snapshot, newLabel: renameLabelInput)
                            renameTarget = nil
                        }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(renameLabelInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(12)
        }
    }

    // MARK: - Save Version Sheet

    private var saveVersionSheet: some View {
        VStack(spacing: 16) {
            Text("Save Version").font(.headline)
            Text("Create a named checkpoint of the current adjustments.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("Version name (e.g. \"Base grade\", \"After crop\")", text: $versionLabelInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)

            HStack(spacing: 12) {
                Button("Cancel") {
                    showSaveVersionSheet = false
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    let label = versionLabelInput.trimmingCharacters(in: .whitespaces)
                    Task {
                        await saveVersionCheckpoint(label: label.isEmpty ? "Checkpoint" : label)
                        showSaveVersionSheet = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }

    private func loadHistory() async {
        guard let db = appDatabase, let photoId = currentPhoto?.id else {
            historyEvents = []; return
        }
        let repo = ActivityEventRepository(db: db)
        historyEvents = (try? await repo.fetchEventsForPhoto(photoId, limit: 30)) ?? []
    }

    private func iconForEvent(_ event: ActivityEvent) -> String {
        switch event.kind {
        case .adjustment:    return "slider.horizontal.3"
        case .note:          return "note.text"
        case .aiSummary:     return "sparkles"
        case .editorialReview: return "text.magnifyingglass"
        case .printAttempt:  return "printer"
        case .rollback:      return "arrow.uturn.backward"
        case .importBatch:   return "square.and.arrow.down"
        default:             return "circle.fill"
        }
    }

    // MARK: - Mask Layer Bar

    private var maskLayerBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // Add Layer
                Button {
                    let layer = AdjustmentLayer(label: "Layer \(maskLayers.count + 1)")
                    maskLayers.append(layer)
                    selectedMaskId = layer.id
                    showMaskOverlay = true
                    nudgePreview()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                        Text("Layer")
                    }.font(.caption2.weight(.medium))
                }
                .buttonStyle(.bordered).controlSize(.small)

                // Add Mask to selected layer
                if let selectedId = selectedMaskId,
                   maskLayers.contains(where: { $0.id == selectedId }) {
                    Menu {
                        Button("Linear Gradient") {
                            maskInteractionMode = .placingLinearGradient
                        }
                        Button("Radial Gradient") {
                            maskInteractionMode = .placingRadialGradient
                        }
                        Divider()
                        Button("Rectangle") {
                            addMaskSource(.rectangle(normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)))
                        }
                        Button("Ellipse") {
                            addMaskSource(.ellipse(normalizedRect: CGRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7)))
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus.circle")
                            Text("Mask")
                        }.font(.caption2.weight(.medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Spacer()

                if showMaskOverlay && !maskLayers.isEmpty {
                    Button { showMaskOverlay = false } label: { Image(systemName: "eye.slash").font(.caption) }
                        .buttonStyle(.borderless)
                } else if !maskLayers.isEmpty {
                    Button { showMaskOverlay = true } label: { Image(systemName: "eye").font(.caption) }
                        .buttonStyle(.borderless)
                }

                Button {
                    Task { await autoSegmentWithVision() }
                } label: {
                    HStack(spacing: 3) {
                        if isAutoSegmenting { ProgressView().scaleEffect(0.5) }
                        else { Image(systemName: "wand.and.stars") }
                        Text(isAutoSegmenting ? "..." : "Detect")
                    }.font(.caption2.weight(.medium))
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(isAutoSegmenting || previewBaseCG == nil)
            }

            // Global layer
            maskLayerRow(icon: "slider.horizontal.3", label: "Global", summary: globalSummary,
                         isSelected: selectedMaskId == nil, isActive: .constant(true),
                         onSelect: { selectedMaskId = nil }, onDelete: nil)

            ForEach(maskLayers.indices, id: \.self) { i in
                maskLayerRow(icon: iconForMask(maskLayers[i]), label: maskLayers[i].label,
                             summary: adjSummary(maskLayers[i].adjustments),
                             isSelected: maskLayers[i].id == selectedMaskId,
                             isActive: $maskLayers[i].isActive,
                             onSelect: { selectedMaskId = maskLayers[i].id },
                             onDelete: { maskLayers.remove(at: i); selectedMaskId = nil; nudgePreview(); Task { await persistToDB() } })
                    .onChange(of: maskLayers[i].isActive) { nudgePreview() }
            }

            if !autoSegments.isEmpty {
                Divider().padding(.vertical, 2)
                Text("Detected").font(.caption2).foregroundStyle(.tertiary)
                ForEach(autoSegments) { seg in
                    Button {
                        let layer = AdjustmentLayer(
                            label: seg.label,
                            sources: [MaskSource(sourceType: .bitmap(rle: Data(seg.maskPixels), width: seg.width, height: seg.height))]
                        )
                        maskLayers.append(layer)
                        selectedMaskId = layer.id
                        showMaskOverlay = true
                        autoSegments.removeAll { $0.id == seg.id }
                        nudgePreview()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle").font(.caption2).foregroundStyle(.blue)
                            Text(seg.label).font(.caption2)
                            Spacer()
                            Text("\(String(format: "%.0f", seg.coverage * 100))%")
                                .font(.caption2).foregroundStyle(.quaternary)
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    /// Add a mask source to the currently selected layer.
    private func addMaskSource(_ sourceType: MaskSourceType) {
        guard let selectedId = selectedMaskId,
              let idx = maskLayers.firstIndex(where: { $0.id == selectedId }) else { return }
        let source = MaskSource(sourceType: sourceType)
        maskLayers[idx].sources.append(source)
        showMaskOverlay = true
        nudgePreview()
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button("Reset") { resetAll() }.buttonStyle(.bordered)
            Spacer()
            if isSaving { ProgressView().scaleEffect(0.7) }
            Button("Apply") { Task { await saveAdjustments() } }
                .buttonStyle(.borderedProminent)
                .disabled(isIdentity && maskLayers.allSatisfy { $0.adjustments.isIdentity })
        }
    }

    // MARK: - Filmstrip

    private var filmstripBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 3) {
                    ForEach(developPhotos) { p in
                        filmstripThumb(p).id(p.id)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 4)
            }
            .frame(height: 56)
            .background(Color(nsColor: .controlBackgroundColor))
            .onChange(of: currentPhoto?.id) { _, newId in
                if let id = newId { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
            .onAppear { if let id = currentPhoto?.id { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    private func filmstripThumb(_ p: PhotoAsset) -> some View {
        let isCurrent = p.id == currentPhoto?.id
        let baseName = (p.canonicalName as NSString).deletingPathExtension
        let thumbURL = ProxyGenerationActor.thumbsDirectory().appendingPathComponent(baseName + ".jpg")
        return Button {
            guard p.id != currentPhoto?.id else { return }
            Task { await persistToDB() }
            maskLayers.removeAll(); selectedMaskId = nil
            autoSegments.removeAll(); showMaskOverlay = false
            resetSliders(); previewImage = nil
            withAnimation(.easeInOut(duration: 0.15)) {
                viewModel.developPhoto = p
                viewModel.selectedPhotoID = p.id
                zoomScale = 1.0; panOffset = .zero; lastPanOffset = .zero
            }
        } label: {
            Group {
                if let img = NSImage(contentsOf: thumbURL) {
                    Image(nsImage: img).resizable().scaledToFill()
                } else { Color.gray.opacity(0.2) }
            }
            .frame(width: 64, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(isCurrent ? Color.accentColor : Color.clear, lineWidth: 2))
            .opacity(isCurrent ? 1.0 : 0.6)
        }.buttonStyle(.plain)
    }

    // MARK: - Navigation

    private func navigatePhoto(by delta: Int) {
        guard let idx = currentIndex else { return }
        let newIdx = idx + delta
        guard newIdx >= 0, newIdx < developPhotos.count else { return }

        // Auto-save current state before switching
        Task { await persistToDB() }

        // Clear mask/adjustment state for new photo (image stays until new one loads)
        maskLayers.removeAll()
        selectedMaskId = nil
        autoSegments.removeAll()
        showMaskOverlay = false
        resetSliders()
        previewImage = nil

        withAnimation(.easeInOut(duration: 0.25)) {
            let newPhoto = developPhotos[newIdx]
            viewModel.developPhoto = newPhoto
            viewModel.selectedPhotoID = newPhoto.id
            zoomScale = 1.0; panOffset = .zero; lastPanOffset = .zero
        }
    }

    // MARK: - Image Loading

    private func loadImage() async {
        guard let photo = currentPhoto else { return }
        do {
            let baseName = (photo.canonicalName as NSString).deletingPathExtension
            let proxyURL = ProxyGenerationActor.proxiesDirectory().appendingPathComponent(baseName + ".jpg")
            let originalPath: String? = if let db = appDatabase {
                try? await db.dbPool.read { d -> String? in
                    try String.fetchOne(d, sql: "SELECT original_file_path FROM photo_assets WHERE id = ?",
                                        arguments: [photo.id])
                }
            } else { nil }
            let sourceURL = URL(fileURLWithPath: photo.filePath)

            let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                if let origPath = originalPath, let origImg = NSImage(contentsOfFile: origPath) { return origImg }
                if let proxy = NSImage(contentsOf: proxyURL) { return proxy }
                let opts: CFDictionary? = sourceURL.pathExtension.lowercased() == "dng"
                    ? [kCGImageSourceTypeIdentifierHint: UTType.tiff.identifier] as CFDictionary : nil
                guard let src = CGImageSourceCreateWithURL(sourceURL as CFURL, opts),
                      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }.value

            if img == nil {
                loadError = "Could not load image for \(photo.canonicalName)"
            }

            displayImage = img
            previewImage = nil
            if let cg = img?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                previewBaseCG = await Task.detached(priority: .userInitiated) { Self.scale(cg, maxEdge: 800) ?? cg }.value
            }
            nudgePreview()
        }
    }

    // MARK: - DB Load/Save

    private func loadAdjustmentsFromDB() async {
        guard let db = appDatabase, let photo = currentPhoto else { return }
        do {
            let json = try await db.dbPool.read { d -> String? in
                try String.fetchOne(d, sql: "SELECT adjustments_json FROM photo_assets WHERE id = ?", arguments: [photo.id])
            }
            guard let json, let saved = PhotoAdjustments.decode(from: json) else { resetSliders(); return }
            exposure = saved.exposure; contrast = saved.contrast; highlights = saved.highlights
            shadows = saved.shadows; whites = saved.whites; blacks = saved.blacks
            saturation = saved.saturation; vibrance = saved.vibrance
            temperature = saved.temperature; tint = saved.tint
            clarity = saved.clarity; dehaze = saved.dehaze
            adj.colorGrading = saved.colorGrading; adj.hsl = saved.hsl
            adj.calibration = saved.calibration
            curvePoints = saved.curvePoints ?? []
        } catch {
            loadError = "Failed to load adjustments: \(error.localizedDescription)"
            resetSliders()
        }
    }

    private func loadMasksFromDB() async {
        guard let db = appDatabase, let photo = currentPhoto else { return }
        do {
            let masksJson = try await db.dbPool.read { d -> String? in
                try String.fetchOne(d, sql: "SELECT masks_json FROM photo_assets WHERE id = ?", arguments: [photo.id])
            }
            maskLayers = MaskLayerStore.decode(from: masksJson)
            selectedMaskId = nil
            showMaskOverlay = !maskLayers.isEmpty
        } catch {
            loadError = "Failed to load masks: \(error.localizedDescription)"
            maskLayers = []
            selectedMaskId = nil
            showMaskOverlay = false
        }
    }

    private func persistToDB() async {
        guard let db = appDatabase, let photo = currentPhoto else { return }
        guard let json = currentAdjustments().encodeToJSON() else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        let masksStr = MaskLayerStore.encode(maskLayers)
        try? await db.dbPool.write { d in
            try d.execute(sql: "UPDATE photo_assets SET adjustments_json = ?, masks_json = ?, updated_at = ? WHERE id = ?",
                          arguments: [json, masksStr, now, photo.id])
        }
    }

    /// Build a PhotoAdjustments from current slider state.
    private func currentAdjustments() -> PhotoAdjustments {
        var toSave = PhotoAdjustments()
        toSave.exposure = exposure; toSave.contrast = contrast; toSave.highlights = highlights
        toSave.shadows = shadows; toSave.whites = whites; toSave.blacks = blacks
        toSave.saturation = saturation; toSave.vibrance = vibrance
        toSave.temperature = temperature; toSave.tint = tint
        toSave.clarity = clarity; toSave.dehaze = dehaze
        toSave.colorGrading = adj.colorGrading; toSave.hsl = adj.hsl
        toSave.calibration = adj.calibration
        toSave.curvePoints = curvePoints.isEmpty ? nil : curvePoints
        return toSave
    }

    // MARK: - In-Memory Undo / Redo

    /// Call this immediately before making a programmatic adjustment change (auto-level, restore, etc.)
    /// so the previous state can be recovered via the Undo button.
    private func captureUndoSnapshot() {
        undoStack.append(currentAdjustments())
        // Limit stack depth to avoid unbounded growth
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func applyAdjustments(_ a: PhotoAdjustments) {
        withAnimation(.easeOut(duration: 0.2)) {
            exposure = a.exposure; contrast = a.contrast
            highlights = a.highlights; shadows = a.shadows
            whites = a.whites; blacks = a.blacks
            saturation = a.saturation; vibrance = a.vibrance
            temperature = a.temperature; tint = a.tint
            clarity = a.clarity; dehaze = a.dehaze
            adj.colorGrading = a.colorGrading; adj.hsl = a.hsl
            adj.calibration = a.calibration
            curvePoints = a.curvePoints ?? []
        }
        nudgePreview()
    }

    private func performUndo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(currentAdjustments())
        applyAdjustments(previous)
    }

    private func performRedo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentAdjustments())
        applyAdjustments(next)
    }

    // MARK: - Version Checkpoints

    private func loadVersionSnapshots() async {
        guard let db = appDatabase, let photoId = currentPhoto?.id else {
            versionSnapshots = []; return
        }
        let repo = AdjustmentSnapshotRepository(db: db)
        versionSnapshots = (try? await repo.fetchSnapshots(forPhoto: photoId)) ?? []
    }

    private func saveVersionCheckpoint(label: String) async {
        guard let db = appDatabase, let photo = currentPhoto else { return }
        let adjustments = currentAdjustments()
        guard let json = adjustments.encodeToJSON() else { return }
        let masksStr = MaskLayerStore.encode(maskLayers)

        // Also persist current state to photo_assets so it matches
        await persistToDB()

        let snapshotId = UUID().uuidString

        // Render thumbnail from current preview
        let thumbPath: String? = await Task.detached(priority: .utility) {
            guard let img = await MainActor.run(body: { self.previewImage ?? self.displayImage }) else { return nil as String? }
            return SnapshotThumbnailService.renderThumbnail(from: img, snapshotId: snapshotId)
        }.value

        let snapshot = AdjustmentSnapshot(
            id: snapshotId,
            photoAssetId: photo.id,
            label: label,
            adjustmentJSON: json,
            masksJSON: masksStr,
            thumbnailPath: thumbPath,
            isCurrentState: true,
            createdAt: Date()
        )
        let repo = AdjustmentSnapshotRepository(db: db)
        try? await repo.saveSnapshot(snapshot)
        await loadVersionSnapshots()

        // Emit activity event
        if let activityEventService {
            let versionNumber = versionSnapshots.count
            try? await activityEventService.emitVersionCreated(
                photoAssetId: photo.id,
                versionName: label,
                versionNumber: versionNumber
            )
        }

        withAnimation { saveMessage = "Version saved: \(label)" }
    }

    private func restoreVersion(_ snapshot: AdjustmentSnapshot) async {
        guard let db = appDatabase, let photo = currentPhoto else { return }
        guard let restored = PhotoAdjustments.decode(from: snapshot.adjustmentJSON) else { return }
        captureUndoSnapshot()

        // Apply adjustments to sliders
        withAnimation(.easeOut(duration: 0.25)) {
            exposure = restored.exposure; contrast = restored.contrast
            highlights = restored.highlights; shadows = restored.shadows
            whites = restored.whites; blacks = restored.blacks
            saturation = restored.saturation; vibrance = restored.vibrance
            temperature = restored.temperature; tint = restored.tint
            clarity = restored.clarity; dehaze = restored.dehaze
            adj.colorGrading = restored.colorGrading
            adj.hsl = restored.hsl
            adj.calibration = restored.calibration
        }

        // Restore mask layers if present
        maskLayers = MaskLayerStore.decode(from: snapshot.masksJSON)
        selectedMaskId = nil
        showMaskOverlay = !maskLayers.isEmpty

        nudgePreview()

        // Save a new snapshot recording the restore action
        let restoredId = UUID().uuidString

        // Render thumbnail from the newly-restored preview
        let thumbPath: String? = await Task.detached(priority: .utility) {
            guard let img = await MainActor.run(body: { self.previewImage ?? self.displayImage }) else { return nil as String? }
            return SnapshotThumbnailService.renderThumbnail(from: img, snapshotId: restoredId)
        }.value

        let restoredSnapshot = AdjustmentSnapshot(
            id: restoredId,
            photoAssetId: photo.id,
            label: "Restored: \(snapshot.label ?? "previous state")",
            adjustmentJSON: snapshot.adjustmentJSON,
            masksJSON: snapshot.masksJSON,
            thumbnailPath: thumbPath,
            isCurrentState: true,
            createdAt: Date()
        )
        let repo = AdjustmentSnapshotRepository(db: db)
        try? await repo.saveSnapshot(restoredSnapshot)

        // Persist to photo_assets
        await persistToDB()
        await loadVersionSnapshots()
        withAnimation { saveMessage = "Restored: \(snapshot.label ?? "version")" }
    }

    private func deleteVersion(_ snapshot: AdjustmentSnapshot) async {
        guard let db = appDatabase else { return }
        let repo = AdjustmentSnapshotRepository(db: db)
        let deleted = try? await repo.deleteSnapshot(id: snapshot.id)
        // Clean up thumbnail file from disk
        SnapshotThumbnailService.deleteThumbnail(atPath: deleted?.thumbnailPath)
        await loadVersionSnapshots()
    }

    private func renameVersion(_ snapshot: AdjustmentSnapshot, newLabel: String) async {
        guard let db = appDatabase else { return }
        let repo = AdjustmentSnapshotRepository(db: db)
        try? await repo.renameSnapshot(id: snapshot.id, newLabel: newLabel)
        await loadVersionSnapshots()
    }

    // MARK: - Preview Pipeline

    private func nudgePreview() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            previewTrigger &+= 1
        }
    }

    // MARK: - Auto Adjust

    /// Analyze the base image histogram and set Levels sliders to produce a balanced histogram.
    /// Uses percentile-based analysis similar to Lightroom's Auto tone.
    private func autoAdjustLevels() {
        guard let cg = previewBaseCG else { return }
        captureUndoSnapshot()

        // Render to known RGBA format for reliable pixel access
        let w = cg.width, h = cg.height
        let bpr = w * 4
        guard w > 0, h > 0 else { return }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return }

        let ptr = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let count = w * h

        // Build per-channel and luminance histograms
        var lumHist = [Int](repeating: 0, count: 256)
        var totalLum: Double = 0

        for i in 0..<count {
            let off = i * 4
            let r = Double(ptr[off])
            let g = Double(ptr[off + 1])
            let b = Double(ptr[off + 2])
            let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let lumInt = max(0, min(255, Int(lum)))
            lumHist[lumInt] += 1
            totalLum += lum
        }

        let meanLum = totalLum / Double(count)
        let countD = Double(count)

        // Find percentile values
        func percentile(_ pct: Double) -> Int {
            let target = Int(countD * pct)
            var cum = 0
            for i in 0..<256 {
                cum += lumHist[i]
                if cum >= target { return i }
            }
            return 255
        }

        let p01  = percentile(0.01)   // black clip point (1%)
        let p05  = percentile(0.05)   // deep shadows
        let p25  = percentile(0.25)   // shadow quarter
        let p50  = percentile(0.50)   // median
        let p75  = percentile(0.75)   // highlight quarter
        let p95  = percentile(0.95)   // bright highlights
        let p99  = percentile(0.99)   // white clip point (1%)

        // Count pixels in tonal zones
        let shadowPixels = lumHist[0..<64].reduce(0, +)
        let highlightPixels = lumHist[192..<256].reduce(0, +)
        let shadowFrac = Double(shadowPixels) / countD
        let highlightFrac = Double(highlightPixels) / countD

        // --- Exposure: gentle nudge toward median ~128 ---
        let targetMedian: Double = 128
        let medianDelta = targetMedian - Double(p50)
        // Conservative: every 80 luminance units ≈ 1 EV (half as aggressive)
        let newExposure = max(-2.0, min(2.0, round((medianDelta / 80.0) * 20) / 20))

        // --- Contrast: gentle boost based on interquartile range ---
        let iqr = Double(p75 - p25)
        let targetIQR: Double = 80
        // Only boost contrast, don't reduce it (negative contrast looks bad)
        let contrastAdjust = max(0, (targetIQR - iqr) * 0.15)
        let newContrast = Int(min(25, contrastAdjust))

        // --- Highlights: only recover if genuinely clipped ---
        let newHighlights: Int
        if highlightFrac > 0.08 {
            // Significant clipping — gentle recovery
            let strength = min(1.0, (highlightFrac - 0.08) / 0.25)
            newHighlights = Int(max(-40, -strength * 30))
        } else {
            newHighlights = 0
        }

        // --- Shadows: only lift if truly crushed (>25% of pixels in deep shadows) ---
        let newShadows: Int
        if shadowFrac > 0.25 && p05 < 20 {
            // Only lift when shadows are genuinely crushed, not just dark subjects
            let strength = min(1.0, (shadowFrac - 0.25) / 0.3)
            newShadows = Int(min(25, strength * 20))
        } else {
            newShadows = 0
        }

        // --- Whites: target p99 around 240-250 ---
        let whiteDelta = 245.0 - Double(p99)
        let newWhites = Int(max(-20, min(30, whiteDelta * 0.3)))

        // --- Blacks: target p01 around 5-15 ---
        let blackDelta = 10.0 - Double(p01)
        let newBlacks = Int(max(-20, min(15, blackDelta * 0.3)))

        // Apply
        withAnimation(.easeOut(duration: 0.25)) {
            exposure = newExposure
            contrast = newContrast
            highlights = newHighlights
            shadows = newShadows
            whites = newWhites
            blacks = newBlacks
        }
        nudgePreview()
    }

    private func rebuildPreview() async {
        guard let cgSrc = previewBaseCG else { return }
        let capExp = exposure, capCon = contrast, capHi = highlights
        let capSh = shadows, capWh = whites, capBl = blacks, capSat = saturation
        let capVib = vibrance
        let capTemp = temperature, capTint = tint
        let capClarity = clarity, capDehaze = dehaze
        let capAdj = adj  // color grading / HSL / calibration
        let capCurvePoints = curvePoints
        let capMasks = maskLayers.filter { $0.isActive }

        let rendered = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            var ci = CIImage(cgImage: cgSrc)

            // 1. Temperature/Tint — first in chain for white balance
            ci = AdjustmentFilterPipeline.applyTemperatureTint(ci, temperature: capTemp, tint: capTint)

            // 2. Exposure
            if abs(capExp) > 0.01 {
                let f = CIFilter(name: "CIExposureAdjust")!
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(Float(capExp), forKey: "inputEV")
                if let out = f.outputImage { ci = out }
            }

            // 3. Contrast + Saturation
            let cF = Float(1.0 + Double(capCon) / 667.0)
            let sF = Float(max(0, 1.0 + Double(capSat) / 100.0))
            if abs(cF - 1) > 0.005 || abs(sF - 1) > 0.005 {
                let f = CIFilter(name: "CIColorControls")!
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(cF, forKey: kCIInputContrastKey)
                f.setValue(sF, forKey: kCIInputSaturationKey)
                if let out = f.outputImage { ci = out }
            }

            // 4. Vibrance — global (was missing before)
            if capVib != 0, let f = CIFilter(name: "CIVibrance") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(Float(capVib) / 100.0, forKey: "inputAmount")
                if let out = f.outputImage { ci = out }
            }

            // 5. Highlights/Shadows — luminance-preserving tone curve approach
            ci = AdjustmentFilterPipeline.applyHighlightsShadows(ci, highlights: capHi, shadows: capSh)

            // 6. Whites & Blacks — smoother non-linear tone curve
            ci = AdjustmentFilterPipeline.applyWhitesBlacks(ci, whites: capWh, blacks: capBl)

            // 7. Dehaze — shadow contrast + saturation boost
            ci = AdjustmentFilterPipeline.applyDehaze(ci, amount: capDehaze)

            // 8. Color Grading / HSL / Calibration — 3D LUT
            if !ColorGradingLUTBuilder.isIdentity(capAdj),
               let f = CIFilter(name: "CIColorCubeWithColorSpace"),
               let sRGB = CGColorSpace(name: CGColorSpace.sRGB) {
                let lutData = ColorGradingLUTBuilder.buildLUT(from: capAdj)
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(ColorGradingLUTBuilder.dimension, forKey: "inputCubeDimension")
                f.setValue(lutData as NSData, forKey: "inputCubeData")
                f.setValue(sRGB, forKey: "inputColorSpace")
                if let out = f.outputImage { ci = out }
            }

            // 9. Clarity — local contrast via large-radius unsharp mask
            ci = AdjustmentFilterPipeline.applyClarity(ci, amount: capClarity)

            // 10. Interactive tone curve
            if capCurvePoints.count >= 2 {
                ci = AdjustmentFilterPipeline.applyCurvePoints(ci, points: capCurvePoints)
            }

            // 11. Per-mask layer adjustments
            if !capMasks.isEmpty {
                ci = MaskRenderingService.applyAdjustmentLayers(capMasks, base: ci, sourceCG: cgSrc)
            }
            guard let cgOut = Self.ciContext.createCGImage(ci, from: ci.extent) else { return nil }
            return NSImage(cgImage: cgOut, size: NSSize(width: cgOut.width, height: cgOut.height))
        }.value
        if let rendered { previewImage = rendered }
    }

    // MARK: - Auto-Segment

    private func autoSegmentWithVision() async {
        guard let baseCG = previewBaseCG else { return }
        isAutoSegmenting = true
        do {
            let segments = try await Self.visionMaskService.generateSegments(from: baseCG)
            autoSegments = segments.filter { seg in !maskLayers.contains(where: { $0.label == seg.label }) }
        } catch { print("[DevelopView] Auto-segment failed: \(error)") }
        isAutoSegmenting = false
    }

    private func saveAdjustments() async {
        isSaving = true
        await persistToDB()

        // Auto-create a snapshot on every Apply so the history is populated
        if let db = appDatabase, let photo = currentPhoto {
            let adjustments = currentAdjustments()
            if let json = adjustments.encodeToJSON() {
                let masksStr = MaskLayerStore.encode(maskLayers)
                let snapshotId = UUID().uuidString

                // Render thumbnail from current preview
                let thumbPath: String? = await Task.detached(priority: .utility) {
                    guard let img = await MainActor.run(body: { self.previewImage ?? self.displayImage }) else { return nil as String? }
                    return SnapshotThumbnailService.renderThumbnail(from: img, snapshotId: snapshotId)
                }.value

                let snapshot = AdjustmentSnapshot(
                    id: snapshotId,
                    photoAssetId: photo.id,
                    label: nil,  // auto-snapshots get no label; user can rename later
                    adjustmentJSON: json,
                    masksJSON: masksStr,
                    thumbnailPath: thumbPath,
                    isCurrentState: true,
                    createdAt: Date()
                )
                let repo = AdjustmentSnapshotRepository(db: db)
                try? await repo.saveSnapshot(snapshot)
                await loadVersionSnapshots()
            }
        }

        isSaving = false
        withAnimation { saveMessage = "Adjustments saved" }
    }

    private func resetAll() {
        resetSliders(); maskLayers.removeAll(); selectedMaskId = nil
        autoSegments.removeAll(); showMaskOverlay = false; nudgePreview()
        Task { await persistToDB() }
    }

    private func resetSliders() {
        exposure = 0; contrast = 0; highlights = 0
        shadows = 0; whites = 0; blacks = 0; saturation = 0; vibrance = 0
        temperature = 0; tint = 0; clarity = 0; dehaze = 0
        curvePoints = []
        adj = PhotoAdjustments()
    }

    private var isIdentity: Bool {
        let t: Bool = exposure == 0 && contrast == 0 && highlights == 0
        let s: Bool = shadows == 0 && whites == 0 && blacks == 0
        let c: Bool = saturation == 0 && vibrance == 0
        let n: Bool = temperature == 0 && tint == 0 && clarity == 0 && dehaze == 0
        return t && s && c && n && curvePoints.isEmpty
    }

    // MARK: - Helpers

    private var globalSummary: String {
        var p: [String] = []
        if exposure != 0 { p.append("Exp \(String(format: "%+.1f", exposure))") }
        if contrast != 0 { p.append("Con \(contrast > 0 ? "+" : "")\(contrast)") }
        if saturation != 0 { p.append("Sat \(saturation > 0 ? "+" : "")\(saturation)") }
        return p.isEmpty ? "No changes" : p.joined(separator: "  ")
    }

    private func adjSummary(_ adj: PhotoAdjustments) -> String {
        var p: [String] = []
        if adj.exposure != 0 { p.append("Exp \(String(format: "%+.1f", adj.exposure))") }
        if adj.contrast != 0 { p.append("Con \(adj.contrast > 0 ? "+" : "")\(adj.contrast)") }
        return p.isEmpty ? "No changes" : p.joined(separator: "  ")
    }

    private func iconForMask(_ m: AdjustmentLayer) -> String {
        let l = m.label.lowercased()
        if l.contains("person") { return "person.fill" }
        if l.contains("face") { return "face.dashed" }
        if l.contains("background") { return "square.dashed" }
        return "circle.dashed"
    }

    @ViewBuilder
    private func maskLayerRow(icon: String, label: String, summary: String, isSelected: Bool,
                              isActive: Binding<Bool>, onSelect: @escaping () -> Void,
                              onDelete: (() -> Void)?) -> some View {
        let fg: Color = isSelected ? .white : .primary
        let bg: Color = isSelected ? .accentColor : .clear
        HStack(spacing: 0) {
            // Left selection indicator
            RoundedRectangle(cornerRadius: 1)
                .fill(isSelected ? Color.white.opacity(0.9) : Color.clear)
                .frame(width: 3)
                .padding(.vertical, 2)
            HStack(spacing: 8) {
                Image(systemName: icon).font(.caption).foregroundColor(isSelected ? .white : .secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.caption.weight(isSelected ? .semibold : .regular)).foregroundColor(fg)
                    if !summary.isEmpty {
                        Text(summary).font(.caption2).lineLimit(1).foregroundColor(isSelected ? .white.opacity(0.7) : .gray)
                    }
                }
                Spacer()
                if onDelete != nil {
                    Toggle("", isOn: isActive).toggleStyle(.switch).labelsHidden().controlSize(.mini)
                    Button { onDelete?() } label: {
                        Image(systemName: "xmark").font(.caption2).foregroundColor(.secondary)
                    }.buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 6)
        }
        .padding(.leading, 2).padding(.trailing, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(bg))
        .contentShape(Rectangle()).onTapGesture { onSelect() }
    }

    @ViewBuilder
    private func adjustmentCard(_ title: String, @ViewBuilder content: @escaping () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    @ViewBuilder
    private func adjustmentCardWithAction(_ title: String, action: @escaping () -> Void, @ViewBuilder content: @escaping () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Button(action: action) {
                    Text("Auto")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
            content()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func overlayButton(icon: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(disabled ? 0.3 : 0.85))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    private static let sliderHelpDescriptions: [String: String] = [
        "Exposure":   "Brightens or darkens the overall image in stops",
        "Contrast":   "Spreads highlights and shadows further apart for more punch",
        "Highlights": "Recovers or boosts the brightest tones",
        "Shadows":    "Lifts or deepens the darkest tones",
        "Whites":     "Sets the white point — clip at +100 to retain detail",
        "Blacks":     "Sets the black point — pull negative to deepen shadows",
        "Saturation": "Uniformly increases or decreases color intensity",
        "Vibrance":   "Boosts muted colors while protecting skin tones",
        "Hue":        "Rotates the color wheel angle for this tonal range",
        "Luminance":  "Brightens or darkens pixels in this tonal range",
        "Balance":    "Shifts the grading balance toward shadows or highlights",
        "Blending":   "Controls how aggressively the color grade blends into the image",
    ]

    private func adjustmentSlider(_ label: String, value: Binding<Double>,
                                  range: ClosedRange<Double>, step: Double = 1, format: String = "%.0f") -> some View {
        let currentVal = String(format: format, value.wrappedValue)
        let desc = Self.sliderHelpDescriptions[label] ?? label
        let helpText = "\(label): \(currentVal) — \(desc)"
        return HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 80, alignment: .leading).foregroundStyle(.secondary)
            Slider(value: value, in: range, step: step)
                .onChange(of: value.wrappedValue) { nudgePreview() }
                .help(helpText)
            Text(currentVal).font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
        }
    }

    private func intBinding(_ b: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(b.wrappedValue) }, set: { b.wrappedValue = Int($0) })
    }

    static func computeImageRect(imageSize: CGSize, containerSize: CGSize, padding: CGFloat) -> CGRect {
        let aW = containerSize.width - padding * 2, aH = containerSize.height - padding * 2
        guard aW > 0, aH > 0 else { return .zero }
        let s = min(aW / imageSize.width, aH / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        return CGRect(x: (containerSize.width - w) / 2, y: (containerSize.height - h) / 2, width: w, height: h)
    }

    nonisolated private static func scale(_ img: CGImage, maxEdge: Int) -> CGImage? {
        let w = img.width, h = img.height
        guard max(w, h) > maxEdge else { return img }
        let r = CGFloat(maxEdge) / CGFloat(max(w, h))
        let nW = Int(CGFloat(w) * r), nH = Int(CGFloat(h) * r)
        guard let ctx = CGContext(data: nil, width: nW, height: nH, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: nW, height: nH))
        return ctx.makeImage()
    }
}
