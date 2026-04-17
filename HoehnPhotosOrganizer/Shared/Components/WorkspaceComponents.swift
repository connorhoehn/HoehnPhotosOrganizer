import CoreGraphics
import GRDB
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - PhotoCardAsset (production: PhotoAsset from DB)

struct PhotoCardAsset: View {
    let photo: PhotoAsset
    let isSelected: Bool
    var isPendingSelection: Bool = false
    /// When flipped to true externally (e.g. keyboard Enter), opens the full-screen preview sheet.
    var forceShowPreview: Bool = false
    var onQuickCuration: ((CurationState) -> Void)? = nil
    /// Called when a context-menu action needs the inspector open (e.g. Get Editorial Feedback).
    var onOpenInspector: (() -> Void)? = nil
    /// Called when "Add Note…" is chosen from the context menu.
    /// Pass a closure from the parent to handle multi-photo selection; nil = single-photo sheet.
    var onAddNote: (() -> Void)? = nil
    /// Called when "Open in Print Lab" is chosen from the context menu.
    var onSendToPrintLab: (() -> Void)? = nil
    /// Called when "Open in Workflow" is chosen from the context menu.
    var onSendToWorkflow: (() -> Void)? = nil
    /// Called when "Remove from Library" is chosen — marks the photo as deleted (soft delete).
    var onRemoveFromLibrary: (() -> Void)? = nil
    /// ViewModel reference for the detail view.
    var viewModel: LibraryViewModel? = nil

    @Environment(\.appDatabase) private var appDatabase: AppDatabase?

    @State private var proxyImage: NSImage? = nil
    @State private var isHovering: Bool = false
    @State private var showingPreview: Bool = false
    @State private var showingRefineSheet: Bool = false
    @State private var showingAdjustments: Bool = false
    @State private var showingNoteInput: Bool = false
    @State private var showingPasteSheet: Bool = false
    @State private var pasteOptions: PasteOptions = .all
    @Environment(AdjustmentClipboard.self) private var clipboard: AdjustmentClipboard?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            thumbnailView
                .frame(maxWidth: .infinity, minHeight: 145, maxHeight: 145)
                .clipped()
                .overlay(alignment: .topTrailing) {
                    if isHovering {
                        curationMenu
                            .padding(10)
                            .transition(.opacity)
                    } else {
                        StatusPill(
                            title: photo.syncStateEnum.label,
                            tint: photo.syncStateEnum.tint
                        )
                        .padding(10)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if isHovering {
                        Button {
                            showingPreview = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(.black.opacity(0.55)))
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                        .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottom) {
                    if isHovering {
                        quickActionsStrip
                            .padding(.bottom, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
                }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 6) {
                    Text(displayName(for: photo.canonicalName))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    StatusPill(
                        title: photo.curationStateEnum.title,
                        tint: photo.curationStateEnum.tint
                    )
                }

                HStack(spacing: 8) {
                    if let ts = parsedDate(from: photo.canonicalName) {
                        Text(ts).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(photo.createdAt.prefix(10)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: roleIcon(for: photo.role))
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                        if photo.processingState == ProcessingState.proxyReady.rawValue {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10)).foregroundStyle(.green.opacity(0.7))
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.18)
                        : isPendingSelection
                            ? Color.accentColor.opacity(0.08)
                            : Color(nsColor: .controlBackgroundColor)
                )
        )
        .shadow(color: isSelected ? Color.accentColor.opacity(0.25) : .black.opacity(0.05),
                radius: isSelected ? 8 : 4, y: isSelected ? 2 : 3)
        .padding(4)
        .onTapGesture(count: 2) {
            if let vm = viewModel {
                vm.developPhoto = photo
                vm.showDevelopMode = true
            } else {
                showingPreview = true
            }
        }
        .onChange(of: forceShowPreview) { _, new in if new { showingPreview = true } }
        .contextMenu {
            if photo.role == PhotoRole.workflowOutput.rawValue {
                Button("Refine Frame Boundary…") {
                    showingRefineSheet = true
                }
                Divider()
            }
            Button {
                if let handler = onAddNote {
                    handler()
                } else {
                    showingNoteInput = true
                }
            } label: {
                Label("Add Note…", systemImage: "note.text.badge.plus")
            }
            Divider()
            Button {
                if let vm = viewModel {
                    vm.developPhoto = photo
                    vm.showDevelopMode = true
                }
            } label: {
                Label("Develop", systemImage: "camera.filters")
            }
            .disabled(viewModel == nil)
            Button {
                showingAdjustments = true
            } label: {
                Label("Edit Adjustments…", systemImage: "slider.horizontal.3")
            }
            Button {
                showingPreview = true
            } label: {
                Label("Get Editorial Feedback…", systemImage: "text.bubble")
            }
            if clipboard?.hasContent == true {
                Divider()
                Button {
                    showingPasteSheet = true
                } label: {
                    Label("Paste Settings", systemImage: "doc.on.clipboard")
                }
                Button {
                    guard let clip = clipboard, let db = appDatabase else { return }
                    Task {
                        let lineageRepo = LineageRepository(db.dbPool)
                        let siblings = try await lineageRepo.fetchSiblings(for: photo.id)
                        if !siblings.isEmpty {
                            showingPasteSheet = true
                        }
                    }
                } label: {
                    Label("Sync to Roll", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            if onSendToPrintLab != nil || onSendToWorkflow != nil {
                Divider()
                if onSendToPrintLab != nil {
                    Button {
                        onSendToPrintLab?()
                    } label: {
                        Label("Open in Print Lab", systemImage: "printer")
                    }
                }
                if onSendToWorkflow != nil {
                    Button {
                        onSendToWorkflow?()
                    } label: {
                        Label("Open in Workflow", systemImage: "arrow.triangle.2.circlepath.circle")
                    }
                }
            }
            Divider()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: photo.filePath)]
                )
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .disabled(!FileManager.default.fileExists(atPath: photo.filePath))
            if onRemoveFromLibrary != nil {
                Divider()
                Button(role: .destructive) {
                    onRemoveFromLibrary?()
                } label: {
                    Label("Remove from Library", systemImage: "trash")
                }
            }
        }
        .sheet(isPresented: $showingNoteInput) {
            if let db = appDatabase {
                NoteInputSheet(photoId: photo.id, db: db)
            }
        }
        .sheet(isPresented: $showingAdjustments) {
            AdjustmentPanelView(targets: [photo])
        }
        .sheet(isPresented: $showingPasteSheet) {
            SelectivePasteSheet(
                options: $pasteOptions,
                targetCount: 1,
                onConfirm: {
                    guard let clip = clipboard, let db = appDatabase else { return }
                    let target = PhotoAdjustments() // default — paste replaces everything selected
                    if let merged = clip.buildAdjustment(for: target, options: pasteOptions),
                       let json = merged.encodeToJSON() {
                        let now = ISO8601DateFormatter().string(from: Date())
                        Task {
                            try? await db.dbPool.write { d in
                                try d.execute(
                                    sql: "UPDATE photo_assets SET adjustments_json = ?, updated_at = ? WHERE id = ?",
                                    arguments: [json, now, photo.id]
                                )
                            }
                            let snapshotRepo = AdjustmentSnapshotRepository(db: db)
                            let snapshot = AdjustmentSnapshot(
                                id: UUID().uuidString,
                                photoAssetId: photo.id,
                                label: "Paste settings",
                                adjustmentJSON: json,
                                thumbnailPath: nil,
                                isCurrentState: true,
                                createdAt: Date()
                            )
                            try? await snapshotRepo.saveSnapshot(snapshot)
                        }
                    }
                    showingPasteSheet = false
                },
                onCancel: { showingPasteSheet = false }
            )
        }
        .task(id: photo.updatedAt) {
            proxyImage = await loadProxyImage()
        }
        .sheet(isPresented: $showingPreview) {
            if let vm = viewModel {
                PhotoDetailView(photo: photo, image: proxyImage, isPresented: $showingPreview, viewModel: vm)
            } else {
                ImagePreviewOverlay(photo: photo, image: proxyImage, isPresented: $showingPreview)
            }
        }
        .sheet(isPresented: $showingRefineSheet) {
            RefineFrameSheet(clip: photo)
        }
        .onDrag {
            NSItemProvider(object: photo.id as NSString)
        }
    }

    // MARK: - Quick actions

    private var quickActionsStrip: some View {
        HStack(spacing: 6) {
            overlayIconButton(icon: "rotate.left") {
                Task { await rotateProxy(clockwise: false) }
            }
            overlayIconButton(icon: "rotate.right") {
                Task { await rotateProxy(clockwise: true) }
            }
            overlayIconButton(icon: "slider.horizontal.3") {
                showingAdjustments = true
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.black.opacity(0.55))
        )
    }

    private func overlayIconButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Curation hamburger

    private var curationMenu: some View {
        Menu {
            Button { onQuickCuration?(.keeper) } label: {
                Label("Keep", systemImage: "checkmark")
            }
            Button { onQuickCuration?(.archive) } label: {
                Label("Archive", systemImage: "archivebox")
            }
            Button { onQuickCuration?(.needsReview) } label: {
                Label("Flag for Review", systemImage: "flag")
            }
            Button { onQuickCuration?(.rejected) } label: {
                Label("Reject", systemImage: "xmark")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.black.opacity(0.55)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Rotation

    private func rotateProxy(clockwise: Bool) async {
        let baseName   = (photo.canonicalName as NSString).deletingPathExtension
        let proxiesDir = ProxyGenerationActor.proxiesDirectory()
        let thumbsDir  = ProxyGenerationActor.thumbsDirectory()
        let proxyURL   = proxiesDir.appendingPathComponent(baseName + ".jpg")
        let thumbURL   = thumbsDir.appendingPathComponent(baseName + ".jpg")

        await Task.detached(priority: .userInitiated) {
            for url in [proxyURL, thumbURL] {
                guard FileManager.default.fileExists(atPath: url.path),
                      let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg  = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }

                let srcW = cg.width, srcH = cg.height
                let newW = srcH,     newH = srcW
                guard let ctx = CGContext(
                    data: nil, width: newW, height: newH,
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                ) else { continue }

                if clockwise {
                    ctx.translateBy(x: 0, y: CGFloat(newH))
                    ctx.rotate(by: -.pi / 2)
                } else {
                    ctx.translateBy(x: CGFloat(newW), y: 0)
                    ctx.rotate(by: .pi / 2)
                }
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(srcW), height: CGFloat(srcH)))

                guard let rotated = ctx.makeImage(),
                      let dest = CGImageDestinationCreateWithURL(
                          url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
                      ) else { continue }
                CGImageDestinationAddImage(dest, rotated,
                    [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
                CGImageDestinationFinalize(dest)
            }
        }.value

        proxyImage = await loadProxyImage()
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private var thumbnailView: some View {
        if let img = proxyImage {
            GeometryReader { geo in
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.linearGradient(
                    colors: photo.placeholderGradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .overlay {
                    Image(systemName: photo.role == PhotoRole.original.rawValue ? "camera.macro" : "photo")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.86))
                }
        }
    }

    private func displayName(for canonical: String) -> String {
        if let range = canonical.range(of: #"20\d{6}"#, options: .regularExpression) {
            let raw = String(canonical[range])
            let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd"
            if let date = fmt.date(from: raw) {
                let out = DateFormatter(); out.dateStyle = .medium; out.timeStyle = .none
                return out.string(from: date)
            }
        }
        return (canonical as NSString).deletingPathExtension
    }

    private func parsedDate(from canonical: String) -> String? {
        if let range = canonical.range(of: #"20\d{6}"#, options: .regularExpression) {
            let raw = String(canonical[range])
            let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd"
            if let date = fmt.date(from: raw) {
                let out = DateFormatter(); out.dateStyle = .medium; out.timeStyle = .none
                return out.string(from: date)
            }
        }
        return nil
    }

    private func roleIcon(for role: String) -> String {
        switch role {
        case PhotoRole.original.rawValue:       return "camera.macro"
        case PhotoRole.workflowOutput.rawValue: return "wand.and.rays"
        case PhotoRole.editedExport.rawValue:   return "photo.on.rectangle"
        default: return "photo"
        }
    }

    private func loadProxyImage() async -> NSImage? {
        let baseName = (photo.canonicalName as NSString).deletingPathExtension
        let proxyURL = ProxyGenerationActor.proxiesDirectory()
            .appendingPathComponent(baseName + ".jpg")
        guard FileManager.default.fileExists(atPath: proxyURL.path) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            NSImage(contentsOf: proxyURL)
        }.value
    }
}

// MARK: - ImagePreviewOverlay

struct ImagePreviewOverlay: View {
    let photo: PhotoAsset
    let image: NSImage?
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(40)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "photo")
                        .font(.system(size: 64, weight: .light))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("No preview available").foregroundStyle(.white.opacity(0.4))
                }
            }

            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(photo.canonicalName).font(.headline).foregroundStyle(.white)
                        HStack(spacing: 8) {
                            StatusPill(title: photo.curationStateEnum.title, tint: photo.curationStateEnum.tint)
                            StatusPill(title: photo.processingStateEnum.title, tint: .white.opacity(0.5))
                        }
                    }
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.7))
                            .background(Circle().fill(.black.opacity(0.3)))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(LinearGradient(
                    colors: [.black.opacity(0.7), .clear],
                    startPoint: .top, endPoint: .bottom
                ))
                Spacer()
            }
        }
        .frame(minWidth: 700, minHeight: 520)
    }
}

// MARK: - PhotoCard (legacy: PhotoRecord — Preview / MockDataStore only)

struct PhotoCard: View {
    let photo: PhotoRecord
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.linearGradient(colors: photo.gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(maxWidth: .infinity, minHeight: 145, maxHeight: 145)
                .overlay(alignment: .topTrailing) {
                    StatusPill(title: photo.syncState.label, tint: photo.syncState.tint)
                        .padding(10)
                }
                .overlay {
                    Image(systemName: photo.role == .original ? "camera.macro" : "photo")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.86))
                }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(photo.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    StatusPill(title: photo.curation.title, tint: photo.curation.tint)
                }

                Text(photo.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                Text("\(photo.city), \(photo.country)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(photo.canonicalName)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        }
        .shadow(color: .black.opacity(isSelected ? 0.16 : 0.05), radius: isSelected ? 12 : 4, y: 4)
    }
}

// MARK: - MetricCard

struct MetricCard: View {
    let metric: DashboardMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(metric.title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(metric.value)
                .font(.system(size: 28, weight: .bold))

            Text(metric.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(metric.tint.opacity(0.12))
        )
    }
}

// MARK: - SettingsRow

struct SettingsRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

// MARK: - InspectorRow

struct InspectorRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }
}

// MARK: - StatusPill

struct StatusPill: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.16))
            )
            .foregroundStyle(tint)
    }
}

// MARK: - FlexibleTagWrap

struct FlexibleTagWrap: View {
    let tags: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(tags.chunked(into: 2).enumerated()), id: \.offset) { pair in
                let row = pair.element
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { tag in
                        Text(tag)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.accentColor.opacity(0.12))
                            )
                    }
                    Spacer()
                }
            }
        }
    }
}

// MARK: - ImportStageRow

struct ImportStageRow: View {
    let stage: ImportStage
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(stage.title)
                        .font(.headline)
                    Text(stage.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Array chunking helper

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
