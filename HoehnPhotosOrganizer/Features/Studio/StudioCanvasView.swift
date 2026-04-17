import SwiftUI
import UniformTypeIdentifiers

// MARK: - StudioCanvasView

/// Main canvas: load/crop photo, select medium, adjust params, render, preview.
struct StudioCanvasView: View {

    @ObservedObject var viewModel: StudioViewModel
    let libraryPhotos: [PhotoAsset]

    @State private var showLibraryPicker = false
    @State private var isDragOver = false
    @State private var showPrintLabAlert = false

    // Before/After comparison
    @State private var showComparison = false
    @State private var sliderPosition: CGFloat = 0.5

    // Crop tool
    @State private var cropRect: CGRect = .zero
    @State private var isDraggingCrop = false

    // Paint by Numbers (post-process transform)
    @State private var pbnActive = false
    @StateObject private var pbnViewModel = PaintByNumbersViewModel()
    @State private var hoveredPBNRegionIndex: Int?
    @State private var pbnMousePosition: CGPoint = .zero

    // Advanced panel
    @State private var showAdvancedPanel = false

    // Right sidebar
    @StateObject private var presetManager = PresetManager()
    @State private var rightSidebarCollapsed = false
    @State private var assistantCollapsed = true
    @State private var presetsCollapsed = false
    @State private var assistantWidth: CGFloat = 280
    @State private var isDraggingAssistantHandle = false
    @State private var isHoveringAssistantHeader = false
    @State private var isHoveringPresetsHeader = false
    @State private var rightStripHovered = false

    // Undo history popover
    @State private var showUndoHistory = false

    var body: some View {
        ZStack {
            // Main workspace (hidden during onboarding)
            VStack(spacing: 0) {
                if viewModel.sourceImage != nil {
                    // Horizontal toolbar
                    StudioToolbar(viewModel: viewModel, showComparison: $showComparison, pbnActive: $pbnActive)
                    Divider()
                }

                // Canvas area with optional side panels (only when image loaded)
                if viewModel.sourceImage != nil {
                    HStack(spacing: 0) {
                        // Left panel: PBN settings when active, Studio advanced panel otherwise
                        if pbnActive {
                            PaintByNumbersView(viewModel: pbnViewModel, sourceMedium: viewModel.selectedMedium)
                                .frame(width: 220)
                        } else {
                            StudioAdvancedPanel(
                                viewModel: viewModel,
                                isExpanded: $showAdvancedPanel,
                                pbnActive: $pbnActive,
                                onOpenFile: { openFilePicker() },
                                onShowLibrary: { showLibraryPicker = true }
                            )
                        }

                        Divider()

                        // Center canvas
                        if pbnActive {
                            pbnCanvasArea
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            canvasArea
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }

                        Divider()

                        // Right: PBN region inspector or chat
                        if pbnActive {
                            PaintByNumbersRegionPanel(
                                regions: pbnViewModel.regions,
                                palette: pbnViewModel.config.palette,
                                selectedRegionIndex: $pbnViewModel.highlightedRegionIndex,
                                selectedRegionIndices: $pbnViewModel.selectedRegionIndices,
                                onToggleRegion: { index in
                                    pbnViewModel.toggleRegionSelection(index)
                                },
                                onColorChange: { index, color in
                                    pbnViewModel.updateRegionColor(regionIndex: index, color: color)
                                },
                                onExportMask: { index in
                                    pbnViewModel.highlightedRegionIndex = index
                                    pbnViewModel.exportImage(format: .regionMaskPNG)
                                },
                                onExportAllMasks: {
                                    pbnViewModel.exportImage(format: .fullKit)
                                },
                                onExportPalette: {
                                    pbnViewModel.exportImage(format: .paletteSwatch)
                                },
                                onExportFullKit: {
                                    pbnViewModel.exportImage(format: .fullKit)
                                }
                            )
                            .frame(width: 280)
                        } else {
                            studioAssistantWrapper
                        }
                    }
                }
            }

            // Onboarding overlay when no image loaded
            if viewModel.sourceImage == nil {
                StudioOnboardingView(
                    viewModel: viewModel,
                    libraryPhotos: libraryPhotos,
                    onSelectPhoto: { photo, image in
                        viewModel.loadFromLibrary(photo: photo, image: image)
                    }
                )
                .transition(.opacity)
            }
        }
        .background(
            Group {
                Button("") {
                    if viewModel.renderedImage != nil {
                        showComparison.toggle()
                    }
                }
                .keyboardShortcut("c", modifiers: [])
                .hidden()

                // Undo: Cmd+Z
                Button("") {
                    viewModel.commandStack.undo()
                }
                .keyboardShortcut("z", modifiers: [.command])
                .hidden()

                // Redo: Cmd+Shift+Z
                Button("") {
                    viewModel.commandStack.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .hidden()

                // Preview render: Cmd+R
                Button("") {
                    if !viewModel.isRendering, viewModel.sourceImage != nil {
                        viewModel.render()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .hidden()

                // Full render: Cmd+Shift+R
                Button("") {
                    if !viewModel.isFullRendering, viewModel.sourceImage != nil {
                        viewModel.renderFull()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .hidden()
            }
        )
        .sheet(isPresented: $showLibraryPicker) {
            StudioLibraryPickerSheet(photos: libraryPhotos) { photo, nsImage in
                viewModel.loadFromLibrary(photo: photo, image: nsImage)
                showComparison = false
            }
        }
        .onChange(of: viewModel.sourceImage == nil) { _, _ in
            if pbnActive {
                pbnViewModel.sourceImage = viewModel.renderedImage ?? viewModel.croppedImage ?? viewModel.sourceImage
            }
        }
        .onChange(of: pbnActive) { _, active in
            if active {
                // Feed rendered image (preferred) or source to PBN
                pbnViewModel.sourceImage = viewModel.renderedImage ?? viewModel.croppedImage ?? viewModel.sourceImage
                pbnViewModel.displayMode = .colorFill
            }
        }
        .onReceive(viewModel.$renderedImage) { newImage in
            guard newImage != nil else { return }
            // Invalidate overlay cache when source image changes.
            // Don't auto-regenerate — user toggles Numbers/Contours to trigger render.
            viewModel.invalidateOverlayCache()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openInStudio)) { notification in
            if let photo = notification.userInfo?["photo"] as? PhotoAsset {
                // Try full-res file, then proxy path, then proxy directory convention
                let candidates: [String?] = [
                    photo.filePath,
                    photo.proxyPath,
                    {
                        let baseName = (photo.canonicalName as NSString).deletingPathExtension
                        return ProxyGenerationActor.proxiesDirectory()
                            .appendingPathComponent(baseName + ".jpg").path
                    }()
                ]
                for path in candidates.compactMap({ $0 }) {
                    if let img = NSImage(contentsOfFile: path) {
                        viewModel.loadFromLibrary(photo: photo, image: img)
                        showComparison = false
                        return
                    }
                }
                print("[Studio] Could not load image for photo \(photo.id) — tried \(candidates.compactMap { $0 })")
            }
        }
    }

    // Old toolsPanel removed — replaced by StudioToolbar + StudioAdvancedPanel

    // MARK: - Center Canvas

    private var canvasArea: some View {
        ZStack {
            // Paper background based on selected medium
            viewModel.selectedMedium.paperColor
                .ignoresSafeArea()

            if let rendered = viewModel.renderedImage {
                // Rendered image (always shown when available)
                GeometryReader { geo in
                    let imageRect = fittedImageRect(
                        imageSize: rendered.size,
                        in: geo.size,
                        padding: 32
                    )

                    ZStack {
                        // Rendered image — always full
                        Image(nsImage: rendered)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: imageRect.width, height: imageRect.height)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

                        // Contour/number overlay — visibility controlled by toggles, not data
                        if (viewModel.showContours || viewModel.showNumbers),
                           let overlay = viewModel.overlayImage {
                            Image(nsImage: overlay)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: imageRect.width, height: imageRect.height)
                                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                                .opacity(0.7)
                                .allowsHitTesting(false)
                        }

                        // Before/After split overlay (constrained to image bounds)
                        if showComparison,
                           let sourceImg = viewModel.croppedImage ?? viewModel.sourceImage {
                            // Source image — clipped to left portion of image rect
                            Image(nsImage: sourceImg)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: imageRect.width, height: imageRect.height)
                                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                                .clipShape(
                                    HalfClip(fraction: sliderPosition, imageRect: imageRect, containerSize: geo.size)
                                )

                            // Divider line — constrained to image
                            let dividerX = imageRect.minX + imageRect.width * sliderPosition
                            Rectangle()
                                .fill(Color.white)
                                .frame(width: 2, height: imageRect.height)
                                .position(x: dividerX, y: geo.size.height / 2)
                                .shadow(color: .black.opacity(0.5), radius: 3)

                            // Drag handle
                            Circle()
                                .fill(Color.white)
                                .frame(width: 32, height: 32)
                                .overlay(
                                    Image(systemName: "arrow.left.and.right")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.black)
                                )
                                .shadow(color: .black.opacity(0.3), radius: 4)
                                .position(x: dividerX, y: geo.size.height / 2)
                                .gesture(
                                    DragGesture()
                                        .onChanged { value in
                                            // Constrain to image bounds
                                            let relX = (value.location.x - imageRect.minX) / imageRect.width
                                            sliderPosition = max(0.02, min(0.98, relX))
                                        }
                                )

                            // Labels
                            Text("BEFORE")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.5), in: Capsule())
                                .position(x: imageRect.minX + 40, y: imageRect.minY + 16)

                            Text("AFTER")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.5), in: Capsule())
                                .position(x: imageRect.maxX - 36, y: imageRect.minY + 16)
                        }

                        // Floating compare toggle button (bottom-right of image)
                        if viewModel.sourceImage != nil {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showComparison.toggle()
                                    if showComparison { sliderPosition = 0.5 }
                                }
                            } label: {
                                Image(systemName: showComparison
                                      ? "rectangle.lefthalf.inset.filled"
                                      : "rectangle.split.2x1")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white)
                                    .frame(width: 36, height: 36)
                                    .background(
                                        showComparison
                                            ? Color.accentColor
                                            : Color.black.opacity(0.5),
                                        in: RoundedRectangle(cornerRadius: 8)
                                    )
                                    .shadow(color: .black.opacity(0.3), radius: 4)
                            }
                            .buttonStyle(.plain)
                            .help("Compare before/after (C)")
                            .position(
                                x: imageRect.maxX - 24,
                                y: imageRect.maxY - 24
                            )
                        }
                    }
                }
            } else if let source = viewModel.croppedImage ?? viewModel.sourceImage {
                if viewModel.showingCropTool {
                    Image(nsImage: source)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(32)
                } else {
                    VStack(spacing: 12) {
                        Image(nsImage: source)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(32)
                            .opacity(0.5)

                        Text("Select a medium and tap Render")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                // Empty state / drop target
                VStack(spacing: 16) {
                    Image(systemName: "paintpalette")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("Drop a photo here to begin")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Or use Load Image / From Library in the tools panel")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }



            // Floating resolution indicator — bottom-right of canvas
            if viewModel.sourceImage != nil, !viewModel.showingCropTool {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        canvasResolutionPill
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 72) // above the render button
                }
                .allowsHitTesting(true)
            }

            // Floating render controls — bottom center of canvas
            if viewModel.sourceImage != nil, !viewModel.showingCropTool {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        Spacer()

                        if viewModel.isRendering {
                            // Preview rendering in progress -- show step name
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                                Text(viewModel.renderStepName.isEmpty ? "Rendering..." : viewModel.renderStepName)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white)
                                Button {
                                    viewModel.cancelRender()
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.6), in: Capsule())
                        } else {
                            // Render button
                            Button {
                                viewModel.render()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "paintbrush.pointed.fill")
                                        .font(.system(size: 12))
                                    Text("Render")
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("(\u{2318}R)")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.white.opacity(0.6))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                .background(Color.accentColor, in: Capsule())
                                .shadow(color: .accentColor.opacity(0.4), radius: 8)
                            }
                            .buttonStyle(.plain)
                        }

                        // Background full-render progress (shows alongside render button)
                        if viewModel.isFullRendering {
                            HStack(spacing: 6) {
                                ProgressView(value: viewModel.fullRenderProgress)
                                    .frame(width: 60)
                                    .tint(.white)
                                Text(viewModel.renderStepName.isEmpty
                                    ? "Full \(Int(viewModel.fullRenderProgress * 100))%"
                                    : "\(viewModel.renderStepName) \(Int(viewModel.fullRenderProgress * 100))%")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.white)
                                Button {
                                    viewModel.renderTask?.cancel()
                                    viewModel.isFullRendering = false
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.5), in: Capsule())
                        }

                        Spacer()
                    }
                    .padding(.bottom, 24)
                }
                .allowsHitTesting(true)
            }

            // Crop tool overlay — constrained to the displayed image area
            if viewModel.showingCropTool,
               let cropSource = viewModel.croppedImage ?? viewModel.sourceImage {
                GeometryReader { geo in
                    let imageRect = fittedImageRect(
                        imageSize: cropSource.size,
                        in: geo.size,
                        padding: 32
                    )
                    ZStack(alignment: .topLeading) {
                        // Dimmed overlay covering only the image area
                        Color.black.opacity(0.4)
                            .frame(width: imageRect.width, height: imageRect.height)
                            .mask(
                                Rectangle()
                                    .overlay(
                                        Rectangle()
                                            .frame(
                                                width: max(cropRect.width, 1),
                                                height: max(cropRect.height, 1)
                                            )
                                            .offset(
                                                x: cropRect.minX - imageRect.width / 2,
                                                y: cropRect.minY - imageRect.height / 2
                                            )
                                            .blendMode(.destinationOut)
                                    )
                            )
                            .offset(x: imageRect.minX, y: imageRect.minY)

                        // Crop border
                        Rectangle()
                            .strokeBorder(Color.white, lineWidth: 1)
                            .frame(
                                width: max(cropRect.width, 1),
                                height: max(cropRect.height, 1)
                            )
                            .position(
                                x: imageRect.minX + cropRect.midX,
                                y: imageRect.minY + cropRect.midY
                            )
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let startX = max(0, min(value.startLocation.x - imageRect.minX, imageRect.width))
                                let startY = max(0, min(value.startLocation.y - imageRect.minY, imageRect.height))
                                let curX = max(0, min(value.location.x - imageRect.minX, imageRect.width))
                                let curY = max(0, min(value.location.y - imageRect.minY, imageRect.height))
                                cropRect = CGRect(
                                    x: min(startX, curX),
                                    y: min(startY, curY),
                                    width: abs(curX - startX),
                                    height: abs(curY - startY)
                                )
                            }
                    )

                    // Apply/Cancel buttons below the image
                    HStack {
                        Button("Cancel") {
                            cropRect = .zero
                            viewModel.showingCropTool = false
                        }
                        .buttonStyle(.bordered)
                        Button("Apply Crop") {
                            applyCrop(imageDisplaySize: imageRect.size)
                            viewModel.showingCropTool = false
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(cropRect.width < 4 || cropRect.height < 4)
                    }
                    .position(
                        x: geo.size.width / 2,
                        y: imageRect.maxY + 24
                    )
                }
            }

            // Drag overlay
            if isDragOver {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.08)))
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.down.doc")
                                .font(.system(size: 36))
                                .foregroundStyle(Color.accentColor)
                            Text("Drop image")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        }
                    )
                    .padding(8)
            }

            // Rendering overlay
            if viewModel.isRendering {
                Color.black.opacity(0.3)
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("Rendering \(viewModel.selectedMedium.rawValue)...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $isDragOver) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Resolution Pill

    private var canvasResolutionPill: some View {
        HStack(spacing: 6) {
            // Source dimensions
            if let src = viewModel.sourceResolutionInfo {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(src.width)×\(src.height)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                    Text(String(format: "%.1f MP", src.megapixels))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }

                if src.isLowRes {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .help("Source under 1 MP — open the full-resolution file for better quality")
                }
            }

            // Preview / Full badge
            if let render = viewModel.renderResolutionInfo {
                Text(render.label)
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(
                            viewModel.isPreview
                                ? Color.orange.opacity(0.25)
                                : Color.green.opacity(0.25)
                        )
                    )
                    .foregroundStyle(viewModel.isPreview ? .orange : .green)
                    .help(viewModel.isPreview
                          ? "Preview (\(render.width)×\(render.height)) — \u{21E7}\u{2318}R for full"
                          : "Full resolution (\(render.width)×\(render.height))")
                    .onTapGesture {
                        if viewModel.isPreview, !viewModel.isFullRendering {
                            viewModel.renderFull()
                        }
                    }
            }

            // Full render progress
            if viewModel.isFullRendering {
                ProgressView(value: viewModel.fullRenderProgress)
                    .frame(width: 40)
                    .tint(.white)
                    .controlSize(.mini)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - PBN Canvas Area

    private var pbnCanvasArea: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
                .ignoresSafeArea()

            if let rendered = pbnViewModel.renderedImage {
                Image(nsImage: rendered)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(32)
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
            } else if let source = pbnViewModel.sourceImage {
                VStack(spacing: 12) {
                    Image(nsImage: source)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(32)
                        .opacity(0.5)
                    Text("Adjust settings and tap Render")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "number.square")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("No image loaded")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if pbnViewModel.isRendering {
                Color.black.opacity(0.3)
                VStack(spacing: 12) {
                    ProgressView(value: pbnViewModel.renderProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 200)
                        .tint(.white)
                    Text("\(Int(pbnViewModel.renderProgress * 100))%")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                    Text("Rendering Paint by Numbers...")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            // Top-left: Back button
            VStack {
                HStack {
                    Button {
                        pbnActive = false
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back to Gallery")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    Spacer()
                }
                Spacer()
            }

            // Bottom-left: Recipe legend overlay
            VStack {
                Spacer()
                HStack {
                    pbnLegendOverlay
                        .padding(12)
                    Spacer()
                }
            }

            // Hover recipe tooltip
            if let recipe = hoveredPBNRecipe {
                pbnHoverTooltip(for: recipe)
                    .position(pbnMousePosition.offsetBy(dx: 16, dy: -20))
                    .allowsHitTesting(false)
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                pbnMousePosition = location
                hoveredPBNRegionIndex = pbnRegionIndexAtPoint(location)
            case .ended:
                hoveredPBNRegionIndex = nil
            }
        }
    }

    // MARK: - PBN Legend Overlay

    private var pbnLegendOverlay: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 3) {
                Text("LEGEND")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)

                if let assignment = pbnViewModel.numberAssignment {
                    ForEach(assignment.legendEntries) { recipe in
                        HStack(spacing: 6) {
                            Text("\(recipe.displayNumber)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .frame(width: 20, alignment: .trailing)
                            Circle()
                                .fill(recipe.resultColor.color)
                                .frame(width: 12, height: 12)
                            if recipe.isPure {
                                Text(recipe.components[0].colorName)
                                    .font(.system(size: 9))
                                    .lineLimit(1)
                            } else {
                                Text(recipe.components.map { "\(Int($0.fraction * 100))% \(abbreviateColorName($0.colorName))" }.joined(separator: " + "))
                                    .font(.system(size: 8))
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 1)
                        .padding(.horizontal, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(hoveredPBNRegionIndex != nil && isRegionForRecipe(recipe) ? Color.accentColor.opacity(0.15) : Color.clear)
                        )
                    }
                } else {
                    // Fallback: simple palette list
                    ForEach(Array(pbnViewModel.config.palette.colors.enumerated()), id: \.offset) { idx, color in
                        HStack(spacing: 6) {
                            Text("\(idx + 1)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .frame(width: 20, alignment: .trailing)
                            Circle()
                                .fill(color.color)
                                .frame(width: 12, height: 12)
                            Text(color.name)
                                .font(.system(size: 9))
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(10)
        }
        .frame(maxWidth: 220, maxHeight: 300)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - PBN Hover Tooltip

    private func pbnHoverTooltip(for recipe: ColorMixRecipe) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(recipe.displayNumber)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                Circle()
                    .fill(recipe.resultColor.color)
                    .frame(width: 14, height: 14)
                    .overlay(
                        Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5)
                    )
            }

            if recipe.isPure {
                Text(recipe.components[0].colorName)
                    .font(.system(size: 10))
                    .foregroundStyle(.primary)
            } else {
                ForEach(Array(recipe.components.enumerated()), id: \.element.paletteIndex) { _, component in
                    HStack(spacing: 4) {
                        Text("\(Int(component.fraction * 100))%")
                            .font(.system(size: 9, design: .monospaced))
                            .frame(width: 28, alignment: .trailing)
                        Text(component.colorName)
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(.secondary)
                }
            }

            if let regionIdx = hoveredPBNRegionIndex,
               pbnViewModel.regions.indices.contains(regionIdx) {
                Text(String(format: "%.1f%% coverage", pbnViewModel.regions[regionIdx].coveragePercent))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - PBN Helpers

    /// Abbreviate a color name by taking the first letter of each word, uppercased.
    /// "Yellow Ochre" -> "YO", "Cadmium Red Pale" -> "CR" (first two words).
    private func abbreviateColorName(_ name: String) -> String {
        let words = name.split(separator: " ")
        if words.count <= 1 { return name }
        // Take initials of up to the first two significant words
        let initials = words.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }
        return initials.joined()
    }

    /// Check if the currently hovered region matches this recipe.
    private func isRegionForRecipe(_ recipe: ColorMixRecipe) -> Bool {
        guard let idx = hoveredPBNRegionIndex,
              pbnViewModel.regions.indices.contains(idx) else { return false }
        return pbnViewModel.regions[idx].recipe?.displayNumber == recipe.displayNumber
    }

    /// Look up the region index at a given point in the canvas using the regionIndexMap.
    private func pbnRegionIndexAtPoint(_ point: CGPoint) -> Int? {
        let w = pbnViewModel.regionMapWidth
        let h = pbnViewModel.regionMapHeight
        guard w > 0, h > 0, !pbnViewModel.regionIndexMap.isEmpty else { return nil }
        // The point is in the pbnCanvasArea coordinate space; we need to map to the region map.
        // This is approximate — would need the actual rendered image frame for pixel-perfect mapping.
        // For now, return nil (hover relies on region panel selection).
        return nil
    }

    private var hoveredPBNRecipe: ColorMixRecipe? {
        guard let idx = hoveredPBNRegionIndex else { return nil }
        return pbnViewModel.numberAssignment?.recipeByColorIndex[idx]
    }

    // MARK: - Right Chat Panel

    // MARK: - Assistant Wrapper (collapse + resize)

    private var studioAssistantWrapper: some View {
        HStack(spacing: 0) {
            // Toggle strip — collapses entire right sidebar
            rightSidebarToggleStrip

            if !rightSidebarCollapsed {
                // Drag handle
                Rectangle()
                    .fill(isDraggingAssistantHandle ? Color.accentColor.opacity(0.3) : Color.clear)
                    .frame(width: 5)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                isDraggingAssistantHandle = true
                                assistantWidth = max(220, min(500, assistantWidth - value.translation.width))
                            }
                            .onEnded { _ in isDraggingAssistantHandle = false }
                    )

                rightSidebarContent
                    .frame(width: assistantWidth)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: rightSidebarCollapsed)
        .animation(.easeInOut(duration: 0.15), value: presetsCollapsed)
        .animation(.easeInOut(duration: 0.15), value: assistantCollapsed)
    }

    // MARK: - Right Sidebar Toggle Strip

    private var rightSidebarToggleStrip: some View {
        Button {
            rightSidebarCollapsed.toggle()
        } label: {
            Image(systemName: rightSidebarCollapsed ? "chevron.left" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(rightStripHovered ? .primary : .secondary)
                .frame(maxWidth: 18, maxHeight: .infinity)
                .background(rightStripHovered ? Color.primary.opacity(0.08) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in rightStripHovered = hovering }
        .help(rightSidebarCollapsed ? "Expand panel" : "Collapse panel")
    }

    // MARK: - Right Sidebar Content (Presets + Assistant)

    private var rightSidebarContent: some View {
        VStack(spacing: 0) {
            // Quick Presets section — collapsible, fixed height
            rightSidebarSection(
                title: "Quick Presets",
                icon: "paintbrush.pointed",
                isCollapsed: $presetsCollapsed,
                isHovering: $isHoveringPresetsHeader
            ) {
                presetsContent
            }

            Divider()

            // Assistant section — collapsible, fills remaining space
            rightSidebarSection(
                title: "Assistant",
                icon: "bubble.left.and.bubble.right",
                isCollapsed: $assistantCollapsed,
                isHovering: $isHoveringAssistantHeader
            ) {
                assistantContent
            }
            .frame(maxHeight: .infinity)

            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Reusable collapsible section header + content for the right sidebar.
    private func rightSidebarSection<Content: View>(
        title: String,
        icon: String,
        isCollapsed: Binding<Bool>,
        isHovering: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            Button {
                isCollapsed.wrappedValue.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed.wrappedValue ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Image(systemName: icon)
                        .font(.system(size: 10))
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(isHovering.wrappedValue ? .primary : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor).opacity(isHovering.wrappedValue ? 1.0 : 0.7))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in isHovering.wrappedValue = hovering }

            if !isCollapsed.wrappedValue {
                Divider()
                content()
            }
        }
    }

    // MARK: - Presets Content

    private var presetsContent: some View {
        let presets = presetManager.presets(for: viewModel.selectedMedium)
        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(presets) { preset in
                    Button {
                        viewModel.updateParams(preset.params, commandName: "Apply \(preset.name) preset")
                    } label: {
                        HStack(spacing: 6) {
                            Text(preset.name)
                                .font(.system(size: 10))
                            Spacer()
                            if viewModel.mediumParams == preset.params {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(viewModel.mediumParams == preset.params
                                      ? Color.accentColor.opacity(0.08)
                                      : Color.primary.opacity(0.03))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .frame(maxHeight: 200)
    }

    // MARK: - Assistant Content

    private var assistantContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if viewModel.chatMessages.isEmpty {
                        chatEmptyState
                    }
                    ForEach(viewModel.chatMessages) { msg in
                        chatBubble(msg)
                    }
                    if viewModel.chatLoading {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.purple.opacity(0.15))
                                .frame(width: 24, height: 24)
                                .overlay(Image(systemName: "paintpalette").font(.system(size: 10)).foregroundStyle(.purple))
                            ProgressView()
                                .controlSize(.small)
                            Text("Thinking...")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
                .padding(12)
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Ask about mediums, techniques...", text: $viewModel.chatInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { sendChat() }
                Button { sendChat() } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.chatInput.isEmpty || viewModel.chatLoading)
            }
            .padding(10)
        }
    }

    private var chatEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "paintpalette")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Studio Assistant")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                chatSuggestion("\"make it look like a charcoal sketch\"")
                chatSuggestion("\"more texture, less detail\"")
                chatSuggestion("\"try trois crayon on warm paper\"")
                chatSuggestion("\"compare oil vs watercolor\"")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func chatSuggestion(_ text: String) -> some View {
        Button {
            viewModel.chatInput = text.replacingOccurrences(of: "\"", with: "")
            sendChat()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func chatBubble(_ msg: StudioChatMessage) -> some View {
        HStack(alignment: .top) {
            if msg.role == .assistant {
                Circle()
                    .fill(Color.purple.opacity(0.15))
                    .frame(width: 24, height: 24)
                    .overlay(Image(systemName: "paintpalette").font(.system(size: 10)).foregroundStyle(.purple))
            }
            Text(msg.text)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(msg.role == .user ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06))
                )
                .frame(maxWidth: .infinity, alignment: msg.role == .user ? .trailing : .leading)
            if msg.role == .user {
                Circle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 24, height: 24)
                    .overlay(Image(systemName: "person.fill").font(.system(size: 10)).foregroundStyle(.secondary))
            }
        }
    }

    // MARK: - Actions

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .tiff, .png, .bmp]
        panel.allowsMultipleSelection = false
        panel.message = "Select a photo for Studio"
        guard panel.runModal() == .OK, let url = panel.url,
              let img = NSImage(contentsOf: url) else { return }
        viewModel.sourcePhotoId = nil
        withAnimation(.easeOut(duration: 0.35)) {
            viewModel.sourceImage = img
        }
        viewModel.renderedImage = nil
        showComparison = false
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data = data as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          let img = NSImage(contentsOf: url) else { return }
                    DispatchQueue.main.async {
                        viewModel.sourcePhotoId = nil
                        withAnimation(.easeOut(duration: 0.35)) {
                            viewModel.sourceImage = img
                        }
                        viewModel.renderedImage = nil
                        showComparison = false
                    }
                }
                return true
            }
        }
        return false
    }

    private func sendChat() {
        let text = viewModel.chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !viewModel.chatLoading else { return }
        viewModel.chatInput = ""
        viewModel.sendChatMessage(text)
    }

    /// Compute the rect where an aspect-fit image is displayed inside a container with padding.
    private func fittedImageRect(imageSize: CGSize, in containerSize: CGSize, padding: CGFloat) -> CGRect {
        let availW = containerSize.width - padding * 2
        let availH = containerSize.height - padding * 2
        guard availW > 0, availH > 0, imageSize.width > 0, imageSize.height > 0 else {
            return .zero
        }
        let scale = min(availW / imageSize.width, availH / imageSize.height)
        let fitW = imageSize.width * scale
        let fitH = imageSize.height * scale
        let originX = padding + (availW - fitW) / 2
        let originY = padding + (availH - fitH) / 2
        return CGRect(x: originX, y: originY, width: fitW, height: fitH)
    }

    /// Apply crop using coordinates relative to the displayed image area.
    private func applyCrop(imageDisplaySize: CGSize) {
        guard let source = viewModel.croppedImage ?? viewModel.sourceImage else { return }
        let imgSize = source.size
        guard imageDisplaySize.width > 0, imageDisplaySize.height > 0 else { return }
        let scaleX = imgSize.width / imageDisplaySize.width
        let scaleY = imgSize.height / imageDisplaySize.height
        let pixelRect = CGRect(
            x: cropRect.minX * scaleX,
            y: cropRect.minY * scaleY,
            width: cropRect.width * scaleX,
            height: cropRect.height * scaleY
        )
        if let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let cropped = cgImage.cropping(to: pixelRect) {
            viewModel.croppedImage = NSImage(cgImage: cropped, size: pixelRect.size)
        }
        cropRect = .zero
    }
}

// MARK: - ParamSliderRow

/// A slider row that tracks drag start/end to commit undoable parameter changes.
/// During dragging, the value updates live for responsiveness.
/// On drag end, a single undoable command captures the before/after values.
private struct ParamSliderRow: View {
    let label: String
    /// The current external value (from the view model).
    let externalValue: Double
    let range: ClosedRange<Double>
    let onDragging: (Double) -> Void
    let onCommit: (_ oldValue: Double, _ newValue: Double) -> Void

    @State private var liveValue: Double
    @State private var dragStartValue: Double
    @State private var isDragging: Bool = false

    init(label: String, value: Double, range: ClosedRange<Double>,
         onDragging: @escaping (Double) -> Void,
         onCommit: @escaping (_ oldValue: Double, _ newValue: Double) -> Void) {
        self.label = label
        self.externalValue = value
        self._liveValue = State(initialValue: value)
        self._dragStartValue = State(initialValue: value)
        self.range = range
        self.onDragging = onDragging
        self.onCommit = onCommit
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .frame(width: 65, alignment: .trailing)
            Slider(value: $liveValue, in: range) { editing in
                if editing {
                    isDragging = true
                    dragStartValue = liveValue
                } else {
                    isDragging = false
                    onCommit(dragStartValue, liveValue)
                }
            }
            .controlSize(.small)
            Text(String(format: "%.1f", liveValue))
                .font(.system(size: 9, design: .monospaced))
                .frame(width: 28)
        }
        .onChange(of: liveValue) { _, newValue in
            if isDragging {
                onDragging(newValue)
            }
        }
        // Sync external value back when it changes (undo/redo, medium switch)
        .onChange(of: externalValue) { _, newExternal in
            if !isDragging {
                liveValue = newExternal
            }
        }
    }
}

// MARK: - StudioLibraryPickerSheet

/// Single-select photo picker for loading a library photo into the Studio canvas.
private struct StudioLibraryPickerSheet: View {

    let photos: [PhotoAsset]
    let onSelect: (PhotoAsset, NSImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText: String = ""

    private var filteredPhotos: [PhotoAsset] {
        guard !searchText.isEmpty else { return photos }
        return photos.filter {
            $0.canonicalName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search by filename", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                if filteredPhotos.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 40))
                            .foregroundStyle(.tertiary)
                        Text(photos.isEmpty ? "No photos in library." : "No results.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4),
                            spacing: 4
                        ) {
                            ForEach(filteredPhotos) { photo in
                                let available = StudioPickerCell.isAvailable(photo)
                                StudioPickerCell(photo: photo)
                                    .overlay(
                                        Group {
                                            if !available {
                                                ZStack {
                                                    Color.black.opacity(0.45)
                                                    Image(systemName: "externaldrive.badge.xmark")
                                                        .font(.system(size: 16))
                                                        .foregroundStyle(.white.opacity(0.7))
                                                }
                                                .cornerRadius(4)
                                            }
                                        }
                                    )
                                    .help(available ? photo.canonicalName : "Source drive not connected")
                                    .onTapGesture {
                                        if available { selectPhoto(photo) }
                                    }
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .navigationTitle("Choose from Library")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 500)
    }

    private func selectPhoto(_ photo: PhotoAsset) {
        // Try full-resolution file first, fall back to proxy
        if let img = NSImage(contentsOfFile: photo.filePath) {
            onSelect(photo, img)
            dismiss()
        } else if let proxyPath = photo.proxyPath, let img = NSImage(contentsOfFile: proxyPath) {
            onSelect(photo, img)
            dismiss()
        } else {
            // Try proxy via standard directory convention
            let baseName = (photo.canonicalName as NSString).deletingPathExtension
            let proxyURL = ProxyGenerationActor.proxiesDirectory()
                .appendingPathComponent(baseName + ".jpg")
            if let img = NSImage(contentsOf: proxyURL) {
                onSelect(photo, img)
                dismiss()
            }
        }
    }
}

// MARK: - StudioPickerCell

private struct StudioPickerCell: View {
    let photo: PhotoAsset

    static func isAvailable(_ photo: PhotoAsset) -> Bool {
        if FileManager.default.fileExists(atPath: photo.filePath) { return true }
        if let pp = photo.proxyPath, FileManager.default.fileExists(atPath: pp) { return true }
        let baseName = (photo.canonicalName as NSString).deletingPathExtension
        let proxyURL = ProxyGenerationActor.proxiesDirectory()
            .appendingPathComponent(baseName + ".jpg")
        return FileManager.default.fileExists(atPath: proxyURL.path)
    }

    private var proxyImage: NSImage? {
        if let pp = photo.proxyPath, let img = NSImage(contentsOfFile: pp) {
            return img
        }
        let baseName = (photo.canonicalName as NSString).deletingPathExtension
        let proxyURL = ProxyGenerationActor.proxiesDirectory()
            .appendingPathComponent(baseName + ".jpg")
        return NSImage(contentsOf: proxyURL)
    }

    var body: some View {
        Group {
            if let img = proxyImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(nsColor: .separatorColor)
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                    )
            }
        }
        .frame(width: 130, height: 110)
        .clipped()
        .cornerRadius(4)
        .contentShape(Rectangle())
    }
}

// MARK: - HalfClip Shape (for compare overlay)

/// Clips to the left portion of the image rect within a container.
struct HalfClip: Shape {
    var fraction: CGFloat
    var imageRect: CGRect
    var containerSize: CGSize

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        // Clip from left edge of image to fraction point
        let clipX = imageRect.minX + imageRect.width * fraction
        return Path(CGRect(
            x: imageRect.minX,
            y: imageRect.minY,
            width: clipX - imageRect.minX,
            height: imageRect.height
        ))
    }
}

// MARK: - CGPoint Offset Helper

private extension CGPoint {
    func offsetBy(dx: CGFloat, dy: CGFloat) -> CGPoint {
        CGPoint(x: x + dx, y: y + dy)
    }
}
