import SwiftUI

// MARK: - StudioAdvancedPanel

/// Collapsible left sidebar for source image management and quick presets.
/// Expands to ~200px, collapses to a thin chevron toggle strip.
struct StudioAdvancedPanel: View {

    @ObservedObject var viewModel: StudioViewModel
    @Binding var isExpanded: Bool
    @Binding var pbnActive: Bool
    let onOpenFile: () -> Void
    let onShowLibrary: () -> Void

    @State private var presetThumbnails: [String: NSImage] = [:]
    @State private var thumbnailSourceHash: Int = 0
    @State private var thumbnailTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            if isExpanded {
                expandedContent
                    .frame(width: 200)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            // Toggle strip
            toggleStrip
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
    }

    // MARK: - Toggle Strip

    @State private var stripHovered = false

    private var toggleStrip: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Image(systemName: isExpanded ? "chevron.left" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(stripHovered ? .primary : .secondary)
                .frame(maxWidth: 18, maxHeight: .infinity)
                .background(stripHovered ? Color.primary.opacity(0.08) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in stripHovered = hovering }
        .help(isExpanded ? "Collapse panel" : "Expand panel")
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                sourceSection
                Divider()
                actionsSection

                if viewModel.selectedMedium == .oil {
                    Divider()
                    configurationSection
                }

                if viewModel.selectedMedium == .troisCrayon || viewModel.selectedMedium == .charcoal || viewModel.selectedMedium == .graphite {
                    Divider()
                    thresholdsSection
                }

                if viewModel.showContours || viewModel.showNumbers {
                    Divider()
                    paletteSection
                }

                if viewModel.renderedImage != nil {
                    Divider()
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { pbnActive.toggle() }
                    } label: {
                        Label("Paint by Numbers", systemImage: "paintpalette.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(pbnActive ? Color.purple : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(pbnActive ? Color.purple.opacity(0.12) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
        .onAppear { generatePresetThumbnailsIfNeeded() }
        .onChange(of: viewModel.sourceImage) { _ in generatePresetThumbnailsIfNeeded() }
        .onChange(of: viewModel.croppedImage) { _ in generatePresetThumbnailsIfNeeded() }
        .onChange(of: viewModel.selectedMedium) { _ in generatePresetThumbnailsIfNeeded() }
    }

    // MARK: - Source Section

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Source")

            // Thumbnail
            if let source = viewModel.croppedImage ?? viewModel.sourceImage {
                Image(nsImage: source)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.04))
                    .frame(maxWidth: .infinity, minHeight: 60, maxHeight: 60)
                    .overlay(
                        Text("No image")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    )
            }

            // Resolution info + low-res warning
            if let info = viewModel.sourceResolutionInfo {
                HStack(spacing: 4) {
                    Text("\(info.width)×\(info.height)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f MP", info.megapixels))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if info.isLowRes {
                        Spacer()
                        HStack(spacing: 2) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 8))
                            Text("Low res")
                                .font(.system(size: 8, weight: .medium))
                        }
                        .foregroundStyle(.orange)
                        .help("Source is under 1 MP — open the full-resolution file for better quality")
                    }
                }
            }

            // Action buttons
            HStack(spacing: 6) {
                Button {
                    onOpenFile()
                } label: {
                    Label("Change", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button {
                    viewModel.showingCropTool = true
                } label: {
                    Label("Crop", systemImage: "crop")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(viewModel.sourceImage == nil)
            }

            Button {
                onShowLibrary()
            } label: {
                Label("From Library", systemImage: "photo.on.rectangle")
                    .font(.system(size: 10))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    // MARK: - Presets Section

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Quick Presets")

            ForEach(presetsForCurrentMedium(), id: \.name) { preset in
                Button {
                    viewModel.updateParams(preset.params, commandName: "Apply \(preset.name) preset")
                } label: {
                    HStack(spacing: 6) {
                        if let thumb = presetThumbnails[preset.name] {
                            Image(nsImage: thumb)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 40, height: 30)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                                )
                        } else {
                            Image(systemName: preset.icon)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .frame(width: 40, height: 30)
                        }
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
                    .padding(.horizontal, 6)
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
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Actions")

            Button {
                viewModel.saveVersion(name: viewModel.selectedMedium.rawValue)
            } label: {
                Label("Save Version", systemImage: "square.and.arrow.down")
                    .font(.system(size: 10))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.renderedImage == nil)

            Button {
                viewModel.exportRenderedImage()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.system(size: 10))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.renderedImage == nil)
        }
    }

    // MARK: - Configuration Section

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Configuration")

            switch viewModel.mediumParams {
            case .oil(let p):
                oilConfigSliders(p)
            default:
                EmptyView()
            }
        }
    }

    private func oilConfigSliders(_ params: OilPaintPipeline.Params) -> some View {
        VStack(spacing: 6) {
            sidebarSlider(
                label: "Bilateral",
                value: Double(params.bilateralD),
                range: 5...25,
                step: 1,
                format: "%.0f"
            ) { newVal in
                var p = params
                p.bilateralD = Int(newVal)
                viewModel.updateParams(.oil(p), commandName: "Change Bilateral")
            }

            sidebarSlider(
                label: "\u{03C3} Color",
                value: params.sigmaColor,
                range: 20...150,
                step: 1,
                format: "%.0f"
            ) { newVal in
                var p = params
                p.sigmaColor = newVal
                viewModel.updateParams(.oil(p), commandName: "Change Sigma Color")
            }

            sidebarSlider(
                label: "\u{03C3} Space",
                value: params.sigmaSpace,
                range: 20...150,
                step: 1,
                format: "%.0f"
            ) { newVal in
                var p = params
                p.sigmaSpace = newVal
                viewModel.updateParams(.oil(p), commandName: "Change Sigma Space")
            }

            sidebarSlider(
                label: "Prune",
                value: Double(params.pruneMinPixels),
                range: 50...400,
                step: 1,
                format: "%.0f"
            ) { newVal in
                var p = params
                p.pruneMinPixels = Int(newVal)
                viewModel.updateParams(.oil(p), commandName: "Change Prune Min")
            }

            sidebarSlider(
                label: "Texture",
                value: params.brushTexture,
                range: 0...1,
                step: 0.01,
                format: "%.2f"
            ) { newVal in
                var p = params
                p.brushTexture = newVal
                viewModel.updateParams(.oil(p), commandName: "Change Brush Texture")
            }
        }
    }

    private func sidebarSlider(
        label: String,
        value: Double,
        range: ClosedRange<Double>,
        step: Double,
        format: String,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9))
                .frame(width: 48, alignment: .leading)
            Slider(value: Binding(
                get: { value },
                set: { onChange($0) }
            ), in: range, step: step)
                .controlSize(.small)
            Text(String(format: format, value))
                .font(.system(size: 9, design: .monospaced))
                .frame(width: 30, alignment: .trailing)
        }
    }

    // MARK: - Palette Section

    private var paletteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Palette")

            // Palette picker
            Menu {
                ForEach(PBNPalette.builtIn) { palette in
                    Button {
                        viewModel.overlayPalette = palette
                        viewModel.generateOverlay()
                    } label: {
                        HStack {
                            Text(palette.name)
                            if palette.id == viewModel.overlayPalette.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    // Mini color swatches
                    ForEach(viewModel.overlayPalette.colors.prefix(5)) { c in
                        Circle()
                            .fill(c.color)
                            .frame(width: 8, height: 8)
                    }
                    Text(viewModel.overlayPalette.name)
                        .font(.system(size: 10))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }
            .menuStyle(.borderlessButton)

            // Region list
            if viewModel.isGeneratingOverlay {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Analyzing...")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            } else if !viewModel.overlayRegions.isEmpty {
                ForEach(viewModel.overlayRegions) { region in
                    HStack(spacing: 6) {
                        Text("\(region.id + 1)")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, alignment: .trailing)

                        RoundedRectangle(cornerRadius: 2)
                            .fill(region.color.color)
                            .frame(width: 14, height: 14)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                            )

                        Text(region.color.name)
                            .font(.system(size: 10))
                            .lineLimit(1)

                        Spacer()

                        if region.coveragePercent > 0 {
                            Text(String(format: "%.0f%%", region.coveragePercent))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Thresholds Section

    private var thresholdsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("THRESHOLDS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(thresholdCount)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button { removeThreshold() } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .disabled(thresholdCount <= 2)
                Button { addThreshold() } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .disabled(thresholdCount >= 8)
            }

            ForEach(0..<thresholdCount, id: \.self) { i in
                HStack(spacing: 4) {
                    Text("T\(i + 1)")
                        .font(.system(size: 9, design: .monospaced))
                        .frame(width: 20)
                    Slider(value: thresholdBinding(at: i), in: 0...255, step: 1)
                        .controlSize(.small)
                    Text("\(Int(thresholdValue(at: i)))")
                        .font(.system(size: 9, design: .monospaced))
                        .frame(width: 24)
                }
            }
        }
    }

    // MARK: - Threshold Helpers

    private var thresholdCount: Int {
        switch viewModel.mediumParams {
        case .troisCrayon(let p): return p.thresholds.count
        case .charcoal(let p): return p.thresholds.count
        case .graphite(let p): return p.thresholds.count
        default: return 0
        }
    }

    private func thresholdValue(at index: Int) -> Double {
        switch viewModel.mediumParams {
        case .troisCrayon(let p):
            guard index < p.thresholds.count else { return 0 }
            return Double(p.thresholds[index])
        case .charcoal(let p):
            guard index < p.thresholds.count else { return 0 }
            return Double(p.thresholds[index])
        case .graphite(let p):
            guard index < p.thresholds.count else { return 0 }
            return Double(p.thresholds[index])
        default: return 0
        }
    }

    private func thresholdBinding(at index: Int) -> Binding<Double> {
        Binding(
            get: { thresholdValue(at: index) },
            set: { newValue in
                let intValue = Int(newValue)
                switch viewModel.mediumParams {
                case .troisCrayon(var p):
                    guard index < p.thresholds.count else { return }
                    p.thresholds[index] = intValue
                    viewModel.updateParams(.troisCrayon(p), commandName: "Change Threshold \(index + 1)")
                case .charcoal(var p):
                    guard index < p.thresholds.count else { return }
                    p.thresholds[index] = intValue
                    viewModel.updateParams(.charcoal(p), commandName: "Change Threshold \(index + 1)")
                case .graphite(var p):
                    guard index < p.thresholds.count else { return }
                    p.thresholds[index] = intValue
                    viewModel.updateParams(.graphite(p), commandName: "Change Threshold \(index + 1)")
                default: break
                }
            }
        )
    }

    private func addThreshold() {
        switch viewModel.mediumParams {
        case .troisCrayon(var p):
            guard p.thresholds.count < 8 else { return }
            let last = p.thresholds.last ?? 200
            p.thresholds.append(min(255, last + 20))
            viewModel.updateParams(.troisCrayon(p), commandName: "Add Threshold")
        case .charcoal(var p):
            guard p.thresholds.count < 8 else { return }
            let last = p.thresholds.last ?? 200
            p.thresholds.append(min(255, last + 20))
            viewModel.updateParams(.charcoal(p), commandName: "Add Threshold")
        case .graphite(var p):
            guard p.thresholds.count < 8 else { return }
            let last = p.thresholds.last ?? 200
            p.thresholds.append(min(255, last + 20))
            viewModel.updateParams(.graphite(p), commandName: "Add Threshold")
        default: break
        }
    }

    private func removeThreshold() {
        switch viewModel.mediumParams {
        case .troisCrayon(var p):
            guard p.thresholds.count > 2 else { return }
            p.thresholds.removeLast()
            viewModel.updateParams(.troisCrayon(p), commandName: "Remove Threshold")
        case .charcoal(var p):
            guard p.thresholds.count > 2 else { return }
            p.thresholds.removeLast()
            viewModel.updateParams(.charcoal(p), commandName: "Remove Threshold")
        case .graphite(var p):
            guard p.thresholds.count > 2 else { return }
            p.thresholds.removeLast()
            viewModel.updateParams(.graphite(p), commandName: "Remove Threshold")
        default: break
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    // MARK: - Preset Thumbnail Generation

    private func generatePresetThumbnailsIfNeeded() {
        guard let source = viewModel.croppedImage ?? viewModel.sourceImage else { return }

        let sourceHash = ObjectIdentifier(source).hashValue
        let presets = presetsForCurrentMedium()

        if sourceHash == thumbnailSourceHash {
            // Source unchanged — only regenerate if medium changed and we're missing keys
            if presets.allSatisfy({ presetThumbnails[$0.name] != nil }) { return }
        } else {
            // New source image — clear all cached thumbnails
            thumbnailSourceHash = sourceHash
            presetThumbnails.removeAll()
        }

        startThumbnailGeneration(source: source)
    }

    private func startThumbnailGeneration(source: NSImage) {
        thumbnailTask?.cancel()

        let presets = presetsForCurrentMedium()
        let thumbSource = downsampleForThumbnail(source, targetWidth: 150)
        let renderer = OpenCVStudioRenderer()

        thumbnailTask = Task {
            await withTaskGroup(of: (String, NSImage?).self) { group in
                for preset in presets {
                    group.addTask {
                        do {
                            let result = try await renderer.render(
                                image: thumbSource,
                                medium: preset.params.medium,
                                params: viewModel.params,
                                progress: { _ in }
                            )
                            return (preset.name, result)
                        } catch {
                            return (preset.name, nil)
                        }
                    }
                }

                for await (name, image) in group {
                    if Task.isCancelled { return }
                    if let image {
                        await MainActor.run {
                            presetThumbnails[name] = image
                        }
                    }
                }
            }
        }
    }

    private func downsampleForThumbnail(_ image: NSImage, targetWidth: CGFloat) -> NSImage {
        let aspect = image.size.height / image.size.width
        let newW = Int(targetWidth)
        let newH = Int(targetWidth * aspect)
        guard newW > 0, newH > 0 else { return image }

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(
                data: nil,
                width: newW,
                height: newH,
                bitsPerComponent: 8,
                bytesPerRow: newW * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            let resized = NSImage(size: NSSize(width: newW, height: newH))
            resized.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: NSSize(width: newW, height: newH)),
                       from: NSRect(origin: .zero, size: image.size),
                       operation: .copy, fraction: 1.0)
            resized.unlockFocus()
            return resized
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        guard let downsampled = context.makeImage() else { return image }
        return NSImage(cgImage: downsampled, size: NSSize(width: newW, height: newH))
    }

    // MARK: - Preset Definitions

    private struct Preset {
        let name: String
        let icon: String
        let params: MediumParams
    }

    private func presetsForCurrentMedium() -> [Preset] {
        let medium = viewModel.selectedMedium
        let defaults = MediumParams.defaults(for: medium)

        // Always include Default; add medium-specific named presets
        var presets: [Preset] = [
            Preset(name: "Default", icon: "slider.horizontal.3", params: defaults)
        ]

        // Oil: numColors, bilateralD, sigmaColor, sigmaSpace, pruneMinPixels, brushTexture
        // Watercolor: numColors, washIntensity, bleedAmount, paperWetness
        // Charcoal: blurRadius, thresholds, contrast, paperRoughness, smudgeAmount
        // Graphite: blurRadius, thresholds, contrast, paperTexture, noiseStrength, sharpAmount
        // TroisCrayon: blurRadius, thresholds, sanguineColor, paperColor, contrast
        // InkWash: numBands, blurAmount, edgeStrength, inkDensity
        // Pastel: numColors, softness, saturation, textureGrain
        // PenAndInk: edgeSensitivity, lineWeight, contrast

        switch medium {
        case .oil:
            if case let .oil(base) = defaults {
                var heavy = base
                heavy.brushTexture = min(base.brushTexture + 0.25, 1.0)
                heavy.sigmaColor = base.sigmaColor * 1.3
                presets.append(Preset(name: "Heavy Texture", icon: "paintbrush.pointed.fill", params: .oil(heavy)))

                var smooth = base
                smooth.sigmaColor = base.sigmaColor * 1.5
                smooth.sigmaSpace = base.sigmaSpace * 1.5
                smooth.brushTexture = base.brushTexture * 0.4
                presets.append(Preset(name: "Smooth Blend", icon: "drop.fill", params: .oil(smooth)))

                var detailed = base
                detailed.numColors = min(base.numColors + 6, 24)
                detailed.bilateralD = max(base.bilateralD - 4, 5)
                presets.append(Preset(name: "High Detail", icon: "sun.max.fill", params: .oil(detailed)))
            }

        case .watercolor:
            if case let .watercolor(base) = defaults {
                var wetOnWet = base
                wetOnWet.paperWetness = min(base.paperWetness + 0.3, 1.0)
                wetOnWet.bleedAmount = min(base.bleedAmount * 1.5, 15.0)
                presets.append(Preset(name: "Wet-on-Wet", icon: "drop.triangle.fill", params: .watercolor(wetOnWet)))

                var dryBrush = base
                dryBrush.paperWetness = base.paperWetness * 0.3
                dryBrush.washIntensity = base.washIntensity * 0.6
                presets.append(Preset(name: "Dry Brush", icon: "paintbrush.fill", params: .watercolor(dryBrush)))

                var delicate = base
                delicate.numColors = max(base.numColors - 3, 3)
                delicate.paperWetness = min(base.paperWetness + 0.15, 1.0)
                presets.append(Preset(name: "Delicate", icon: "leaf.fill", params: .watercolor(delicate)))
            }

        case .charcoal:
            if case let .charcoal(base) = defaults {
                var bold = base
                bold.contrast = min(base.contrast * 1.3, 200.0)
                bold.smudgeAmount = min(base.smudgeAmount * 1.5, 5.0)
                presets.append(Preset(name: "Bold & Dark", icon: "circle.fill", params: .charcoal(bold)))

                var soft = base
                soft.smudgeAmount = min(base.smudgeAmount * 2.0, 5.0)
                soft.blurRadius = min(base.blurRadius * 2.0, 3.0)
                soft.contrast = base.contrast * 0.7
                presets.append(Preset(name: "Soft & Smooth", icon: "circle.lefthalf.filled", params: .charcoal(soft)))

                var detailed = base
                detailed.blurRadius = max(base.blurRadius * 0.3, 0.1)
                detailed.smudgeAmount = max(base.smudgeAmount * 0.5, 0.5)
                detailed.paperRoughness = min(base.paperRoughness + 0.2, 1.0)
                presets.append(Preset(name: "High Detail", icon: "line.3.crossed.swirl.circle.fill", params: .charcoal(detailed)))
            }

        case .graphite:
            if case let .graphite(base) = defaults {
                var fine = base
                fine.blurRadius = max(base.blurRadius * 0.3, 0.1)
                fine.noiseStrength = min(base.noiseStrength * 1.3, 15.0)
                presets.append(Preset(name: "Fine Hatching", icon: "line.diagonal", params: .graphite(fine)))

                var soft = base
                soft.blurRadius = min(base.blurRadius * 2.5, 3.0)
                soft.noiseStrength = base.noiseStrength * 0.4
                presets.append(Preset(name: "Soft Pencil", icon: "pencil", params: .graphite(soft)))

                var highContrast = base
                highContrast.contrast = min(base.contrast * 1.4, 200.0)
                presets.append(Preset(name: "High Contrast", icon: "circle.lefthalf.filled", params: .graphite(highContrast)))
            }

        case .troisCrayon:
            if case let .troisCrayon(base) = defaults {
                var highContrast = base
                highContrast.contrast = min(base.contrast * 1.3, 200.0)
                presets.append(Preset(name: "High Contrast", icon: "flame.fill", params: .troisCrayon(highContrast)))

                var softTones = base
                softTones.contrast = base.contrast * 0.7
                softTones.blurRadius = min(base.blurRadius * 1.3, 40.0)
                presets.append(Preset(name: "Soft Tones", icon: "circle.fill", params: .troisCrayon(softTones)))

                var detailed = base
                detailed.blurRadius = max(base.blurRadius * 0.5, 1.0)
                presets.append(Preset(name: "Fine Detail", icon: "equal.circle.fill", params: .troisCrayon(detailed)))
            }

        case .inkWash:
            if case let .inkWash(base) = defaults {
                var bold = base
                bold.inkDensity = min(base.inkDensity + 0.25, 1.0)
                bold.edgeStrength = min(base.edgeStrength + 0.2, 1.0)
                presets.append(Preset(name: "Bold Ink", icon: "paintbrush.fill", params: .inkWash(bold)))

                var dilute = base
                dilute.inkDensity = base.inkDensity * 0.5
                dilute.blurAmount = min(base.blurAmount * 1.5, 12.0)
                presets.append(Preset(name: "Dilute Wash", icon: "drop.fill", params: .inkWash(dilute)))

                var detailed = base
                detailed.numBands = min(base.numBands + 2, 8)
                detailed.edgeStrength = min(base.edgeStrength + 0.3, 1.0)
                presets.append(Preset(name: "High Detail", icon: "textformat", params: .inkWash(detailed)))
            }

        case .pastel:
            if case let .pastel(base) = defaults {
                var softBlend = base
                softBlend.softness = min(base.softness * 1.6, 8.0)
                presets.append(Preset(name: "Soft Blend", icon: "cloud.fill", params: .pastel(softBlend)))

                var vivid = base
                vivid.saturation = min(base.saturation * 1.4, 2.0)
                presets.append(Preset(name: "Vivid", icon: "sun.max.fill", params: .pastel(vivid)))

                var textured = base
                textured.textureGrain = min(base.textureGrain + 0.3, 1.0)
                textured.softness = base.softness * 0.6
                presets.append(Preset(name: "Textured", icon: "square.grid.3x3.fill", params: .pastel(textured)))
            }

        case .penAndInk:
            if case let .penAndInk(base) = defaults {
                var fine = base
                fine.edgeSensitivity = max(base.edgeSensitivity - 0.2, 0.0)
                fine.lineWeight = base.lineWeight * 0.6
                presets.append(Preset(name: "Fine Lines", icon: "line.diagonal", params: .penAndInk(fine)))

                var bold = base
                bold.lineWeight = min(base.lineWeight * 1.8, 3.0)
                bold.contrast = min(base.contrast * 1.3, 2.0)
                presets.append(Preset(name: "Bold Line", icon: "pencil.tip", params: .penAndInk(bold)))

                var detailed = base
                detailed.edgeSensitivity = max(base.edgeSensitivity - 0.25, 0.0)
                detailed.contrast = min(base.contrast * 1.2, 2.0)
                presets.append(Preset(name: "High Detail", icon: "circle.grid.3x3.fill", params: .penAndInk(detailed)))
            }

        }

        return presets
    }
}
