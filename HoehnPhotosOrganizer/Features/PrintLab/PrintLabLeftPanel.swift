import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - PrintLabLeftPanel

/// Left panel of the redesigned Print Lab.
/// Top section: list of images currently on the canvas.
/// Bottom section: one-tap template presets.
struct PrintLabLeftPanel: View {

    @ObservedObject var viewModel: PrintLabViewModel
    let libraryPhotos: [PhotoAsset]   // from LibraryViewModel.photos

    @State private var showingPicker   = false
    @State private var showingSaveAs   = false
    @State private var saveAsName      = ""
    @State private var templateSearch  = ""

    // MARK: - Layer ordering helpers

    /// List items reversed so the frontmost layer (last in canvasImages) appears at the top.
    private var reversedListItems: [ListItem] {
        Array(listItems.reversed())
    }

    /// The ListItem ID that owns the currently selected canvas image.
    private var selectedListItemID: UUID? {
        guard let selID = viewModel.selectedImageID else { return nil }
        for item in listItems {
            switch item {
            case .single(let img) where img.id == selID:
                return item.id
            case .group(_, let imgs) where imgs.contains(where: { $0.id == selID }):
                return item.id
            default: break
            }
        }
        return nil
    }

    private var isAtFront: Bool {
        guard let selID = selectedListItemID else { return true }
        return listItems.last?.id == selID
    }

    private var isAtBack: Bool {
        guard let selID = selectedListItemID else { return true }
        return listItems.first?.id == selID
    }

    private func bringToFront() {
        guard let selID = selectedListItemID else { return }
        var ids = listItems.map(\.id)
        guard let idx = ids.firstIndex(of: selID) else { return }
        ids.remove(at: idx); ids.append(selID)
        viewModel.reorderLayers(byListItemIDs: ids)
    }

    private func sendToBack() {
        guard let selID = selectedListItemID else { return }
        var ids = listItems.map(\.id)
        guard let idx = ids.firstIndex(of: selID) else { return }
        ids.remove(at: idx); ids.insert(selID, at: 0)
        viewModel.reorderLayers(byListItemIDs: ids)
    }

    private func bringForward() {
        guard let selID = selectedListItemID else { return }
        var ids = listItems.map(\.id)
        guard let idx = ids.firstIndex(of: selID), idx < ids.count - 1 else { return }
        ids.swapAt(idx, idx + 1)
        viewModel.reorderLayers(byListItemIDs: ids)
    }

    private func sendBackward() {
        guard let selID = selectedListItemID else { return }
        var ids = listItems.map(\.id)
        guard let idx = ids.firstIndex(of: selID), idx > 0 else { return }
        ids.swapAt(idx, idx - 1)
        viewModel.reorderLayers(byListItemIDs: ids)
    }

    var body: some View {
        VStack(spacing: 0) {
            imageListSection
            Divider()
            bottomScrollArea
        }
        .frame(width: 220)
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(isPresented: $showingPicker) {
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
        .sheet(isPresented: $showingSaveAs) {
            saveAsSheet
        }
    }

    // MARK: - List display items

    private enum ListItem: Identifiable {
        case single(CanvasImage)
        case group(id: UUID, images: [CanvasImage])

        var id: UUID {
            switch self {
            case .single(let img):       return img.id
            case .group(let id, _):     return id
            }
        }
    }

    private var listItems: [ListItem] {
        var result: [ListItem] = []
        var seen = Set<UUID>()
        for img in viewModel.canvasImages {
            if let gid = img.groupID {
                guard !seen.contains(gid) else { continue }
                seen.insert(gid)
                let group = viewModel.canvasImages.filter { $0.groupID == gid }
                result.append(.group(id: gid, images: group))
            } else {
                result.append(.single(img))
            }
        }
        return result
    }

    // MARK: - Image List Section

    private var imageListSection: some View {
        VStack(spacing: 0) {
            // Section header — always pinned at top
            HStack {
                Text("Layers")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if !viewModel.canvasImages.isEmpty {
                    Button {
                        viewModel.canvasImages.removeAll()
                        viewModel.selectedImageID = nil
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear all images")
                }
                Button {
                    showingPicker = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Add from Library")
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 4)

            Divider()

            // Arrangement strip — only when multiple layers exist and one is selected
            if viewModel.canvasImages.count > 1 && viewModel.selectedImageID != nil {
                arrangementStrip
                Divider()
            }

            if viewModel.canvasImages.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("No layers")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Reversed list: top row = frontmost layer (Photoshop convention).
                // Drag-to-reorder is enabled via onMove + always-active editMode.
                List {
                    ForEach(reversedListItems) { item in
                        layerRow(for: item)
                            .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    .onMove { from, to in
                        var ids = reversedListItems.map(\.id)
                        ids.move(fromOffsets: from, toOffset: to)
                        // ids is front→back; canvasImages is back→front
                        viewModel.reorderLayers(byListItemIDs: ids.reversed())
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
            }
        }
        .frame(maxHeight: 260)
    }

    @ViewBuilder
    private func layerRow(for item: ListItem) -> some View {
        switch item {
        case .single(let img):
            ImageListRow(
                image: img,
                isSelected: viewModel.selectedImageID == img.id,
                onSelect: { viewModel.selectedImageID = img.id },
                onRemove: { viewModel.removeCanvasImage(id: img.id) }
            )
        case .group(let gid, let images):
            ImageGroupRow(
                images: images,
                isSelected: images.contains { viewModel.selectedImageID == $0.id },
                onSelect: { viewModel.selectedImageID = images.first?.id },
                onRemove: { viewModel.removeGroup(groupID: gid) }
            )
        }
    }

    // MARK: - Arrangement Strip

    private var arrangementStrip: some View {
        HStack(spacing: 0) {
            Text("Arrange")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.leading, 10)
            Spacer()
            arrangementBtn(icon: "arrow.up.to.line", help: "Bring to Front",
                           disabled: isAtFront, action: bringToFront)
            arrangementBtn(icon: "arrow.up", help: "Bring Forward",
                           disabled: isAtFront, action: bringForward)
            arrangementBtn(icon: "arrow.down", help: "Send Backward",
                           disabled: isAtBack, action: sendBackward)
            arrangementBtn(icon: "arrow.down.to.line", help: "Send to Back",
                           disabled: isAtBack, action: sendToBack)
        }
        .padding(.trailing, 4)
        .padding(.vertical, 3)
    }

    private func arrangementBtn(icon: String, help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 24, height: 22)
                .foregroundStyle(disabled ? Color.secondary.opacity(0.25) : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    // MARK: - Bottom scroll area (Libraries + Transforms + History)

    /// True only when an image is actively selected — gates Transforms.
    private var hasSelectedImage: Bool { viewModel.selectedImageID != nil }

    private var stepWedgeItems: [(steps: Int, subtitle: String)] {
        [(21, "SpyderPRINT / i1Pro, 1 row"),
         (31, "2 rows, even tonal steps"),
         (50, "Medium density ramp"),
         (80, "5×16 grid"),
         (129, "Fine tonal graduation"),
         (256, "Full 8-bit ramp, 16×16"),
         (512, "High-density, 16×32")]
    }

    private var imageTransformItems: [(icon: String, title: String, subtitle: String, template: PrintTemplate, action: () -> Void)] {
        let img = viewModel.canvasImages.first(where: { $0.id == viewModel.selectedImageID })?.sourceImage
            ?? viewModel.canvasImages.first?.sourceImage
            ?? NSImage()
        return [
            ("square.grid.3x3", "Calibration Strip", "8 tiles, ±15% brightness",
             .calibrationStrip(columns: 4, rows: 2, brightnessRange: 0.30, saturationRange: 0.0), {
                viewModel.applyTemplate(.calibrationStrip(columns: 4, rows: 2, brightnessRange: 0.30, saturationRange: 0.0), sourceImage: img)
            }),
            ("rectangle.grid.2x2", "8-up Proof Sheet", "8 copies, progressive curves",
             .eightUpProof, {
                viewModel.applyTemplate(.eightUpProof, sourceImage: img)
            }),
            ("doc.richtext.fill", "Digital Negative", "Grayscale + invert for alt-process",
             .digitalNegative, {
                viewModel.applyTemplate(.digitalNegative, sourceImage: img)
            }),
            ("arrow.up.left.and.arrow.down.right", "Flush Target", "Zero margins, fill paper edge-to-edge",
             .flushTarget, {
                viewModel.applyTemplate(.flushTarget, sourceImage: img)
            }),
        ]
    }

    private func templateItemProvider(_ template: PrintTemplate) -> NSItemProvider? {
        guard let data = try? JSONEncoder().encode(template) else { return nil }
        return NSItemProvider(item: data as NSData, typeIdentifier: UTType.json.identifier)
    }

    private var bottomScrollArea: some View {
        VStack(spacing: 0) {

            // ── TEMPLATES ─────────────────────────────────────
            VStack(spacing: 0) {
                PanelSectionHeader(title: "Templates")
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        LibrarySectionHeader(title: "Step Wedges")
                        ForEach(stepWedgeItems, id: \.steps) { item in
                            let template = PrintTemplate.stepWedge(steps: item.steps)
                            TemplateButton(
                                icon: item.steps <= 50 ? "rectangle.split.3x1" : "rectangle.split.3x1.fill",
                                title: "\(item.steps)-Step Wedge",
                                subtitle: item.subtitle,
                                dragProvider: templateItemProvider(template)
                            ) {
                                viewModel.applyTemplate(template, sourceImage: NSImage())
                            }
                        }

                        if !viewModel.savedTemplates.isEmpty {
                            LibrarySectionHeader(title: "Saved")
                            ForEach(viewModel.savedTemplates) { template in
                                TemplateButton(
                                    icon: "bookmark.fill",
                                    title: template.displayName,
                                    subtitle: "Custom",
                                    disabled: !hasSelectedImage,
                                    disabledHint: "Select an image first"
                                ) {
                                    if let img = viewModel.canvasImages
                                        .first(where: { $0.id == viewModel.selectedImageID })?.sourceImage
                                        ?? viewModel.canvasImages.first?.sourceImage {
                                        viewModel.applyTemplate(template, sourceImage: img)
                                    }
                                }
                            }
                        }

                        Button {
                            saveAsName = ""
                            showingSaveAs = true
                        } label: {
                            Label("Save Current as\u{2026}", systemImage: "bookmark.circle.fill")
                                .font(.system(size: 11))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(maxHeight: 220)

            Divider()

            // ── TOOLS ─────────────────────────────────────────
            VStack(spacing: 0) {
                PanelSectionHeader(title: "Tools")
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        if !hasSelectedImage {
                            Text("Select an image to apply tools")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        } else {
                            // Border tool — adds/removes border outside the image
                            let borderActive = viewModel.selectedImage?.borderWidthInches ?? 0 > 0
                            TemplateButton(
                                icon: borderActive ? "square.filled.on.square" : "square.dashed",
                                title: "Border",
                                subtitle: borderActive ? "Active — adjust in toolbar" : "Add border outside image",
                                isActive: borderActive
                            ) {
                                guard var img = viewModel.selectedImage else { return }
                                viewModel.recordSnapshot(label: borderActive ? "Remove Border" : "Add Border")
                                img.borderWidthInches = borderActive ? 0 : 0.25
                                viewModel.updateCanvasImage(img)
                            }

                            ForEach(Array(imageTransformItems.enumerated()), id: \.offset) { _, t in
                                TemplateButton(icon: t.icon, title: t.title, subtitle: t.subtitle,
                                               dragProvider: templateItemProvider(t.template),
                                               action: t.action)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(maxHeight: 180)

            Divider()

            // ── HISTORY ───────────────────────────────────────
            VStack(spacing: 0) {
                PanelSectionHeader(title: "History") {
                    if viewModel.canUndo {
                        Button("Undo") { viewModel.undo() }
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                            .buttonStyle(.plain)
                    }
                }
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        if viewModel.historyLabels.isEmpty {
                            Text("No changes yet")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(Array(viewModel.historyLabels.enumerated()), id: \.offset) { i, label in
                                HStack(spacing: 6) {
                                    Image(systemName: i == 0 ? "clock.fill" : "clock")
                                        .font(.system(size: 10))
                                        .foregroundStyle(i == 0 ? Color.accentColor : Color.secondary.opacity(0.5))
                                        .frame(width: 16)
                                    Text(label)
                                        .font(.system(size: 11))
                                        .foregroundStyle(i == 0 ? Color.primary : Color.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: - Save As Sheet

    private var saveAsSheet: some View {
        VStack(spacing: 16) {
            Text("Save as Template")
                .font(.headline)
            TextField("Template name", text: $saveAsName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
            HStack {
                Button("Cancel") { showingSaveAs = false }
                Button("Save") {
                    if !saveAsName.isEmpty {
                        viewModel.savedTemplates.append(.custom(name: saveAsName))
                    }
                    showingSaveAs = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saveAsName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 320)
    }
}

// MARK: - ImageListRow

private struct ImageListRow: View {
    let image: CanvasImage
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    private var thumbnail: NSImage? {
        if let asset = image.photoAsset {
            let baseName = (asset.canonicalName as NSString).deletingPathExtension
            let url = ProxyGenerationActor.proxiesDirectory()
                .appendingPathComponent(baseName + ".jpg")
            return NSImage(contentsOf: url)
        }
        return image.sourceImage
    }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let thumb = thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Color(nsColor: .separatorColor)
                }
            }
            .frame(width: 32, height: 28)
            .clipped()
            .cornerRadius(3)

            Text(image.photoAsset?.canonicalName ?? "Dropped image")
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Calibration strip tile label (if present)
            if let label = image.tileLabel {
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from canvas")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .cornerRadius(4)
        .onTapGesture { onSelect() }
    }
}

// MARK: - ImageGroupRow

private struct ImageGroupRow: View {
    let images: [CanvasImage]
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Color(nsColor: .separatorColor).cornerRadius(3)
                Text("\(images.count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 32, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(images.first?.groupLabel ?? "Template Group")
                    .font(.system(size: 11))
                    .lineLimit(1)
                Text("\(images.count) patches")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from canvas")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .cornerRadius(4)
        .onTapGesture { onSelect() }
    }
}

// MARK: - PanelSectionHeader (major section divider with optional trailing)

private struct PanelSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    init(title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

// MARK: - LibrarySectionHeader (minor sub-section label)

private struct LibrarySectionHeader: View {
    let title: String
    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

// MARK: - TemplateButton

private struct TemplateButton: View {
    let icon: String
    let title: String
    let subtitle: String
    var disabled: Bool = false
    var disabledHint: String = ""
    var isActive: Bool = false
    var dragProvider: NSItemProvider? = nil
    let action: () -> Void

    var body: some View {
        if let provider = dragProvider {
            buttonContent.onDrag { provider }
        } else {
            buttonContent
        }
    }

    private var buttonContent: some View {
        Button(action: { if !disabled { action() } }) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 20)
                    .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(disabled ? Color.secondary.opacity(0.5) : Color.primary)
                    Text(disabled && !disabledHint.isEmpty ? disabledHint : subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isActive ? Color.accentColor.opacity(0.08) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .allowsHitTesting(true)
        .opacity(disabled ? 0.6 : 1.0)
    }
}
