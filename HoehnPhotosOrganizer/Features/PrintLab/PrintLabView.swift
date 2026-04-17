import SwiftUI
import AppKit

// MARK: - PrintLabView

/// Top-level Print Lab host. Owns PrintLabViewModel and lays out:
/// [Toolbar] / [Left Panel 220pt] | [Canvas flex] | [Right Panel 240pt]
struct PrintLabView: View {

    @ObservedObject var viewModel: PrintLabViewModel
    let libraryPhotos: [PhotoAsset]   // from LibraryViewModel.photos

    @Environment(\.appDatabase) private var appDatabase
    @Environment(\.activityEventService) private var activityEventService

    @State private var showingLibraryPicker = false

    private let ppi: CGFloat = 72

    var body: some View {
        VStack(spacing: 0) {
            printLabToolbar
            Divider()
            HStack(spacing: 0) {
                // Left panel: image list + templates
                PrintLabLeftPanel(viewModel: viewModel, libraryPhotos: libraryPhotos)

                Divider()

                // Canvas: center, takes all remaining space
                PrintCanvasView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                // Right panel: technical settings, all collapsed by default
                PrintLabRightPanel(viewModel: viewModel, onPageSetup: pageSetup)
            }
        }
        .background {
            // Keyboard shortcuts — hidden buttons
            Button("") { runPrint() }
                .keyboardShortcut("p", modifiers: .command)
                .hidden()
            Button("") { rotateCW() }
                .keyboardShortcut("r", modifiers: .command)
                .hidden()
            Button("") { centerImage() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .hidden()
        }
        .sheet(isPresented: $viewModel.showingSoftProof) {
            let source = viewModel.canvasImages
                .first(where: { $0.id == viewModel.selectedImageID })?.sourceImage
                ?? viewModel.canvasImages.first?.sourceImage
                ?? NSImage()
            SoftProofPanel(viewModel: viewModel, sourceImage: source)
        }
        .sheet(isPresented: $showingLibraryPicker) {
            LibraryPickerSheet(photos: libraryPhotos) { selected in
                let baseCount = viewModel.canvasImages.count
                for (i, photo) in selected.enumerated() {
                    let cascade = CGFloat(baseCount + i) * 0.3
                    let baseName = (photo.canonicalName as NSString).deletingPathExtension
                    let proxyURL = ProxyGenerationActor.proxiesDirectory()
                        .appendingPathComponent(baseName + ".jpg")
                    let img: NSImage = NSImage(contentsOf: proxyURL) ?? NSImage()
                    let canvasImg = CanvasImage(
                        photoAsset: photo,
                        sourceImage: img,
                        position: CGPoint(
                            x: viewModel.marginLeft + cascade,
                            y: viewModel.marginTop  + cascade
                        ),
                        size: CGSize(
                            width:  viewModel.paperWidth  - viewModel.marginLeft - viewModel.marginRight,
                            height: viewModel.paperHeight - viewModel.marginTop  - viewModel.marginBottom
                        )
                    )
                    viewModel.addCanvasImage(canvasImg)
                }
            }
        }
    }

    // MARK: - Print Lab Toolbar

    private var printLabToolbar: some View {
        HStack(spacing: 0) {

            // Add from Library
            PrintLabToolbarButton(icon: "plus.circle", label: "Add", help: "Add image from library") {
                showingLibraryPicker = true
            }

            // Paste from Clipboard
            PrintLabToolbarButton(
                icon: "doc.on.clipboard",
                label: "Paste",
                help: "Paste image from clipboard (⌘V)",
                enabled: NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
            ) { pasteImageFromClipboard() }

            toolbarDivider

            // Arrange group
            PrintLabToolbarButton(
                icon: "arrow.up.and.down.and.arrow.left.and.right",
                label: "Center",
                help: "Center on paper",
                enabled: viewModel.selectedImage != nil
            ) { centerImage() }

            PrintLabToolbarButton(
                icon: "arrow.left.and.right",
                label: "Ctr H",
                help: "Center horizontally",
                enabled: viewModel.selectedImage != nil
            ) { centerImageH() }

            PrintLabToolbarButton(
                icon: "arrow.up.and.down",
                label: "Ctr V",
                help: "Center vertically",
                enabled: viewModel.selectedImage != nil
            ) { centerImageV() }

            PrintLabToolbarButton(
                icon: "arrow.up.left.and.arrow.down.right",
                label: "Fit",
                help: "Fit image to printable area",
                enabled: viewModel.selectedImage != nil
            ) { fitImageToPage() }

            PrintLabToolbarButton(
                icon: "square.grid.2x2",
                label: "Arrange",
                help: "Distribute images evenly across the canvas",
                enabled: viewModel.canvasImages.count >= 2
            ) { viewModel.autoArrangeImages() }

            toolbarDivider

            // Transform group
            PrintLabToolbarButton(
                icon: "rotate.left",
                label: "CCW",
                help: "Rotate 90° counter-clockwise",
                enabled: viewModel.selectedImage != nil
            ) { rotateCCW() }

            PrintLabToolbarButton(
                icon: "rotate.right",
                label: "CW",
                help: "Rotate 90° clockwise",
                enabled: viewModel.selectedImage != nil
            ) { rotateCW() }

            PrintLabToolbarButton(
                icon: viewModel.flipEmulsion ? "arrow.left.and.right.square.fill" : "arrow.left.and.right.square",
                label: "Flip",
                help: "Flip emulsion (alt-process digital negatives)",
                isActive: viewModel.flipEmulsion
            ) { viewModel.flipEmulsion.toggle() }

            toolbarDivider

            // Zoom group
            PrintLabToolbarButton(
                icon: "minus.magnifyingglass",
                label: "Zoom −",
                help: "Zoom canvas out  ⌘−"
            ) { viewModel.magnify = max(0.2, viewModel.magnify - 0.1) }
            .keyboardShortcut("-", modifiers: .command)

            PrintLabToolbarButton(
                icon: "plus.magnifyingglass",
                label: "Zoom +",
                help: "Zoom canvas in  ⌘+"
            ) { viewModel.magnify = min(2.0, viewModel.magnify + 0.1) }
            .keyboardShortcut("=", modifiers: .command)

            toolbarDivider

            // Template Presets
            Menu {
                Section("Portrait") {
                    Button("4×6 (10×15cm)")    { applyTemplate(width: 4,    height: 6) }
                    Button("5×7 (13×18cm)")    { applyTemplate(width: 5,    height: 7) }
                    Button("8×10 (20×25cm)")   { applyTemplate(width: 8,    height: 10) }
                    Button("8.5×11 Letter")    { applyTemplate(width: 8.5,  height: 11) }
                    Button("A4 (8.27×11.69\")") { applyTemplate(width: 8.27, height: 11.69) }
                }
                Section("Square") {
                    Button("4×4")   { applyTemplate(width: 4,  height: 4) }
                    Button("8×8")   { applyTemplate(width: 8,  height: 8) }
                    Button("12×12") { applyTemplate(width: 12, height: 12) }
                }
                Section("Landscape") {
                    Button("6×4")  { applyTemplate(width: 6,  height: 4) }
                    Button("7×5")  { applyTemplate(width: 7,  height: 5) }
                    Button("10×8") { applyTemplate(width: 10, height: 8) }
                }
                Section("Contact Sheet") {
                    Menu("Contact Sheet") {
                        Button("2×3 (6 images)")   { applyContactSheet(cols: 2, rows: 3) }
                        Button("3×4 (12 images)")  { applyContactSheet(cols: 3, rows: 4) }
                        Button("4×5 (20 images)")  { applyContactSheet(cols: 4, rows: 5) }
                        Button("5×7 (35 images)")  { applyContactSheet(cols: 5, rows: 7) }
                    }
                }
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "doc.text.image")
                        .font(.system(size: 14, weight: .medium))
                    Text("Templates")
                        .font(.system(size: 9))
                }
                .foregroundStyle(Color.primary)
                .frame(width: 60, height: 38)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .frame(width: 60)
            .help("Apply a standard print size template")

            toolbarDivider

            // Soft Proof
            PrintLabToolbarButton(
                icon: "eye.fill",
                label: "Soft Proof",
                help: "Preview image through printer ICC profile",
                isActive: viewModel.softProofProfileURL != nil,
                enabled: !viewModel.canvasImages.isEmpty
            ) { viewModel.showingSoftProof = true }

            // Border group — only visible when the selected image has a border applied
            if viewModel.selectedImage?.borderWidthInches ?? 0 > 0 {
                toolbarDivider
                borderToolbarSection
                toolbarDivider
            }

            // Canvas orientation
            Picker("", selection: $viewModel.isPortrait) {
                Image(systemName: "rectangle.portrait").tag(true)
                Image(systemName: "rectangle").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 60)
            .padding(.horizontal, 6)
            .help("Toggle portrait / landscape")
            .onChange(of: viewModel.isPortrait) { _ in
                viewModel.refitImagesToCanvas()
            }

            toolbarDivider

            // Page Setup
            PrintLabToolbarButton(
                icon: "gearshape",
                label: "Page",
                help: "Configure page size and printer"
            ) { pageSetup() }

            // Clear Canvas
            PrintLabToolbarButton(
                icon: "trash",
                label: "Clear",
                help: "Remove all images from canvas",
                enabled: !viewModel.canvasImages.isEmpty
            ) { viewModel.canvasImages.removeAll() }

            Divider().frame(height: 20)

            // Run Print — primary action
            Button {
                runPrint()
            } label: {
                Label("Run Print", systemImage: "printer.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.canvasImages.isEmpty)

            // Hidden keyboard shortcut buttons
            Group {
                Button("Delete Selected") { deleteSelected() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .hidden()
                Button("Select All") { selectAll() }
                    .keyboardShortcut("a", modifiers: .command)
                    .hidden()
                Button("Undo") { viewModel.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!viewModel.canUndo)
                    .hidden()
            }
        }
        .padding(.leading, 8)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var toolbarDivider: some View {
        Divider()
            .frame(height: 28)
            .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var borderToolbarSection: some View {
        if let img = viewModel.selectedImage {
            HStack(spacing: 2) {
                // Label
                VStack(spacing: 2) {
                    Image(systemName: "square.filled.on.square")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Text("Border")
                        .font(.system(size: 9))
                }
                .frame(width: 44, height: 38)

                // −
                Button {
                    guard var updated = viewModel.selectedImage else { return }
                    viewModel.recordSnapshot(label: "Border −")
                    updated.borderWidthInches = max(0.0625, updated.borderWidthInches - 0.0625)
                    viewModel.updateCanvasImage(updated)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.15)))
                }
                .buttonStyle(.plain)

                // Width + total output size
                VStack(spacing: 1) {
                    Text(String(format: "%.3f\"", img.borderWidthInches))
                        .font(.system(size: 9, design: .monospaced))
                        .frame(width: 46)
                        .multilineTextAlignment(.center)
                    Text(String(format: "%.2f×%.2f\"",
                                img.size.width  + img.borderWidthInches * 2,
                                img.size.height + img.borderWidthInches * 2))
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .frame(width: 68)
                }

                // +
                Button {
                    guard var updated = viewModel.selectedImage else { return }
                    viewModel.recordSnapshot(label: "Border +")
                    updated.borderWidthInches = min(3.0, updated.borderWidthInches + 0.0625)
                    viewModel.updateCanvasImage(updated)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.15)))
                }
                .buttonStyle(.plain)

                // Color: black / white
                Divider().frame(height: 20).padding(.horizontal, 3)

                Button {
                    guard var updated = viewModel.selectedImage else { return }
                    updated.borderIsWhite = false
                    viewModel.updateCanvasImage(updated)
                } label: {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.black)
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .stroke(!img.borderIsWhite ? Color.accentColor : Color.clear, lineWidth: 2))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Black border")

                Button {
                    guard var updated = viewModel.selectedImage else { return }
                    updated.borderIsWhite = true
                    viewModel.updateCanvasImage(updated)
                } label: {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white)
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .stroke(img.borderIsWhite ? Color.accentColor : Color.secondary.opacity(0.4),
                                    lineWidth: img.borderIsWhite ? 2 : 1))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("White border")

                // Remove border
                Divider().frame(height: 20).padding(.horizontal, 3)

                Button {
                    guard var updated = viewModel.selectedImage else { return }
                    viewModel.recordSnapshot(label: "Remove Border")
                    updated.borderWidthInches = 0
                    viewModel.updateCanvasImage(updated)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .help("Remove border")
            }
        }
    }

    // MARK: - Canvas Actions

    /// Paste an NSImage from the system clipboard onto the canvas.
    /// Uses the same sizing logic as drag-drop / file-load in PrintCanvasView.
    private func pasteImageFromClipboard() {
        guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage else { return }
        let rep = image.representations.first
        let pw = rep?.pixelsWide ?? 0
        let ph = rep?.pixelsHigh ?? 0
        let (paperW, paperH) = paperDimensions()
        var initW  = paperW - viewModel.marginLeft - viewModel.marginRight
        var initH  = paperH - viewModel.marginTop  - viewModel.marginBottom
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
                x: (paperW - initW) / 2 + cascade,
                y: (paperH - initH) / 2 + cascade
            ),
            size: CGSize(width: initW, height: initH),
            rotation: rotation
        )
        viewModel.addCanvasImage(canvasImg)
    }

    private func applyTemplate(width: CGFloat, height: CGFloat) {
        let isLandscape = width > height
        if isLandscape {
            viewModel.paperWidth  = max(width, height)
            viewModel.paperHeight = min(width, height)
            viewModel.isPortrait  = false
        } else {
            viewModel.paperWidth  = min(width, height)
            viewModel.paperHeight = max(width, height)
            viewModel.isPortrait  = width <= height
        }
        viewModel.refitImagesToCanvas()
    }

    private func applyContactSheet(cols: Int, rows: Int) {
        applyTemplate(width: 8.5, height: 11)
        viewModel.autoArrangeImages()
    }

    private func centerImage() {
        guard var img = viewModel.selectedImage else { return }
        viewModel.recordSnapshot(label: "Center")
        let (pw, ph) = paperDimensions()
        img.position.x = (pw - img.size.width)  / 2
        img.position.y = (ph - img.size.height) / 2
        viewModel.updateCanvasImage(img)
    }

    private func centerImageH() {
        guard var img = viewModel.selectedImage else { return }
        viewModel.recordSnapshot(label: "Center Horizontal")
        let (pw, _) = paperDimensions()
        img.position.x = (pw - img.size.width) / 2
        viewModel.updateCanvasImage(img)
    }

    private func centerImageV() {
        guard var img = viewModel.selectedImage else { return }
        viewModel.recordSnapshot(label: "Center Vertical")
        let (_, ph) = paperDimensions()
        img.position.y = (ph - img.size.height) / 2
        viewModel.updateCanvasImage(img)
    }

    private func fitImageToPage() {
        guard var img = viewModel.selectedImage else { return }
        viewModel.recordSnapshot(label: "Fit to Page")
        let (pw, ph) = paperDimensions()
        let printW = pw - viewModel.marginLeft - viewModel.marginRight
        let printH = ph - viewModel.marginTop  - viewModel.marginBottom
        guard printW > 0, printH > 0, img.size.width > 0, img.size.height > 0 else { return }
        let ar = img.size.height / img.size.width
        if ar > printH / printW {
            img.size.height = printH
            img.size.width  = printH / ar
        } else {
            img.size.width  = printW
            img.size.height = printW * ar
        }
        img.position.x = viewModel.marginLeft + (printW - img.size.width)  / 2
        img.position.y = viewModel.marginTop  + (printH - img.size.height) / 2
        viewModel.updateCanvasImage(img)
    }

    private func rotateCW() {
        guard var img = viewModel.selectedImage else { return }
        viewModel.recordSnapshot(label: "Rotate CW")
        let cx = img.position.x + img.size.width  / 2
        let cy = img.position.y + img.size.height / 2
        // Bake rotation into pixels so the frame (size) correctly represents the new dimensions.
        // Reset rotation to 0 — no separate visual transform needed.
        img.sourceImage = img.sourceImage.rotatedCW90()
        img.rotation    = 0
        let (nw, nh) = (img.size.height, img.size.width)
        img.size     = CGSize(width: nw, height: nh)
        // Rotate around center — no clamping, image may extend off-paper
        img.position = CGPoint(x: cx - nw / 2, y: cy - nh / 2)
        viewModel.updateCanvasImage(img)
    }

    private func rotateCCW() {
        guard var img = viewModel.selectedImage else { return }
        viewModel.recordSnapshot(label: "Rotate CCW")
        let cx = img.position.x + img.size.width  / 2
        let cy = img.position.y + img.size.height / 2
        img.sourceImage = img.sourceImage.rotatedCCW90()
        img.rotation    = 0
        let (nw, nh) = (img.size.height, img.size.width)
        img.size     = CGSize(width: nw, height: nh)
        // Rotate around center — no clamping, image may extend off-paper
        img.position = CGPoint(x: cx - nw / 2, y: cy - nh / 2)
        viewModel.updateCanvasImage(img)
    }

    private func deleteSelected() {
        guard let id = viewModel.selectedImageID else { return }
        viewModel.removeCanvasImage(id: id)
    }

    private func selectAll() {
        viewModel.selectedImageID = viewModel.canvasImages.first?.id
    }

    private func paperDimensions() -> (width: CGFloat, height: CGFloat) {
        let w = viewModel.isPortrait
            ? min(viewModel.paperWidth, viewModel.paperHeight)
            : max(viewModel.paperWidth, viewModel.paperHeight)
        let h = viewModel.isPortrait
            ? max(viewModel.paperWidth, viewModel.paperHeight)
            : min(viewModel.paperWidth, viewModel.paperHeight)
        return (w, h)
    }

    // MARK: - Run Print

    private func runPrint() {
        guard let first = viewModel.canvasImages.first else { return }
        let img = viewModel.isNegative ? first.sourceImage.invertedColors() : first.sourceImage
        let displayW = viewModel.isPortrait
            ? min(viewModel.paperWidth, viewModel.paperHeight)
            : max(viewModel.paperWidth, viewModel.paperHeight)
        let displayH = viewModel.isPortrait
            ? max(viewModel.paperWidth, viewModel.paperHeight)
            : min(viewModel.paperWidth, viewModel.paperHeight)
        let printView = CanvasPrintView(
            image: img,
            paperWidth:  displayW,  paperHeight: displayH,
            imgLeft:     first.position.x,  imgTop: first.position.y,
            imgWidth:    first.size.width,  imgHeight: first.size.height,
            rotation:    first.rotation,
            flipH:       viewModel.flipEmulsion,
            borderWidthInches: first.borderWidthInches,
            borderIsWhite: first.borderIsWhite
        )
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperSize              = NSSize(width: displayW * ppi, height: displayH * ppi)
        info.leftMargin             = viewModel.marginLeft   * ppi
        info.rightMargin            = viewModel.marginRight  * ppi
        info.topMargin              = viewModel.marginTop    * ppi
        info.bottomMargin           = viewModel.marginBottom * ppi
        info.isHorizontallyCentered = false
        info.isVerticallyCentered   = false
        applySelectedPrinter(on: info)
        if viewModel.colorMgmt == "No Color Management" {
            info.dictionary()[NSPrintInfo.AttributeKey("NSColorSyncColorSpaceName")] =
                "NSDeviceGrayColorSpace" as NSString
        }
        let panel = NSPrintPanel()
        panel.options = [.showsCopies, .showsPageRange, .showsPaperSize,
                         .showsOrientation, .showsScaling, .showsPreview]
        let op = NSPrintOperation(view: printView, printInfo: info)
        op.printPanel         = panel
        op.showsPrintPanel    = true
        op.showsProgressPanel = true
        if let window = NSApp.keyWindow {
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            op.run()
        }

        // Log the print job asynchronously — best-effort, failure is silent
        Task {
            await viewModel.logPrintJob(db: appDatabase, activityService: activityEventService)
        }
    }

    // MARK: - Page Setup

    private func pageSetup() {
        let info = NSPrintInfo.shared
        applySelectedPrinter(on: info)
        let layout = NSPageLayout()
        let result = layout.runModal(with: info)
        guard result == NSApplication.ModalResponse.OK.rawValue else { return }
        let pts: CGFloat = 72
        let sz   = info.paperSize
        let rawW = sz.width  / pts
        let rawH = sz.height / pts
        if info.orientation == .landscape {
            viewModel.paperWidth  = max(rawW, rawH)
            viewModel.paperHeight = min(rawW, rawH)
            viewModel.isPortrait  = false
        } else {
            viewModel.paperWidth  = min(rawW, rawH)
            viewModel.paperHeight = max(rawW, rawH)
            viewModel.isPortrait  = true
        }
    }

    private func applySelectedPrinter(on info: NSPrintInfo) {
        if !viewModel.selectedPrinterName.isEmpty,
           let printer = NSPrinter(name: viewModel.selectedPrinterName) {
            info.printer = printer
        }
    }
}

// MARK: - PrintLabToolbarButton

private struct PrintLabToolbarButton: View {
    let icon: String
    let label: String
    let help: String
    var isActive: Bool = false
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                Text(label)
                    .font(.system(size: 9))
            }
            .foregroundStyle(isActive ? Color.accentColor : (enabled ? Color.primary : Color.secondary.opacity(0.4)))
            .frame(width: 44, height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}
