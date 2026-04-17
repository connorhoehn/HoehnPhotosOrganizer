import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

private let printTemplateDragUTI = UTType.json.identifier

// MARK: - PrintCanvasView

/// A Print-Tool–style canvas for positioning and printing digital negatives via QTR / macOS print dialog.
struct PrintCanvasView: View {

    @ObservedObject var viewModel: PrintLabViewModel

    // Legacy single-image init for backward compatibility during transition
    // (MainWorkspaceView still passes photoId — Plan 05 updates the call site)
    var photoId: String? = nil
    var photoImage: NSImage? = nil

    @Environment(\.appDatabase) private var appDatabase

    // MARK: Legacy single-image state (used by legacy image loading path only)
    @State private var selectedImageURL: URL? = nil
    @State private var sourceImage: NSImage? = nil
    @State private var isDroppingFile = false

    // MARK: Pinch-to-zoom
    @State private var pinchBaseMagnify: CGFloat = 1.0

    // MARK: Resize handle state
    @State private var isHoveringImage: Bool = false
    @State private var isHoveringHandle: Bool = false
    @State private var isDraggingImage: Bool = false
    @State private var activeHandle: HandlePos? = nil
    @State private var resizeStartRect: CGRect = .zero

    // MARK: Rubber-band selection
    @State private var rubberBandStart: CGPoint? = nil
    @State private var rubberBandEnd:   CGPoint? = nil
    // Per-image drag start positions (captured once per drag, avoids stale `ci` capture)
    @State private var dragStartPos:    CGPoint  = .zero

    private var rubberBandRect: CGRect? {
        guard let s = rubberBandStart, let e = rubberBandEnd else { return nil }
        return CGRect(x: min(s.x, e.x), y: min(s.y, e.y),
                      width: abs(e.x - s.x), height: abs(e.y - s.y))
    }

    // MARK: Drop feedback
    @State private var showUnsupportedDropAlert = false

    // MARK: Keyboard paste
    @State private var keyEventMonitor: Any? = nil

    // MARK: Neg Prefs
    @State private var showNegPrefs: Bool = false
    @State private var bgType: BGType     = .white
    @State private var borderSize: BorderSz = .none
    @State private var customBorderInches: CGFloat = 0.25

    // MARK: Constants
    private let rulerPx: CGFloat = 20
    private let ppi: CGFloat     = 72

    // MARK: Types
    enum BGType: String, CaseIterable, Identifiable {
        case white = "White"; case black = "Black"; case border = "Border"
        var id: String { rawValue }
    }
    enum BorderSz: String, CaseIterable, Identifiable {
        case none = "None"; case small = "Small"; case medium = "Medium"; case large = "Large"
        var id: String { rawValue }
        var inset: CGFloat { switch self { case .none: 0; case .small: 0.25; case .medium: 0.5; case .large: 0.75 } }
    }
    enum HandlePos: CaseIterable, Hashable {
        case tl, t, tr, r, br, b, bl, l
        var isCorner: Bool { [.tl, .tr, .br, .bl].contains(self) }
    }

    // MARK: Body
    var body: some View {
        HStack(spacing: 0) {
            canvasArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onDrop(of: [.fileURL, .json], isTargeted: $isDroppingFile) { providers in
                    guard let provider = providers.first else { return false }
                    // Template drag from left panel (JSON-encoded PrintTemplate)
                    if provider.hasItemConformingToTypeIdentifier(printTemplateDragUTI) {
                        provider.loadDataRepresentation(forTypeIdentifier: printTemplateDragUTI) { data, _ in
                            guard let data,
                                  let template = try? JSONDecoder().decode(PrintTemplate.self, from: data) else { return }
                            DispatchQueue.main.async {
                                let sourceImage = viewModel.selectedImage?.sourceImage
                                    ?? viewModel.canvasImages.first?.sourceImage
                                    ?? NSImage()
                                viewModel.applyTemplate(template, sourceImage: sourceImage)
                            }
                        }
                        return true
                    }
                    // File drop from Finder
                    provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                        guard let data = item as? Data,
                              let url  = URL(dataRepresentation: data, relativeTo: nil) else { return }
                        let ext = url.pathExtension.lowercased()
                        DispatchQueue.main.async {
                            if ["tif","tiff","png","jpg","jpeg"].contains(ext) {
                                self.selectedImageURL = url
                                self.loadImage(from: url)
                            } else {
                                self.showUnsupportedDropAlert = true
                            }
                        }
                    }
                    return true
                }
                .alert("Unsupported File Type",
                       isPresented: $showUnsupportedDropAlert) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Only TIFF, PNG, and JPEG files can be placed on the canvas.")
                }
        }
        .sheet(isPresented: $showNegPrefs) {
            NegPreferencesSheet(bgType: $bgType, borderSize: $borderSize, flipEmulsion: $viewModel.flipEmulsion)
        }
        .onChange(of: borderSize) { _, sz in
            if sz != .none { customBorderInches = sz.inset }
        }
        .onAppear {
            viewModel.loadPrinters()
            viewModel.loadICCProfiles()
            // ⌘V clipboard paste monitor
            keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.modifierFlags.contains(.command),
                   event.charactersIgnoringModifiers == "v",
                   let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
                    self.handleImagePaste(image)
                    return nil  // consume the event
                }
                return event
            }
            // Legacy single-image compatibility: if photoId/photoImage provided, add as first canvas image
            let imgToLoad: NSImage? = photoImage ?? {
                guard let pid = photoId else { return nil }
                let proxyURL = ProxyGenerationActor.proxiesDirectory()
                    .appendingPathComponent((pid as NSString).deletingPathExtension + ".jpg")
                return NSImage(contentsOf: proxyURL)
            }()
            if let img = imgToLoad, viewModel.canvasImages.isEmpty {
                sourceImage = img
                let rep    = img.representations.first
                let pw     = rep?.pixelsWide ?? 0
                let ph     = rep?.pixelsHigh ?? 0
                var initW  = viewModel.paperWidth  - viewModel.marginLeft - viewModel.marginRight
                var initH  = viewModel.paperHeight - viewModel.marginTop  - viewModel.marginBottom
                if pw > 0 && ph > 0 {
                    let w = CGFloat(pw) / 360.0
                    let h = CGFloat(ph) / 360.0
                    initW = min(w, initW)
                    initH = min(h, initH)
                }
                let canvasImg = CanvasImage(
                    sourceImage: img,
                    position: CGPoint(
                        x: (viewModel.paperWidth  - initW) / 2,
                        y: (viewModel.paperHeight - initH) / 2
                    ),
                    size: CGSize(width: initW, height: initH)
                )
                viewModel.addCanvasImage(canvasImg)
            }
        }
        .onDisappear {
            if let monitor = keyEventMonitor {
                NSEvent.removeMonitor(monitor)
                keyEventMonitor = nil
            }
        }
    }

    // MARK: - Canvas Area

    /// Extra pasteboard space around the paper so layers can be dragged off-paper
    /// and the user can scroll to see them.
    private let pasteboardMargin: CGFloat = 200

    private var canvasArea: some View {
        GeometryReader { geo in
            let canvasW  = geo.size.width  - rulerPx
            let canvasH  = geo.size.height - rulerPx
            let scale    = ppi * viewModel.magnify
            let displayW = viewModel.isPortrait
                ? min(viewModel.paperWidth, viewModel.paperHeight)
                : max(viewModel.paperWidth, viewModel.paperHeight)
            let displayH = viewModel.isPortrait
                ? max(viewModel.paperWidth, viewModel.paperHeight)
                : min(viewModel.paperWidth, viewModel.paperHeight)
            let paperW   = displayW * scale
            let paperH   = displayH * scale

            // The total pasteboard is the paper plus margin on each side.
            // If the viewport is larger than the pasteboard, center the paper.
            let pasteboardW = paperW + pasteboardMargin * 2
            let pasteboardH = paperH + pasteboardMargin * 2
            // Paper origin within the pasteboard content
            let originX = pasteboardMargin
            let originY = pasteboardMargin

            ZStack(alignment: .topLeading) {
                Color(nsColor: .windowBackgroundColor)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Color(nsColor: .controlBackgroundColor)
                            .frame(width: rulerPx, height: rulerPx)
                        topRuler(availableWidth: canvasW, paperOriginX: originX, scale: scale)
                    }
                    HStack(spacing: 0) {
                        leftRuler(availableHeight: canvasH, paperOriginY: originY, scale: scale)
                        ScrollViewReader { scrollProxy in
                            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                                paperCanvas(
                                    canvasSize: CGSize(width: canvasW, height: canvasH),
                                    paperOriginX: originX, paperOriginY: originY,
                                    paperW: paperW, paperH: paperH, scale: scale
                                )
                                .frame(
                                    width: max(canvasW, pasteboardW),
                                    height: max(canvasH, pasteboardH)
                                )
                                // Invisible anchor at the paper center for initial scroll
                                Color.clear
                                    .frame(width: 1, height: 1)
                                    .id("paperCenter")
                                    .position(
                                        x: originX + paperW / 2,
                                        y: originY + paperH / 2
                                    )
                            }
                            .clipped()
                            .gesture(
                                MagnifyGesture()
                                    .onChanged { value in
                                        viewModel.magnify = max(0.2, min(3.0, pinchBaseMagnify * value.magnification))
                                    }
                                    .onEnded { value in
                                        viewModel.magnify = max(0.2, min(3.0, pinchBaseMagnify * value.magnification))
                                        pinchBaseMagnify = viewModel.magnify
                                    }
                            )
                            .onAppear {
                                pinchBaseMagnify = viewModel.magnify
                                // Double-dispatch to ensure geometry has settled after layout
                                DispatchQueue.main.async {
                                    scrollProxy.scrollTo("paperCenter", anchor: .center)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        scrollProxy.scrollTo("paperCenter", anchor: .center)
                                    }
                                }
                            }
                            .onChange(of: viewModel.magnify) { newVal in
                                pinchBaseMagnify = newVal
                            }
                        }
                    }
                }

                // Zoom controls overlay — bottom-left, interactive
                zoomControlsOverlay(displayW: displayW, displayH: displayH, viewSize: geo.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, rulerPx + 2)
                    .padding(.bottom, 14)

                // Paper + image info overlay — bottom-right, non-interactive
                canvasInfoOverlay(displayW: displayW, displayH: displayH)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 14)
                    .padding(.bottom, 14)
                    .allowsHitTesting(false)

                // Rotation angle overlay — center, shown when selected image has non-zero rotation
                if let sel = viewModel.selectedImage, sel.rotation != 0 {
                    rotationAngleOverlay(rotation: sel.rotation)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, rulerPx + 8)
                        .allowsHitTesting(false)
                        .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                }
            }
        }
    }

    // MARK: Rulers

    private func topRuler(availableWidth: CGFloat, paperOriginX: CGFloat, scale: CGFloat) -> some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(Color(nsColor: .controlBackgroundColor)))
            var i = 0
            while CGFloat(i) * scale <= size.width + scale {
                let x = CGFloat(i) * scale
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: x, y: size.height - 7))
                    p.addLine(to: CGPoint(x: x, y: size.height))
                }, with: .color(.secondary), lineWidth: 0.5)
                ctx.draw(Text("\(i)").font(.system(size: 7)).foregroundColor(.secondary),
                         at: CGPoint(x: x + 2, y: 2), anchor: .topLeading)
                let hx = x + scale / 2
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: hx, y: size.height - 4))
                    p.addLine(to: CGPoint(x: hx, y: size.height))
                }, with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)
                i += 1
            }
            // Ruler markers: combined outer bounds of all canvas images (including border)
            if !viewModel.canvasImages.isEmpty {
                let imgs = viewModel.canvasImages
                let minX = imgs.map { $0.position.x + $0.dragOffset.width - $0.borderWidthInches }.min()!
                let maxX = imgs.map { $0.position.x + $0.dragOffset.width + $0.size.width + $0.borderWidthInches }.max()!
                let leftX  = paperOriginX + minX * scale
                let rightX = paperOriginX + maxX * scale
                for markerX in [leftX, rightX] {
                    let tri = Path { p in
                        p.move(to: CGPoint(x: markerX,     y: size.height))
                        p.addLine(to: CGPoint(x: markerX - 4, y: size.height - 8))
                        p.addLine(to: CGPoint(x: markerX + 4, y: size.height - 8))
                        p.closeSubpath()
                    }
                    ctx.fill(tri, with: .color(.orange))
                    ctx.stroke(Path { p in
                        p.move(to: CGPoint(x: markerX, y: 0))
                        p.addLine(to: CGPoint(x: markerX, y: size.height))
                    }, with: .color(.orange.opacity(0.35)), lineWidth: 0.5)
                }
            }
        }
        .frame(height: rulerPx)
    }

    private func leftRuler(availableHeight: CGFloat, paperOriginY: CGFloat, scale: CGFloat) -> some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(Color(nsColor: .controlBackgroundColor)))
            var i = 0
            while CGFloat(i) * scale <= size.height + scale {
                let y = CGFloat(i) * scale
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: size.width - 7, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                }, with: .color(.secondary), lineWidth: 0.5)
                ctx.draw(Text("\(i)").font(.system(size: 7)).foregroundColor(.secondary),
                         at: CGPoint(x: 2, y: y + 2), anchor: .topLeading)
                let hy = y + scale / 2
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: size.width - 4, y: hy))
                    p.addLine(to: CGPoint(x: size.width, y: hy))
                }, with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)
                i += 1
            }
            // Ruler markers: combined outer bounds of all canvas images (including border)
            if !viewModel.canvasImages.isEmpty {
                let imgs = viewModel.canvasImages
                let minY = imgs.map { $0.position.y + $0.dragOffset.height - $0.borderWidthInches }.min()!
                let maxY = imgs.map { $0.position.y + $0.dragOffset.height + $0.size.height + $0.borderWidthInches }.max()!
                let topY    = paperOriginY + minY * scale
                let bottomY = paperOriginY + maxY * scale
                for markerY in [topY, bottomY] {
                    let tri = Path { p in
                        p.move(to: CGPoint(x: size.width,     y: markerY))
                        p.addLine(to: CGPoint(x: size.width - 8, y: markerY - 4))
                        p.addLine(to: CGPoint(x: size.width - 8, y: markerY + 4))
                        p.closeSubpath()
                    }
                    ctx.fill(tri, with: .color(.orange))
                    ctx.stroke(Path { p in
                        p.move(to: CGPoint(x: 0, y: markerY))
                        p.addLine(to: CGPoint(x: size.width, y: markerY))
                    }, with: .color(.orange.opacity(0.35)), lineWidth: 0.5)
                }
            }
        }
        .frame(width: rulerPx)
    }

    // MARK: Canvas Info Overlay

    private func canvasInfoOverlay(displayW: CGFloat, displayH: CGFloat) -> some View {
        let paperName = paperSizeName(w: displayW, h: displayH)
        let sel = viewModel.selectedImage

        return VStack(alignment: .trailing, spacing: 4) {
            // Paper size row
            HStack(spacing: 6) {
                Text("Paper")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(sizeString(displayW, displayH) + (paperName.isEmpty ? "" : "  \(paperName)"))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
            }

            if let img = sel {
                Divider().frame(width: 140)

                // Image size row
                HStack(spacing: 6) {
                    Text("Layer")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(sizeString(img.size.width, img.size.height))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                }

                // Total with border (only when border is active)
                if img.borderWidthInches > 0 {
                    let totalW = img.size.width  + img.borderWidthInches * 2
                    let totalH = img.size.height + img.borderWidthInches * 2
                    HStack(spacing: 6) {
                        Text("+ Border")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(sizeString(totalW, totalH))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.90))
                .shadow(color: .black.opacity(0.20), radius: 6, y: 2)
        )
    }

    // MARK: Zoom Controls Overlay

    private func zoomControlsOverlay(displayW: CGFloat, displayH: CGFloat, viewSize: CGSize) -> some View {
        HStack(spacing: 4) {
            Button {
                viewModel.magnify = max(0.2, viewModel.magnify - 0.1)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Zoom out")

            Text("\(Int((viewModel.magnify * 100).rounded()))%")
                .font(.caption.monospaced())
                .frame(width: 40, alignment: .center)

            Button {
                viewModel.magnify = min(3.0, viewModel.magnify + 0.1)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Zoom in")

            Button {
                viewModel.magnify = 1.0
                pinchBaseMagnify = 1.0
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help("Reset zoom (⌘0)")
            .keyboardShortcut("0", modifiers: .command)

            Button {
                // Scale paper to fill the available canvas area (minus ruler) with a 10% margin
                let canvasW = viewSize.width  - rulerPx
                let canvasH = viewSize.height - rulerPx
                guard displayW > 0, displayH > 0, canvasW > 0, canvasH > 0 else { return }
                let paperPixelW = displayW * ppi
                let paperPixelH = displayH * ppi
                let fitX = canvasW / paperPixelW
                let fitY = canvasH / paperPixelH
                let newMagnify = min(fitX, fitY) * 0.9
                viewModel.magnify = max(0.2, min(3.0, newMagnify))
                pinchBaseMagnify = viewModel.magnify
            } label: {
                Image(systemName: "rectangle.arrowtriangle.2.inward")
            }
            .buttonStyle(.borderless)
            .help("Fit page to window")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .cornerRadius(8)
    }

    // MARK: Rotation Angle Overlay

    private func rotationAngleOverlay(rotation: Double) -> some View {
        Text("\(Int(rotation.truncatingRemainder(dividingBy: 360)))°")
            .font(.title3.monospaced())
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .cornerRadius(8)
    }

    private func sizeString(_ w: CGFloat, _ h: CGFloat) -> String {
        // Format whole numbers without decimals, fractions as clean decimals
        let fw = w == w.rounded() ? String(format: "%.0f", w) : String(format: "%g", w)
        let fh = h == h.rounded() ? String(format: "%.0f", h) : String(format: "%g", h)
        return "\(fw) × \(fh)\""
    }

    private func paperSizeName(w: CGFloat, h: CGFloat) -> String {
        let known: [(CGFloat, CGFloat, String)] = [
            (8.5, 11,   "Letter"),
            (11,  8.5,  "Letter"),
            (8.5, 14,   "Legal"),
            (11,  17,   "Tabloid"),
            (17,  11,   "Tabloid"),
            (13,  19,   "Super B"),
            (19,  13,   "Super B"),
            (17,  22,   "Arch C"),
            (22,  17,   "Arch C"),
        ]
        return known.first { abs(w - $0.0) < 0.1 && abs(h - $0.1) < 0.1 }?.2 ?? ""
    }

    // MARK: Paper Canvas

    private func paperCanvas(canvasSize: CGSize,
                              paperOriginX: CGFloat, paperOriginY: CGFloat,
                              paperW: CGFloat, paperH: CGFloat, scale: CGFloat) -> some View {
        // Selection ring for first / selected image (above clipped paper)
        let selectedImg = viewModel.canvasImages.first(where: { $0.id == viewModel.selectedImageID })
            ?? viewModel.canvasImages.first
        let showHandles = (isHoveringImage || isHoveringHandle || activeHandle != nil) && !isDraggingImage

        return ZStack(alignment: .topLeading) {
            Color(nsColor: .underPageBackgroundColor)
                .overlay(isDroppingFile ? Color.accentColor.opacity(0.1) : Color.clear)

            // Drop shadow
            Rectangle()
                .fill(Color.black.opacity(0.25))
                .frame(width: paperW, height: paperH)
                .offset(x: paperOriginX + 3, y: paperOriginY + 3)
                .blur(radius: 4)

            // Paper surface only — clipped to paper bounds
            ZStack(alignment: .topLeading) {
                paperSurface(paperW: paperW, paperH: paperH, scale: scale)
            }
            .frame(width: paperW, height: paperH)
            .clipped()
            .offset(x: paperOriginX, y: paperOriginY)

            // Image tiles — NOT clipped, allowing off-paper positioning
            Group {
                ForEach(viewModel.canvasImages.indices, id: \.self) { idx in
                    imageTile(img: $viewModel.canvasImages[idx], scale: scale,
                              paperOriginX: paperOriginX, paperOriginY: paperOriginY)
                }
            }
            .offset(x: paperOriginX, y: paperOriginY)

            // Selection ring + handles (above clip) for selected image
            if let si = selectedImg {
                let imgX = paperOriginX + (si.position.x + si.dragOffset.width)  * scale
                let imgY = paperOriginY + (si.position.y + si.dragOffset.height) * scale
                let imgW = si.size.width  * scale
                let imgH = si.size.height * scale
                let cx   = imgX + imgW / 2
                let cy   = imgY + imgH / 2

                Rectangle()
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                    .frame(width: imgW, height: imgH)
                    .rotationEffect(.degrees(si.rotation))
                    .position(x: cx, y: cy)
                    .opacity(showHandles ? 1 : 0)
                    .animation(.easeInOut(duration: 0.12), value: showHandles)

                ForEach(HandlePos.allCases, id: \.self) { handle in
                    let pt = handlePoint(handle, cx: cx, cy: cy, imgW: imgW, imgH: imgH, rotation: si.rotation)
                    let sz: CGFloat = handle.isCorner ? 12 : 9
                    Circle()
                        .fill(activeHandle == handle ? Color.accentColor : Color.white)
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                        .frame(width: sz, height: sz)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                        .position(x: pt.x, y: pt.y)
                        .opacity(showHandles ? 1 : 0)
                        .animation(.easeInOut(duration: 0.12), value: showHandles)
                        .onHover { isHoveringHandle = $0 }
                        .gesture(resizeGesture(handle, scale: scale))
                }

                // Border hover bar below image
                if showHandles {
                    borderHoverBar(imgX: imgX, imgY: imgY, imgW: imgW, imgH: imgH)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }

            // Rubber-band selection overlay
            if let rr = rubberBandRect, rr.width > 2 || rr.height > 2 {
                Rectangle()
                    .stroke(Color.accentColor.opacity(0.9), lineWidth: 1)
                    .background(Color.accentColor.opacity(0.07))
                    .frame(width: max(1, rr.width), height: max(1, rr.height))
                    .offset(x: rr.minX, y: rr.minY)
                    .allowsHitTesting(false)
            }
        }
        // Rubber-band: simultaneousGesture so it fires alongside per-tile gestures.
        .contentShape(Rectangle())   // make the entire ZStack hit-testable
        .simultaneousGesture(
            DragGesture(minimumDistance: 6)
                .onChanged { v in
                    guard !isDraggingImage, activeHandle == nil else {
                        rubberBandStart = nil; rubberBandEnd = nil; return
                    }
                    if rubberBandStart == nil {
                        let ptInPaper = CGPoint(
                            x: (v.startLocation.x - paperOriginX) / scale,
                            y: (v.startLocation.y - paperOriginY) / scale
                        )
                        let hitsImage = viewModel.canvasImages.contains { img in
                            CGRect(origin: img.position, size: img.size).contains(ptInPaper)
                        }
                        guard !hitsImage else { return }
                        rubberBandStart = v.startLocation
                    }
                    rubberBandEnd = v.location
                }
                .onEnded { _ in
                    defer { rubberBandStart = nil; rubberBandEnd = nil }
                    guard let rect = rubberBandRect,
                          rect.width > 6 || rect.height > 6 else { return }
                    let hits = viewModel.canvasImages.filter { img in
                        let r = CGRect(
                            x: paperOriginX + img.position.x * scale,
                            y: paperOriginY + img.position.y * scale,
                            width:  img.size.width  * scale,
                            height: img.size.height * scale
                        )
                        return r.intersects(rect)
                    }
                    viewModel.selectedImageID = hits.last?.id
                }
        )
    }

    // MARK: Paper Surface

    @ViewBuilder
    private func paperSurface(paperW: CGFloat, paperH: CGFloat, scale: CGFloat) -> some View {
        Rectangle()
            .fill(bgType == .black ? Color.black : Color.white)
            .frame(width: paperW, height: paperH)

        Canvas { ctx, sz in
            let minor = scale * 0.1
            let major = scale * 1.0
            for x in stride(from: 0.0, through: sz.width, by: minor) {
                let isMajor = x.truncatingRemainder(dividingBy: major) < 0.5
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: sz.height))
                }, with: .color((bgType == .black ? Color.white : Color.black)
                    .opacity(isMajor ? 0.12 : 0.05)),
                   lineWidth: isMajor ? 0.5 : 0.3)
            }
            for y in stride(from: 0.0, through: sz.height, by: minor) {
                let isMajor = y.truncatingRemainder(dividingBy: major) < 0.5
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: sz.width, y: y))
                }, with: .color((bgType == .black ? Color.white : Color.black)
                    .opacity(isMajor ? 0.12 : 0.05)),
                   lineWidth: isMajor ? 0.5 : 0.3)
            }
        }
        .frame(width: paperW, height: paperH)

        if bgType == .border {
            Rectangle()
                .strokeBorder(Color.black, lineWidth: max(1, customBorderInches * scale))
                .frame(width: paperW, height: paperH)
        }
    }

    // MARK: Image Tile (per-CanvasImage)

    @ViewBuilder
    private func imageTile(
        img: Binding<CanvasImage>,
        scale: CGFloat,
        paperOriginX: CGFloat,
        paperOriginY: CGFloat
    ) -> some View {
        let ci    = img.wrappedValue
        let tileX = (ci.position.x + ci.dragOffset.width)  * scale
        let tileY = (ci.position.y + ci.dragOffset.height) * scale
        let tileW = ci.size.width  * scale
        let tileH = ci.size.height * scale

        let renderedImg: NSImage = viewModel.isNegative
            ? (ci.sourceImage.invertedColors())
            : ci.sourceImage

        let borderPx = ci.borderWidthInches * scale
        let borderColor: Color = ci.borderIsWhite ? .white : .black
        let outerX = tileX - borderPx
        let outerY = tileY - borderPx

        Image(nsImage: renderedImg)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: max(1, tileW), height: max(1, tileH))
            .clipped()
            .padding(borderPx)
            .background(borderPx > 0 ? borderColor : Color.clear)
            .rotationEffect(.degrees(ci.rotation))
            .overlay(ci.tileLabel.map { label in
                VStack {
                    Spacer()
                    Text(label)
                        .font(.system(size: 8, weight: .medium))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.55))
                        .foregroundColor(.white)
                        .cornerRadius(3)
                        .padding(.bottom, 4)
                }
            })
            .offset(x: outerX, y: outerY)
            // Single gesture handles both click-to-select and drag-to-move.
            // minimumDistance: 0 ensures mouseDown immediately selects the image,
            // avoiding the macOS SwiftUI tap vs. drag recognition conflict.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if viewModel.selectedImageID != ci.id {
                            viewModel.selectedImageID = ci.id
                        }
                        // Always capture the current position at the start of each new drag.
                        // Using !isDraggingImage as the "first frame" sentinel avoids the
                        // snap-on-second-drag bug where a stale dragStartPos would be used.
                        if !isDraggingImage {
                            dragStartPos = img.wrappedValue.position
                        }
                        let moved = abs(value.translation.width) > 2 || abs(value.translation.height) > 2
                        if moved {
                            img.wrappedValue.dragOffset = CGSize(
                                width:  value.translation.width  / scale,
                                height: value.translation.height / scale
                            )
                            isDraggingImage = true
                        }
                    }
                    .onEnded { value in
                        guard isDraggingImage else { return }
                        let rawX = dragStartPos.x + value.translation.width  / scale
                        let rawY = dragStartPos.y + value.translation.height / scale
                        img.wrappedValue.position = CGPoint(x: rawX, y: rawY)
                        img.wrappedValue.dragOffset = .zero
                        isDraggingImage = false
                    }
            )
            .onHover { isHoveringImage = $0 }
    }

    // MARK: - Resize Handles

    /// Returns the screen position of a resize handle, accounting for image rotation.
    /// `cx/cy` is the image center in canvas coordinates.
    private func handlePoint(_ h: HandlePos, cx: CGFloat, cy: CGFloat,
                              imgW: CGFloat, imgH: CGFloat, rotation: Double) -> CGPoint {
        // Local offset from center before rotation
        let (dx, dy): (CGFloat, CGFloat)
        switch h {
        case .tl: (dx, dy) = (-imgW/2, -imgH/2)
        case .t:  (dx, dy) = (0,       -imgH/2)
        case .tr: (dx, dy) = ( imgW/2, -imgH/2)
        case .r:  (dx, dy) = ( imgW/2,  0)
        case .br: (dx, dy) = ( imgW/2,  imgH/2)
        case .b:  (dx, dy) = (0,        imgH/2)
        case .bl: (dx, dy) = (-imgW/2,  imgH/2)
        case .l:  (dx, dy) = (-imgW/2,  0)
        }
        // Rotate the local offset by the image rotation angle
        let rad = rotation * .pi / 180.0
        let cosA = CGFloat(cos(rad))
        let sinA = CGFloat(sin(rad))
        return CGPoint(
            x: cx + dx * cosA - dy * sinA,
            y: cy + dx * sinA + dy * cosA
        )
    }

    private func resizeGesture(_ handle: HandlePos, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard let selID = viewModel.selectedImageID,
                      let idx = viewModel.canvasImages.firstIndex(where: { $0.id == selID }) else { return }
                let ci = viewModel.canvasImages[idx]
                if activeHandle != handle {
                    activeHandle = handle
                    viewModel.recordSnapshot(label: "Resize")
                    resizeStartRect = CGRect(
                        x: ci.position.x, y: ci.position.y,
                        width: ci.size.width, height: ci.size.height
                    )
                }
                let dx = v.translation.width  / scale
                let dy = v.translation.height / scale
                let r  = resizeStartRect
                let mn: CGFloat = 0.25
                // Always maintain aspect ratio — only scale, never warp.
                let ar = r.height / r.width
                var newPos  = CGPoint(x: r.minX, y: r.minY)
                var newSize = CGSize(width: r.width, height: r.height)
                switch handle {
                case .br:   // anchor: top-left
                    let nw = max(mn, r.width + dx)
                    newSize = CGSize(width: nw, height: nw * ar)
                case .bl:   // anchor: top-right
                    let nw = max(mn, r.width - dx)
                    newPos.x = r.maxX - nw
                    newSize = CGSize(width: nw, height: nw * ar)
                case .tr:   // anchor: bottom-left
                    let nw = max(mn, r.width + dx)
                    let nh = nw * ar
                    newPos.y = r.maxY - nh
                    newSize = CGSize(width: nw, height: nh)
                case .tl:   // anchor: bottom-right
                    let nw = max(mn, r.width - dx)
                    let nh = nw * ar
                    newPos.x = r.maxX - nw
                    newPos.y = r.maxY - nh
                    newSize = CGSize(width: nw, height: nh)
                case .r:    // scale from right; center vertically
                    let nw = max(mn, r.width + dx)
                    let nh = nw * ar
                    newPos.y = r.midY - nh / 2
                    newSize = CGSize(width: nw, height: nh)
                case .l:    // scale from left; center vertically
                    let nw = max(mn, r.width - dx)
                    let nh = nw * ar
                    newPos.x = r.maxX - nw
                    newPos.y = r.midY - nh / 2
                    newSize = CGSize(width: nw, height: nh)
                case .b:    // scale from bottom; center horizontally
                    let nh = max(mn, r.height + dy)
                    let nw = nh / ar
                    newPos.x = r.midX - nw / 2
                    newSize = CGSize(width: nw, height: nh)
                case .t:    // scale from top; center horizontally
                    let nh = max(mn, r.height - dy)
                    let nw = nh / ar
                    newPos.x = r.midX - nw / 2
                    newPos.y = r.maxY - nh
                    newSize = CGSize(width: nw, height: nh)
                }
                viewModel.canvasImages[idx].position = newPos
                viewModel.canvasImages[idx].size     = newSize
            }
            .onEnded { _ in activeHandle = nil }
    }

    // MARK: - Border Hover Bar

    private func borderHoverBar(imgX: CGFloat, imgY: CGFloat, imgW: CGFloat, imgH: CGFloat) -> some View {
        let cx = imgX + imgW / 2
        let cy = imgY + imgH + 20

        return HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    bgType = bgType == .border ? .white : .border
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: bgType == .border ? "checkmark.square.fill" : "square.dashed")
                        .foregroundStyle(bgType == .border ? Color.accentColor : .secondary)
                    Text("Border")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(.plain)

            if bgType == .border {
                Rectangle().fill(.separator).frame(width: 1, height: 16)

                ForEach([BorderSz.small, .medium, .large], id: \.self) { sz in
                    let active = abs(customBorderInches - sz.inset) < 0.001
                    Button(sz.rawValue) {
                        borderSize = sz
                        customBorderInches = sz.inset
                    }
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(active
                        ? Color.accentColor.opacity(0.2)
                        : Color.secondary.opacity(0.1)))
                    .foregroundStyle(active ? Color.accentColor : .primary)
                    .buttonStyle(.plain)
                }

                Rectangle().fill(.separator).frame(width: 1, height: 16)

                HStack(spacing: 4) {
                    Button {
                        customBorderInches = max(0.0625, customBorderInches - 0.0625)
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 18, height: 18)
                            .background(RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.15)))
                    }
                    .buttonStyle(.plain)

                    Text(String(format: "%.3f\"", customBorderInches))
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: 44)
                        .multilineTextAlignment(.center)

                    Button {
                        customBorderInches = min(3.0, customBorderInches + 0.0625)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 18, height: 18)
                            .background(RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.22), radius: 8, y: 2)
        )
        .position(x: cx, y: cy)
    }

    // MARK: - Actions

    /// Paste an NSImage from the clipboard onto the canvas,
    /// using the same sizing logic as drag-drop / file load.
    func handleImagePaste(_ image: NSImage) {
        let rep = image.representations.first
        let pw = rep?.pixelsWide ?? 0
        let ph = rep?.pixelsHigh ?? 0
        var initW  = viewModel.paperWidth  - viewModel.marginLeft - viewModel.marginRight
        var initH  = viewModel.paperHeight - viewModel.marginTop  - viewModel.marginBottom
        var rotation: Double = 0
        if pw > 0 && ph > 0 {
            let w = CGFloat(pw) / 360.0
            let h = CGFloat(ph) / 360.0
            let isImgPortrait = ph > pw
            let (fw, fh) = isImgPortrait ? (h, w) : (w, h)
            initW = min(fw, initW)
            initH = min(fh, initH)
            if isImgPortrait { rotation = 90 }
        }
        let cascade = CGFloat(viewModel.canvasImages.count) * 0.3
        let canvasImg = CanvasImage(
            sourceImage: image,
            position: CGPoint(
                x: (viewModel.paperWidth  - initW) / 2 + cascade,
                y: (viewModel.paperHeight - initH) / 2 + cascade
            ),
            size: CGSize(width: initW, height: initH),
            rotation: rotation
        )
        viewModel.addCanvasImage(canvasImg)
    }

    private func loadImage(from url: URL) {
        guard let img = NSImage(contentsOf: url) else { return }
        sourceImage = img
        let rep = img.representations.first
        let pw = rep?.pixelsWide ?? 0
        let ph = rep?.pixelsHigh ?? 0
        var initW  = viewModel.paperWidth  - viewModel.marginLeft - viewModel.marginRight
        var initH  = viewModel.paperHeight - viewModel.marginTop  - viewModel.marginBottom
        var rotation: Double = 0
        if pw > 0 && ph > 0 {
            let w = CGFloat(pw) / 360.0
            let h = CGFloat(ph) / 360.0
            let isImgPortrait = ph > pw
            let (fw, fh) = isImgPortrait ? (h, w) : (w, h)
            initW = min(fw, initW)
            initH = min(fh, initH)
            if isImgPortrait { rotation = 90 }
        }
        // Cascade so new images don't stack perfectly on top of existing ones
        let cascade = CGFloat(viewModel.canvasImages.count) * 0.3
        let canvasImg = CanvasImage(
            sourceImage: img,
            position: CGPoint(
                x: (viewModel.paperWidth  - initW) / 2 + cascade,
                y: (viewModel.paperHeight - initH) / 2 + cascade
            ),
            size: CGSize(width: initW, height: initH),
            rotation: rotation
        )
        viewModel.addCanvasImage(canvasImg)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool { false }
}

// MARK: - CanvasPrintView

class CanvasPrintView: NSView {
    let image: NSImage
    let paperW, paperH: CGFloat
    let imgLeft, imgTop, imgW, imgH: CGFloat
    let rotation: Double
    let flipH: Bool
    let borderWidthInches: CGFloat
    let borderIsWhite: Bool

    init(image: NSImage,
         paperWidth: CGFloat, paperHeight: CGFloat,
         imgLeft: CGFloat, imgTop: CGFloat,
         imgWidth: CGFloat, imgHeight: CGFloat,
         rotation: Double, flipH: Bool,
         borderWidthInches: CGFloat = 0,
         borderIsWhite: Bool = false) {
        self.image  = image
        self.paperW = paperWidth;  self.paperH = paperHeight
        self.imgLeft = imgLeft;    self.imgTop  = imgTop
        self.imgW    = imgWidth;   self.imgH    = imgHeight
        self.rotation = rotation;  self.flipH   = flipH
        self.borderWidthInches = borderWidthInches
        self.borderIsWhite = borderIsWhite
        super.init(frame: NSRect(x: 0, y: 0,
                                 width:  paperWidth  * 72,
                                 height: paperHeight * 72))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let pts: CGFloat = 72
        let b = borderWidthInches * pts
        // imageRect = the image area (no border)
        let imageRect = NSRect(
            x:      imgLeft                 * pts,
            y:     (paperH - imgTop - imgH) * pts,
            width:  imgW                    * pts,
            height: imgH                    * pts
        )
        // outerRect expands outward by border on all sides
        let outerRect = NSRect(
            x:      imageRect.minX - b,
            y:      imageRect.minY - b,
            width:  imageRect.width  + b * 2,
            height: imageRect.height + b * 2
        )
        let cx = outerRect.midX, cy = outerRect.midY
        NSGraphicsContext.saveGraphicsState()
        let xfm = NSAffineTransform()
        if flipH {
            xfm.translateX(by: cx, yBy: cy)
            xfm.scaleX(by: -1, yBy: 1)
            xfm.translateX(by: -cx, yBy: -cy)
        }
        if rotation != 0 {
            xfm.translateX(by: cx, yBy: cy)
            xfm.rotate(byDegrees: CGFloat(-rotation))
            xfm.translateX(by: -cx, yBy: -cy)
        }
        xfm.concat()
        // Draw border region first (expands outside image), then image on top
        if borderWidthInches > 0 {
            (borderIsWhite ? NSColor.white : NSColor.black).setFill()
            outerRect.fill()
        }
        image.draw(in: imageRect, from: .zero, operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: 1)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        return bounds
    }
}

// MARK: - NegPreferencesSheet

struct NegPreferencesSheet: View {
    @Binding var bgType: PrintCanvasView.BGType
    @Binding var borderSize: PrintCanvasView.BorderSz
    @Binding var flipEmulsion: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(
                            colors: [.red,.orange,.yellow,.green,.blue,.purple],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 52, height: 52)
                    Text("PRINT\nTOOL")
                        .font(.system(size: 8, weight: .black)).foregroundColor(.white)
                        .multilineTextAlignment(.center)
                }
                VStack(alignment: .leading) {
                    Text("Print-Tool Preferences").font(.headline)
                    Text("Active for Digital Negatives").font(.subheadline).foregroundColor(.secondary)
                }
                Spacer()
            }
            Divider()
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Background Type").font(.system(size: 12, weight: .medium))
                    HStack(spacing: 10) {
                        ForEach(PrintCanvasView.BGType.allCases) { type in
                            VStack(spacing: 4) {
                                bgPreview(type)
                                Text(type.rawValue).font(.system(size: 10))
                            }
                            .onTapGesture { bgType = type }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Border Size").font(.system(size: 12, weight: .medium))
                    HStack(spacing: 10) {
                        ForEach(PrintCanvasView.BorderSz.allCases) { sz in
                            VStack(spacing: 4) {
                                borderPreview(sz)
                                Text(sz.rawValue).font(.system(size: 10))
                            }
                            .onTapGesture { borderSize = sz }
                        }
                    }
                }
            }
            HStack {
                Toggle("Flip for Emulsion Side  —  flip shows only on the print",
                       isOn: $flipEmulsion).font(.system(size: 11))
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 580)
    }

    @ViewBuilder
    private func bgPreview(_ type: PrintCanvasView.BGType) -> some View {
        let sel = type == bgType
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(sel ? Color.accentColor : Color.gray.opacity(0.35),
                              lineWidth: sel ? 2 : 1)
                .frame(width: 48, height: 48)
            switch type {
            case .white:
                Rectangle().fill(.white).frame(width: 40, height: 40)
                Rectangle().fill(.black.opacity(0.35)).frame(width: 22, height: 40).offset(x: 9)
            case .black:
                Rectangle().fill(.black).frame(width: 40, height: 40)
                Rectangle().fill(.white.opacity(0.35)).frame(width: 22, height: 40).offset(x: 9)
            case .border:
                Rectangle().fill(.white).frame(width: 40, height: 40)
                Rectangle().strokeBorder(.black, lineWidth: 3).frame(width: 40, height: 40)
                Rectangle().fill(.black.opacity(0.35)).frame(width: 18, height: 34).offset(x: 9)
            }
        }
    }

    @ViewBuilder
    private func borderPreview(_ sz: PrintCanvasView.BorderSz) -> some View {
        let sel = sz == borderSize
        let lw: CGFloat = sz == .none ? 0 : sz == .small ? 2 : sz == .medium ? 5 : 8
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(sel ? Color.accentColor : Color.gray.opacity(0.35),
                              lineWidth: sel ? 2 : 1)
                .frame(width: 48, height: 48)
            Rectangle().fill(.white).frame(width: 40, height: 40)
            if lw > 0 {
                Rectangle().fill(.black.opacity(0.35)).frame(width: 40 - lw * 2, height: 40 - lw * 2)
            } else {
                Rectangle().fill(.black.opacity(0.35)).frame(width: 40, height: 40)
            }
        }
    }
}

// MARK: - NSImage inversion

extension NSImage {
    func invertedColors() -> NSImage {
        guard let tiff = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return self }
        let ci = CIImage(bitmapImageRep: bitmap)
        let filter = CIFilter.colorInvert()
        filter.inputImage = ci
        guard let output = filter.outputImage else { return self }
        let rep = NSCIImageRep(ciImage: output)
        let result = NSImage(size: size)
        result.addRepresentation(rep)
        return result
    }
}


// MARK: - Preview

#Preview {
    PrintCanvasView(viewModel: PrintLabViewModel())
        .frame(width: 1100, height: 750)
}
