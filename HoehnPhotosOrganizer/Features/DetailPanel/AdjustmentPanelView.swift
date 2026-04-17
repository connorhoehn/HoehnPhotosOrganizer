import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import GRDB
import SwiftUI
import UniformTypeIdentifiers

// MARK: - AdjustmentPanelView

/// Sheet for applying adjustments to one or more photos.
///
/// Layout: left pane shows a live CoreImage preview. Right pane has the sliders.
/// Save bakes adjustments into pixel data and writes a new DNG to the app's managed originals directory.
struct AdjustmentPanelView: View {

    // MARK: - Input

    let targets: [PhotoAsset]

    /// Optional external mask bindings — when provided, mask state is owned by the caller
    /// (PhotoDetailView) so MaskOverlayView and AdjustmentPanelView share the same state.
    var externalMaskLayers: Binding<[AdjustmentLayer]>? = nil
    var externalSelectedMaskId: Binding<String?>? = nil

    @Environment(\.appDatabase) private var appDatabase: AppDatabase?
    @Environment(\.dismiss) private var dismiss

    /// Injected rollback engine — publishes PhotoAdjustments when user restores a snapshot.
    @EnvironmentObject private var rollbackEngine: RollbackEngine

    // MARK: - Section expansion state (Photoshop-style collapsed by default)
    @State private var whiteBalanceExpanded = false
    @State private var toneCurveExpanded  = false
    @State private var levelsExpanded     = true   // open by default — primary controls
    @State private var colorExpanded2     = false
    @State private var colorGradingExp    = false
    @State private var hslExpanded        = false
    @State private var colorBalanceExp    = false
    @State private var calibrationExp     = false

    // MARK: - Masking state (internal fallback when no external bindings supplied)

    @State private var _maskLayers: [AdjustmentLayer] = []
    @State private var _selectedMaskId: String? = nil

    // Computed accessors — prefer external bindings when available
    private var maskLayers: [AdjustmentLayer] {
        get { externalMaskLayers?.wrappedValue ?? _maskLayers }
    }
    private var maskLayersBinding: Binding<[AdjustmentLayer]> {
        externalMaskLayers ?? $_maskLayers
    }
    private var selectedMaskId: String? {
        get { externalSelectedMaskId?.wrappedValue ?? _selectedMaskId }
    }
    private var selectedMaskIdBinding: Binding<String?> {
        externalSelectedMaskId ?? $_selectedMaskId
    }

    // MARK: - Tone Curve state

    @State private var selectedPreset: ImageAdjustment.ToneCurvePreset? = nil
    @State private var useToneCurve = false

    // MARK: - Levels state (Camera Raw controls)

    @State private var exposure: Double = 0         // -5.0 to +5.0
    @State private var contrast: Int    = 0         // -100 to +100
    @State private var highlights: Int  = 0         // -100 to +100
    @State private var shadows: Int     = 0         // -100 to +100
    @State private var whites: Int      = 0         // -100 to +100
    @State private var blacks: Int      = 0         // -100 to +100

    // MARK: - White Balance state

    @State private var temperature: Double = 0      // -100 to +100
    @State private var tint: Double        = 0      // -100 to +100

    // MARK: - Color state

    @State private var saturation: Int  = 0         // -100 to +100
    @State private var vibrance: Int    = 0         // -100 to +100

    // MARK: - Presence state

    @State private var clarity: Double  = 0         // -100 to +100
    @State private var dehaze: Double   = 0         // -100 to +100

    // MARK: - Complex colour (HSL / Color Grading / Color Balance / Calibration)

    @State private var adj = PhotoAdjustments()     // carries nested complex fields only
    @State private var selectedHSL: HSLChannelName = .red

    private enum HSLChannelName: String, CaseIterable, Identifiable {
        case red, orange, yellow, green, aqua, blue, purple, magenta
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    // MARK: - Preview state

    @State private var originalImage: NSImage? = nil
    @State private var previewImage: NSImage? = nil
    @State private var previewBaseCG: CGImage? = nil  // 512px downscale for fast live preview
    @State private var showingOriginal = false
    @State private var previewTrigger = 0             // incremented to kick off preview rebuild
    @State private var debounceTask: Task<Void, Never>? = nil

    /// Reused across every preview render — CIContext is expensive to construct, cheap to reuse.
    private static let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: true])

    /// Computes the actual image rect within the container after scaledToFit + padding.
    private static func computeImageRect(imageSize: CGSize, containerSize: CGSize, padding: CGFloat) -> CGRect {
        let innerW = containerSize.width - padding * 2
        let innerH = containerSize.height - padding * 2
        let imgAspect = imageSize.width / imageSize.height
        let containerAspect = innerW / innerH
        let fitW = imgAspect > containerAspect ? innerW : innerH * imgAspect
        let fitH = imgAspect > containerAspect ? innerW / imgAspect : innerH
        return CGRect(
            x: padding + (innerW - fitW) / 2,
            y: padding + (innerH - fitH) / 2,
            width: fitW,
            height: fitH
        )
    }

    // MARK: - Save state

    @State private var isSaving = false
    @State private var saveResult: SaveResult?

    enum SaveResult {
        case success(Int)
        case failure(String)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HStack(spacing: 0) {
                previewPane
                    .frame(minWidth: 440)

                Divider()

                VStack(spacing: 0) {
                    // Masks layer bar — always visible at top, Camera Raw style
                    maskLayerBar
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    Divider()

                    ScrollView {
                        VStack(spacing: 16) {
                            // Show per-mask sliders when a mask is selected, global sliders otherwise
                            if let selectedId = selectedMaskId,
                               let idx = maskLayers.firstIndex(where: { $0.id == selectedId }) {
                                MaskAdjustmentPanel(layer: maskLayersBinding[idx]) {
                                    maskLayersBinding.wrappedValue.remove(at: idx)
                                    selectedMaskIdBinding.wrappedValue = nil
                                    nudgePreview()
                                    Task { await persistToDB() }
                                }
                                .onChange(of: maskLayers[idx].adjustments) { nudgePreview() }
                                .onChange(of: maskLayers[idx].opacity) { nudgePreview() }
                                .onChange(of: maskLayers[idx].sources) { nudgePreview() }
                            } else {
                                whiteBalanceSection
                                toneCurveSection
                                levelsSection
                                colorSection
                                colorGradingSection
                                hslSection
                                colorBalanceSection
                                calibrationSection
                            }
                        }
                        .padding(20)
                    }

                    // Fixed feedback — always visible, never inside the scroll view.
                    if let result = saveResult {
                        resultBanner(result)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                    }
                }
                .frame(width: 400)
            }
            .frame(maxHeight: .infinity)

            Divider()
            actionBar
        }
        .frame(width: 1100, height: 820)
        .overlay(alignment: .top) {
            if showCopiedHUD {
                Text("Settings copied")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.75), in: Capsule())
                    .padding(.top, 60)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(.easeInOut(duration: 0.3), value: showCopiedHUD)
            }
        }
        .task {
            await loadFromDB()
            await loadOriginalImage()
            await loadMasksFromDB()
            // Auto-detect segments in background if no masks exist yet
            if maskLayers.isEmpty && autoSegments.isEmpty {
                await autoSegmentWithVision()
            }
        }
        .task(id: previewTrigger) { await rebuildPreview() }
        .onChange(of: adj) { nudgePreview() }
        .onKeyPress("m") {
            if !maskLayers.isEmpty { showMaskOverlay.toggle() }
            return .handled
        }
        .onReceive(rollbackEngine.currentAdjustment.compactMap { $0 }) { restored in
            applyRestoredAdjustments(restored)
        }
        .onReceive(rollbackEngine.currentMasks.compactMap { $0 }) { restoredMasks in
            if let ext = externalMaskLayers {
                ext.wrappedValue = restoredMasks
            } else {
                _maskLayers = restoredMasks
            }
            showMaskOverlay = !restoredMasks.isEmpty
            nudgePreview()
        }
        .alert("Rename Mask", isPresented: .init(
            get: { renamingMaskIndex != nil },
            set: { if !$0 { renamingMaskIndex = nil } }
        )) {
            if let idx = renamingMaskIndex, idx < maskLayers.count {
                TextField("Label", text: maskLayersBinding[idx].label)
                Button("Done") { renamingMaskIndex = nil }
            }
        }
        .confirmationDialog("Revert to Original", isPresented: $showRevertConfirm) {
            Button("Revert", role: .destructive) {
                Task { await revertToOriginal() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will discard all adjustments and masks, restoring the earliest saved state.")
        }
        .task { await loadSnapshotCount() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.title3)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Adjustments")
                    .font(.headline)
                Text(targetLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var targetLabel: String {
        targets.count == 1 ? targets[0].canonicalName : "\(targets.count) photos selected"
    }

    // MARK: - Preview pane

    @State private var showMaskOverlay = false

    private var previewPane: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            let displayed: NSImage? = showingOriginal ? originalImage : (previewImage ?? originalImage)

            if let img = displayed {
                GeometryReader { geo in
                    let imgRect = Self.computeImageRect(imageSize: img.size, containerSize: geo.size, padding: 16)

                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(16)
                        .onTapGesture {
                            if !maskLayers.isEmpty {
                                showMaskOverlay.toggle()
                            }
                        }

                    if showMaskOverlay {
                        MaskOverlayView(
                            maskLayers: maskLayersBinding,
                            selectedMaskId: selectedMaskIdBinding,
                            displayedImageRect: imgRect
                        )
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: showMaskOverlay)
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.secondary.opacity(0.4))
                    Text("No preview available")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            // Before/after toggle — bottom center
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(showingOriginal ? "Showing Original" : "Preview") {
                        showingOriginal.toggle()
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.bottom, 16)
            }
        }
    }

    // MARK: - Tone Curve

    private var toneCurveSection: some View {
        adjustmentCard("Tone Curve", isExpanded: $toneCurveExpanded) {
            Toggle("Apply tone curve", isOn: $useToneCurve)
                .toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: useToneCurve) { nudgePreview() }

            if useToneCurve {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Preset")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("Preset", selection: $selectedPreset) {
                        ForEach(ImageAdjustment.ToneCurvePreset.allCases) { preset in
                            Text(preset.rawValue).tag(Optional(preset))
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedPreset) { nudgePreview() }

                    if let preset = selectedPreset {
                        Text(curveDescription(preset))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .onAppear {
                    if selectedPreset == nil { selectedPreset = .mediumContrast }
                }
            }
        }
    }

    private func curveDescription(_ preset: ImageAdjustment.ToneCurvePreset) -> String {
        switch preset {
        case .linear:          return "No contrast adjustment — passes through unchanged."
        case .mediumContrast:  return "Gentle S-curve — lifts shadows, compresses highlights."
        case .strongContrast:  return "Strong S-curve — crushed blacks, clipped highlights."
        }
    }

    // MARK: - White Balance

    private var whiteBalanceSection: some View {
        adjustmentCard("White Balance", isExpanded: $whiteBalanceExpanded) {
            adjustmentSlider("Temperature", value: $temperature, range: -100.0...100.0, step: 1.0, format: "%.0f")
            adjustmentSlider("Tint",        value: $tint,        range: -100.0...100.0, step: 1.0, format: "%.0f")
        }
    }

    // MARK: - Levels

    private var levelsSection: some View {
        adjustmentCardWithAction("Levels", isExpanded: $levelsExpanded, action: { autoAdjustLevels() }) {
            adjustmentSlider("Exposure", value: $exposure, range: -5.0...5.0, step: 0.05, format: "%.2f")
            adjustmentSlider("Contrast",   value: intBinding($contrast),   range: -100...100)
            adjustmentSlider("Highlights", value: intBinding($highlights), range: -100...100)
            adjustmentSlider("Shadows",    value: intBinding($shadows),    range: -100...100)
            adjustmentSlider("Whites",     value: intBinding($whites),     range: -100...100)
            adjustmentSlider("Blacks",     value: intBinding($blacks),     range: -100...100)
            Divider().padding(.vertical, 2)
            adjustmentSlider("Clarity", value: $clarity, range: -100.0...100.0, step: 1.0, format: "%.0f")
            adjustmentSlider("Dehaze",  value: $dehaze,  range: -100.0...100.0, step: 1.0, format: "%.0f")
        }
    }

    // MARK: - Color

    private var colorSection: some View {
        adjustmentCard("Color", isExpanded: $colorExpanded2) {
            adjustmentSlider("Saturation", value: intBinding($saturation), range: -100...100)
            adjustmentSlider("Vibrance",   value: intBinding($vibrance),   range: -100...100)
        }
    }

    // MARK: - Color Grading

    private var colorGradingSection: some View {
        adjustmentCard("Color Grading", isExpanded: $colorGradingExp) {
            Text("Shadows").font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
            adjustmentSlider("Hue",        value: intBinding($adj.colorGrading.shadows.hue),        range: 0...360)
            adjustmentSlider("Saturation", value: intBinding($adj.colorGrading.shadows.saturation), range: 0...100)
            adjustmentSlider("Luminance",  value: intBinding($adj.colorGrading.shadows.luminance),  range: -100...100)
            Divider().padding(.vertical, 2)
            Text("Midtones").font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
            adjustmentSlider("Hue",        value: intBinding($adj.colorGrading.midtones.hue),        range: 0...360)
            adjustmentSlider("Saturation", value: intBinding($adj.colorGrading.midtones.saturation), range: 0...100)
            adjustmentSlider("Luminance",  value: intBinding($adj.colorGrading.midtones.luminance),  range: -100...100)
            Divider().padding(.vertical, 2)
            Text("Highlights").font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
            adjustmentSlider("Hue",        value: intBinding($adj.colorGrading.highlights.hue),        range: 0...360)
            adjustmentSlider("Saturation", value: intBinding($adj.colorGrading.highlights.saturation), range: 0...100)
            adjustmentSlider("Luminance",  value: intBinding($adj.colorGrading.highlights.luminance),  range: -100...100)
            Divider().padding(.vertical, 2)
            Text("Global").font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
            adjustmentSlider("Balance",  value: intBinding($adj.colorGrading.balance),  range: -100...100)
            adjustmentSlider("Blending", value: intBinding($adj.colorGrading.blending), range: 0...100)
        }
    }

    // MARK: - HSL

    private var hslSection: some View {
        adjustmentCard("HSL", isExpanded: $hslExpanded) {
            HStack(spacing: 8) {
                Text("Channel")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                Picker("Channel", selection: $selectedHSL) {
                    ForEach(HSLChannelName.allCases) { ch in Text(ch.label).tag(ch) }
                }
                .labelsHidden()
                Spacer()
            }
            let ch = hslChannelBinding(selectedHSL)
            adjustmentSlider("Hue",        value: intBinding(ch.hue),        range: -100...100)
            adjustmentSlider("Saturation", value: intBinding(ch.saturation), range: -100...100)
            adjustmentSlider("Luminance",  value: intBinding(ch.luminance),  range: -100...100)
        }
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

    // MARK: - Color Balance

    private var colorBalanceSection: some View {
        adjustmentCard("Color Balance", isExpanded: $colorBalanceExp) {
            Text("Shadows").font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
            adjustmentSlider("Red",   value: intBinding($adj.colorBalance.shadows.red),   range: -100...100)
            adjustmentSlider("Green", value: intBinding($adj.colorBalance.shadows.green), range: -100...100)
            adjustmentSlider("Blue",  value: intBinding($adj.colorBalance.shadows.blue),  range: -100...100)
            Divider().padding(.vertical, 2)
            Text("Midtones").font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
            adjustmentSlider("Red",   value: intBinding($adj.colorBalance.midtones.red),   range: -100...100)
            adjustmentSlider("Green", value: intBinding($adj.colorBalance.midtones.green), range: -100...100)
            adjustmentSlider("Blue",  value: intBinding($adj.colorBalance.midtones.blue),  range: -100...100)
            Divider().padding(.vertical, 2)
            Text("Highlights").font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
            adjustmentSlider("Red",   value: intBinding($adj.colorBalance.highlights.red),   range: -100...100)
            adjustmentSlider("Green", value: intBinding($adj.colorBalance.highlights.green), range: -100...100)
            adjustmentSlider("Blue",  value: intBinding($adj.colorBalance.highlights.blue),  range: -100...100)
        }
    }

    // MARK: - Calibration

    private var calibrationSection: some View {
        adjustmentCard("Calibration", isExpanded: $calibrationExp) {
            Text("Red Primary").font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
            adjustmentSlider("Hue",        value: intBinding($adj.calibration.red.hue),        range: -100...100)
            adjustmentSlider("Saturation", value: intBinding($adj.calibration.red.saturation), range: -100...100)
            Divider().padding(.vertical, 2)
            Text("Green Primary").font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
            adjustmentSlider("Hue",        value: intBinding($adj.calibration.green.hue),        range: -100...100)
            adjustmentSlider("Saturation", value: intBinding($adj.calibration.green.saturation), range: -100...100)
            Divider().padding(.vertical, 2)
            Text("Blue Primary").font(.caption2).fontWeight(.medium).foregroundStyle(.secondary)
            adjustmentSlider("Hue",        value: intBinding($adj.calibration.blue.hue),        range: -100...100)
            adjustmentSlider("Saturation", value: intBinding($adj.calibration.blue.saturation), range: -100...100)
        }
    }

    // MARK: - Masking section

    @State private var isAutoSegmenting = false
    @State private var autoSegments: [AppleVisionSegment] = []
    @State private var renamingMaskIndex: Int? = nil
    @State private var showRevertConfirm = false
    @State private var snapshotCount: Int = 0
    private static let visionMaskService = AppleVisionMaskService()

    // MARK: - Mask Layer Bar (Camera Raw style)

    private var maskLayerBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header row: title + auto-segment
            HStack {
                Text("Masks")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()

                if showMaskOverlay {
                    Button {
                        showMaskOverlay = false
                    } label: {
                        Image(systemName: "eye.slash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Hide mask overlay (M)")
                } else if !maskLayers.isEmpty {
                    Button {
                        showMaskOverlay = true
                    } label: {
                        Image(systemName: "eye")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Show mask overlay (M)")
                }

                Button {
                    Task { await autoSegmentWithVision() }
                } label: {
                    HStack(spacing: 3) {
                        if isAutoSegmenting {
                            ProgressView().scaleEffect(0.5)
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                        Text(isAutoSegmenting ? "..." : "Detect")
                    }
                    .font(.caption2.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isAutoSegmenting || previewBaseCG == nil)
            }

            // "Global" pseudo-layer — click to deselect all masks and show global sliders
            maskLayerRow(
                icon: "slider.horizontal.3",
                label: "Global",
                summary: globalAdjustmentSummary,
                isSelected: selectedMaskId == nil,
                isActive: .constant(true),
                onSelect: { selectedMaskIdBinding.wrappedValue = nil },
                onDelete: nil
            )

            // Mask layers — drag to reorder (compositing order = array order)
            ForEach(maskLayers.indices, id: \.self) { i in
                maskLayerRow(
                    icon: iconForMask(maskLayers[i]),
                    label: maskLayers[i].label,
                    summary: maskLayerSummary(maskLayers[i]),
                    isSelected: maskLayers[i].id == selectedMaskId,
                    isActive: maskLayersBinding[i].isActive,
                    onSelect: { selectedMaskIdBinding.wrappedValue = maskLayers[i].id },
                    onDelete: {
                        maskLayersBinding.wrappedValue.remove(at: i)
                        selectedMaskIdBinding.wrappedValue = nil
                        nudgePreview()
                        Task { await persistToDB() }
                    },
                    tintIndex: i
                )
                .contextMenu {
                    Button("Rename") { renamingMaskIndex = i }
                    Button("Duplicate") { duplicateMaskLayer(at: i) }
                    Divider()
                    Button("Delete", role: .destructive) {
                        maskLayersBinding.wrappedValue.remove(at: i)
                        selectedMaskIdBinding.wrappedValue = nil
                        nudgePreview()
                        Task { await persistToDB() }
                    }
                }
                .onChange(of: maskLayers[i].isActive) { nudgePreview() }
            }
            .onMove { source, destination in
                maskLayersBinding.wrappedValue.move(fromOffsets: source, toOffset: destination)
                nudgePreview()
                Task { await persistToDB() }
            }

            // Add Layer button — creates blank full-image mask
            Button {
                addBlankMaskLayer()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.caption2)
                    Text("Add Layer")
                        .font(.caption2.weight(.medium))
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.top, 2)

            // Detected regions (not yet added as masks)
            if !autoSegments.isEmpty {
                Divider().padding(.vertical, 2)
                Text("Detected")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                ForEach(autoSegments) { segment in
                    Button {
                        addSegmentAsMaskLayer(segment)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                            Text(segment.label)
                                .font(.caption2)
                            Spacer()
                            Text("\(String(format: "%.0f", segment.coverage * 100))%")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Mask Layer Row (Camera Raw style)

    /// Layer tint colors matching MaskOverlayView for visual consistency.
    private static let layerTintColors: [Color] = [
        Color(red: 60/255, green: 120/255, blue: 255/255),   // blue
        Color(red: 255/255, green: 140/255, blue: 60/255),   // orange
        Color(red: 80/255, green: 220/255, blue: 120/255),   // green
        Color(red: 200/255, green: 80/255, blue: 255/255),   // purple
        Color(red: 255/255, green: 80/255, blue: 100/255),   // red
        Color(red: 60/255, green: 210/255, blue: 230/255),   // cyan
        Color(red: 255/255, green: 200/255, blue: 60/255),   // yellow
    ]

    private func maskLayerRow(
        icon: String,
        label: String,
        summary: String,
        isSelected: Bool,
        isActive: Binding<Bool>,
        onSelect: @escaping () -> Void,
        onDelete: (() -> Void)?,
        tintIndex: Int? = nil
    ) -> some View {
        HStack(spacing: 8) {
            ZStack {
                if let idx = tintIndex {
                    Circle()
                        .fill(Self.layerTintColors[idx % Self.layerTintColors.count])
                        .frame(width: 8, height: 8)
                }
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white : .secondary)
            }
            .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : .primary)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                }
            }

            Spacer()

            if onDelete != nil {
                Toggle("", isOn: isActive)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.mini)

                Button {
                    onDelete?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }

    // MARK: - Adjustment summaries

    private var globalAdjustmentSummary: String {
        var parts: [String] = []
        if exposure != 0   { parts.append("Exp \(String(format: "%+.1f", exposure))") }
        if contrast != 0   { parts.append("Con \(contrast > 0 ? "+" : "")\(contrast)") }
        if highlights != 0 { parts.append("Hi \(highlights > 0 ? "+" : "")\(highlights)") }
        if shadows != 0    { parts.append("Sh \(shadows > 0 ? "+" : "")\(shadows)") }
        if saturation != 0 { parts.append("Sat \(saturation > 0 ? "+" : "")\(saturation)") }
        return parts.isEmpty ? "No changes" : parts.joined(separator: "  ")
    }

    private func adjustmentSummary(_ adj: PhotoAdjustments) -> String {
        var parts: [String] = []
        if adj.exposure != 0   { parts.append("Exp \(String(format: "%+.1f", adj.exposure))") }
        if adj.contrast != 0   { parts.append("Con \(adj.contrast > 0 ? "+" : "")\(adj.contrast)") }
        if adj.highlights != 0 { parts.append("Hi \(adj.highlights > 0 ? "+" : "")\(adj.highlights)") }
        if adj.shadows != 0    { parts.append("Sh \(adj.shadows > 0 ? "+" : "")\(adj.shadows)") }
        if adj.saturation != 0 { parts.append("Sat \(adj.saturation > 0 ? "+" : "")\(adj.saturation)") }
        return parts.isEmpty ? "No changes" : parts.joined(separator: "  ")
    }

    /// Extended summary for mask layer rows — includes edge refinement info
    private func maskLayerSummary(_ layer: AdjustmentLayer) -> String {
        var parts: [String] = []
        let adj = layer.adjustments
        if adj.exposure != 0   { parts.append("Exp \(String(format: "%+.1f", adj.exposure))") }
        if adj.contrast != 0   { parts.append("Con \(adj.contrast > 0 ? "+" : "")\(adj.contrast)") }
        if adj.saturation != 0 { parts.append("Sat \(adj.saturation > 0 ? "+" : "")\(adj.saturation)") }
        if layer.opacity < 0.99 { parts.append("\(Int(layer.opacity * 100))%") }
        if !layer.sources.isEmpty { parts.append("\(layer.sources.count) mask\(layer.sources.count == 1 ? "" : "s")") }
        return parts.isEmpty ? "No changes" : parts.joined(separator: "  ")
    }

    private func iconForMask(_ mask: AdjustmentLayer) -> String {
        if let first = mask.sources.first { return first.typeIcon }
        let label = mask.label.lowercased()
        if label.contains("person") { return "person.fill" }
        if label.contains("face") { return "face.dashed" }
        if label.contains("background") { return "square.dashed" }
        if label.contains("salient") { return "sparkles" }
        return "circle.dashed"
    }

    // MARK: - Action bar

    @Environment(AdjustmentClipboard.self) private var clipboard: AdjustmentClipboard?
    @State private var showCopiedHUD = false

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button("Reset") { resetAll() }
                .buttonStyle(.bordered)

            Button {
                showRevertConfirm = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                    Text("Revert to Original")
                    if snapshotCount > 1 {
                        Text("\(snapshotCount)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.secondary))
                    }
                }
            }
            .buttonStyle(.bordered)
            .disabled(snapshotCount == 0)

            Button {
                guard let clip = clipboard else { return }
                var toSave = adj
                toSave.exposure        = exposure
                toSave.contrast        = contrast
                toSave.highlights      = highlights
                toSave.shadows         = shadows
                toSave.whites          = whites
                toSave.blacks          = blacks
                toSave.saturation      = saturation
                toSave.vibrance        = vibrance
                toSave.useToneCurve    = useToneCurve
                toSave.toneCurvePreset = selectedPreset?.rawValue
                clip.copy(adjustment: toSave, fromPhoto: targets.first?.id ?? "")
                showCopiedHUD = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    showCopiedHUD = false
                }
            } label: {
                Label("Copy Settings", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .help("Copy all adjustment settings to clipboard")

            Spacer()

            Button("Cancel") { dismiss() }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape)

            if isSaving {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Saving…").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Button("Apply Adjustments\(targets.count > 1 ? " (\(targets.count))" : "")") {
                    Task { await saveAdjustments() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(isIdentity && !useToneCurve)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Result banner (fixed, outside ScrollView)

    private func resultBanner(_ result: SaveResult) -> some View {
        HStack(spacing: 8) {
            switch result {
            case .success(let n):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Applied to \(n) photo\(n == 1 ? "" : "s"). Library thumbnails updated.")
                    .font(.callout).foregroundStyle(.green)
            case .failure(let msg):
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(msg).font(.callout).foregroundStyle(.red)
            }
            Spacer()
            Button { saveResult = nil } label: {
                Image(systemName: "xmark").font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(bannerColor(result).opacity(0.08))
        )
    }

    private func bannerColor(_ result: SaveResult) -> Color {
        switch result {
        case .success: return .green
        case .failure: return .red
        }
    }

    // MARK: - Save

    private func saveAdjustments() async {
        guard let db = appDatabase else {
            saveResult = .failure("Database not available.")
            return
        }

        guard !isIdentity || useToneCurve else {
            saveResult = .failure("No adjustments to apply — dial in at least one control.")
            return
        }

        isSaving = true
        saveResult = nil

        let originalsDir = ProxyGenerationActor.originalsDirectory()
        let proxiesDir   = ProxyGenerationActor.proxiesDirectory()
        let thumbsDir    = ProxyGenerationActor.thumbsDirectory()

        // Capture all slider values on the MainActor before jumping off.
        let capExposure   = exposure
        let capContrast   = contrast
        let capHighlights = highlights
        let capShadows    = shadows
        let capWhites     = whites
        let capBlacks     = blacks
        let capSaturation = saturation
        let capVibrance   = vibrance
        let capTemp       = temperature
        let capTint       = tint
        let capClarity    = clarity
        let capDehaze     = dehaze
        let capMaskLayersSave = maskLayers.filter { $0.isActive }
        let capUseCurve   = useToneCurve
        let capPreset     = selectedPreset
        let capAdj        = adj

        var successCount = 0
        var lastError: String? = nil

        for photo in targets {
            let sourceURL = URL(fileURLWithPath: photo.filePath)
            let baseName  = (photo.canonicalName as NSString).deletingPathExtension
            let dngURL    = originalsDir.appendingPathComponent(baseName + ".dng")
            let proxyURL  = proxiesDir.appendingPathComponent(baseName + ".jpg")
            let thumbURL  = thumbsDir.appendingPathComponent(baseName + ".jpg")

            // --- Step 0: resolve original source file (non-destructive editing) ---
            // Always render from the pristine original, never the proxy (which may have prior bakes).
            let originalPath = await resolveOriginalPath(photo: photo, db: db)
            let originalURL = URL(fileURLWithPath: originalPath)

            // --- Step 1: load source CGImage from original (with proxy fallback) ---
            let proxyFallbackURL = proxiesDir.appendingPathComponent(baseName + ".jpg")
            let loadedCG = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                // Try the resolved original first
                let hint: CFDictionary? = originalURL.pathExtension.lowercased() == "dng"
                    ? [kCGImageSourceTypeIdentifierHint: UTType.tiff.identifier] as CFDictionary
                    : nil
                if let src = CGImageSourceCreateWithURL(originalURL as CFURL, hint),
                   let cg  = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                    return cg
                }
                // Proxy fallback — source may be sandboxed or on unmounted drive
                if let src = CGImageSourceCreateWithURL(proxyFallbackURL as CFURL, nil),
                   let cg  = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                    print("[AdjustmentPanel] Using proxy fallback for \(baseName)")
                    return cg
                }
                return nil
            }.value

            guard let sourceCG = loadedCG else {
                lastError = "Could not load image for \(photo.canonicalName)."
                continue
            }

            // --- Step 2: apply adjustments via CoreImage (shared pipeline) ---
            let renderResult = await Task.detached(priority: .userInitiated) { () -> Result<CGImage, Error> in
                var ci = CIImage(cgImage: sourceCG)

                // 1. Temperature/Tint
                ci = AdjustmentFilterPipeline.applyTemperatureTint(ci, temperature: capTemp, tint: capTint)

                // 2. Exposure
                if abs(capExposure) > 0.01 {
                    let f = CIFilter(name: "CIExposureAdjust")!
                    f.setValue(ci, forKey: kCIInputImageKey)
                    f.setValue(Float(capExposure), forKey: "inputEV")
                    if let out = f.outputImage { ci = out }
                }

                // 3. Contrast + Saturation
                let contrastFactor   = Float(1.0 + Double(capContrast) / 667.0)
                let saturationFactor = Float(max(0, 1.0 + Double(capSaturation) / 100.0))
                if abs(contrastFactor - 1) > 0.005 || abs(saturationFactor - 1) > 0.005 {
                    let f = CIFilter(name: "CIColorControls")!
                    f.setValue(ci, forKey: kCIInputImageKey)
                    f.setValue(contrastFactor,   forKey: kCIInputContrastKey)
                    f.setValue(saturationFactor, forKey: kCIInputSaturationKey)
                    if let out = f.outputImage { ci = out }
                }

                // 4. Vibrance
                if capVibrance != 0, let f = CIFilter(name: "CIVibrance") {
                    f.setValue(ci, forKey: kCIInputImageKey)
                    f.setValue(Float(capVibrance) / 100.0, forKey: "inputAmount")
                    if let out = f.outputImage { ci = out }
                }

                // 5. Highlights/Shadows
                ci = AdjustmentFilterPipeline.applyHighlightsShadows(ci, highlights: capHighlights, shadows: capShadows)

                // 6. Whites/Blacks
                ci = AdjustmentFilterPipeline.applyWhitesBlacks(ci, whites: capWhites, blacks: capBlacks)

                // 7. Dehaze
                ci = AdjustmentFilterPipeline.applyDehaze(ci, amount: capDehaze)

                // 8. HSL / Color Grading / Color Balance / Calibration — 3D LUT
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

                // 9. Clarity
                ci = AdjustmentFilterPipeline.applyClarity(ci, amount: capClarity)

                // 10. Tone curve preset
                if capUseCurve, let preset = capPreset {
                    let pts = preset.points
                    if pts.count >= 5 {
                        let f = CIFilter(name: "CIToneCurve")!
                        f.setValue(ci, forKey: kCIInputImageKey)
                        let vecs = pts.prefix(5).map { CIVector(x: CGFloat($0.input) / 255,
                                                                 y: CGFloat($0.output) / 255) }
                        f.setValue(vecs[0], forKey: "inputPoint0")
                        f.setValue(vecs[1], forKey: "inputPoint1")
                        f.setValue(vecs[2], forKey: "inputPoint2")
                        f.setValue(vecs[3], forKey: "inputPoint3")
                        f.setValue(vecs[4], forKey: "inputPoint4")
                        if let out = f.outputImage { ci = out }
                    }
                }

                // 11. Apply mask layers via CIBlendWithMask
                if !capMaskLayersSave.isEmpty {
                    ci = MaskRenderingService.applyAdjustmentLayers(
                        capMaskLayersSave,
                        base: ci,
                        sourceCG: sourceCG
                    )
                }

                guard let cg = Self.sharedCIContext.createCGImage(ci, from: ci.extent,
                                                                   format: .RGBA8,
                                                                   colorSpace: CGColorSpaceCreateDeviceRGB()) else {
                    return .failure(NSError(domain: "AdjustmentPanel", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "CoreImage render failed."]))
                }
                return .success(cg)
            }.value

            let adjustedCG: CGImage
            switch renderResult {
            case .success(let cg): adjustedCG = cg
            case .failure(let err):
                print("[AdjustmentPanel] Render failed for \(photo.canonicalName): \(err)")
                lastError = err.localizedDescription
                continue
            }

            // --- Step 3: write DNG + proxy + thumbnail to app-managed dirs ---
            let writeResult = await Task.detached(priority: .userInitiated) { () -> Result<Int, Error> in
                do {
                    try MinimalDNGWriter.write(adjustedCG, to: dngURL)

                    let proxyCG = Self.scale(adjustedCG, maxEdge: 1600) ?? adjustedCG
                    try Self.writeJPEG(proxyCG, to: proxyURL)

                    let thumbCG = Self.scale(adjustedCG, maxEdge: 300) ?? adjustedCG
                    try Self.writeJPEG(thumbCG, to: thumbURL)

                    let attrs = try? FileManager.default.attributesOfItem(atPath: dngURL.path)
                    return .success(attrs?[.size] as? Int ?? 0)
                } catch {
                    return .failure(error)
                }
            }.value

            switch writeResult {
            case .success(let newSize):
                successCount += 1
                let stampNow = ISO8601DateFormatter().string(from: Date())
                try? await db.dbPool.write { d in
                    try d.execute(
                        sql: "UPDATE photo_assets SET file_path = ?, file_size = ?, updated_at = ? WHERE id = ?",
                        arguments: [dngURL.path, newSize, stampNow, photo.id]
                    )
                }
                let maskInfo = capMaskLayersSave.isEmpty ? "" : " + \(capMaskLayersSave.count) mask\(capMaskLayersSave.count == 1 ? "" : "s")"
                let detail = "exp:\(String(format:"%.2f", capExposure)) contrast:\(capContrast) sat:\(capSaturation)\(maskInfo)"
                let activity = ActivityDB(
                    id: UUID().uuidString,
                    kind: "adjustment",
                    title: "Adjustments baked to DNG",
                    detail: "\(photo.canonicalName): \(detail)",
                    photoId: photo.id,
                    timestamp: stampNow
                )
                try? await db.dbPool.write { d in try activity.insert(d) }
            case .failure(let err):
                print("[AdjustmentPanel] Write failed for \(photo.canonicalName): \(err)")
                lastError = err.localizedDescription
            }
        }

        if successCount > 0 {
            // Non-destructive: keep sliders/masks as-is. They're persisted in DB
            // and the snapshot, so reopening the panel restores the full editing state.
            // The baked DNG + proxy reflect the current adjustments.
            await persistToDB()
            saveResult = .success(successCount)
        } else {
            saveResult = .failure(lastError ?? "Failed to embed adjustments.")
        }

        isSaving = false
    }

    // MARK: - Reset

    private func resetAll() {
        useToneCurve = false
        selectedPreset = nil
        exposure = 0; contrast = 0; highlights = 0
        shadows = 0; whites = 0; blacks = 0
        saturation = 0; vibrance = 0
        adj = PhotoAdjustments()
        maskLayersBinding.wrappedValue.removeAll()
        selectedMaskIdBinding.wrappedValue = nil
        autoSegments.removeAll()
        showMaskOverlay = false
        saveResult = nil
        nudgePreview()
        Task { await clearPersistedAdjustments() }
    }

    private func clearPersistedAdjustments() async {
        guard let db = appDatabase else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        for photo in targets {
            try? await db.dbPool.write { d in
                try d.execute(
                    sql: "UPDATE photo_assets SET adjustments_json = NULL, masks_json = NULL, updated_at = ? WHERE id = ?",
                    arguments: [now, photo.id]
                )
            }
        }
    }

    private var isIdentity: Bool {
        let toneIdentity   = exposure == 0 && contrast == 0 && highlights == 0
        let shadowIdentity = shadows == 0 && whites == 0 && blacks == 0
        let colorIdentity  = saturation == 0 && vibrance == 0
        let wbIdentity     = temperature == 0 && tint == 0
        let presIdentity   = clarity == 0 && dehaze == 0
        let hasMaskAdj     = maskLayers.contains { $0.isActive && !$0.adjustments.isIdentity }
        return toneIdentity && shadowIdentity && colorIdentity && wbIdentity && presIdentity && ColorGradingLUTBuilder.isIdentity(adj) && !hasMaskAdj
    }

    // MARK: - Rollback support

    /// Apply a restored PhotoAdjustments snapshot to all sliders.
    private func applyRestoredAdjustments(_ saved: PhotoAdjustments) {
        exposure      = saved.exposure
        contrast      = saved.contrast
        highlights    = saved.highlights
        shadows       = saved.shadows
        whites        = saved.whites
        blacks        = saved.blacks
        saturation    = saved.saturation
        vibrance      = saved.vibrance
        temperature   = saved.temperature
        tint          = saved.tint
        clarity       = saved.clarity
        dehaze        = saved.dehaze
        useToneCurve  = saved.useToneCurve
        selectedPreset = saved.toneCurvePreset.flatMap {
            ImageAdjustment.ToneCurvePreset(rawValue: $0)
        }
        adj.colorGrading = saved.colorGrading
        adj.hsl          = saved.hsl
        adj.colorBalance = saved.colorBalance
        adj.calibration  = saved.calibration
        nudgePreview()
    }

    // MARK: - Layer helpers

    private func addBlankMaskLayer() {
        let layer = AdjustmentLayer(
            label: "Layer \(maskLayers.count + 1)",
            adjustments: PhotoAdjustments()
        )
        maskLayersBinding.wrappedValue.append(layer)
        selectedMaskIdBinding.wrappedValue = layer.id
        showMaskOverlay = true
        nudgePreview()
        Task { await persistToDB() }
    }

    private func duplicateMaskLayer(at index: Int) {
        guard index < maskLayers.count else { return }
        var copy = maskLayers[index]
        copy.id = UUID().uuidString
        copy.label = copy.label + " Copy"
        copy.createdAt = ISO8601DateFormatter().string(from: .now)
        maskLayersBinding.wrappedValue.insert(copy, at: index + 1)
        selectedMaskIdBinding.wrappedValue = copy.id
        nudgePreview()
        Task { await persistToDB() }
    }

    // MARK: - Revert to Original

    private func revertToOriginal() async {
        guard let db = appDatabase, let photo = targets.first else { return }
        let snapshotRepo = AdjustmentSnapshotRepository(db: db)
        guard let snapshots = try? await snapshotRepo.fetchSnapshots(forPhoto: photo.id),
              let earliest = snapshots.first else { return }
        try? await rollbackEngine.rollback(to: earliest, photoAssetId: photo.id)
    }

    private func loadSnapshotCount() async {
        guard let db = appDatabase, let photo = targets.first else { return }
        let snapshotRepo = AdjustmentSnapshotRepository(db: db)
        let snapshots = (try? await snapshotRepo.fetchSnapshots(forPhoto: photo.id)) ?? []
        snapshotCount = snapshots.count
    }

    // MARK: - Apple Vision Auto-Segmentation

    private func autoSegmentWithVision() async {
        guard let baseCG = previewBaseCG else { return }
        isAutoSegmenting = true

        // Check segmentation cache first
        if let db = appDatabase, let photo = targets.first {
            let cacheRepo = SegmentationCacheRepository(db: db)
            if let cachedJSON = try? await cacheRepo.fetchSegments(forPhoto: photo.id),
               let cached = Self.decodeSegmentsCache(cachedJSON) {
                autoSegments = cached
                showMaskOverlay = true
                isAutoSegmenting = false
                return
            }
        }

        do {
            let segments = try await Self.visionMaskService.generateSegments(from: baseCG)
            autoSegments = segments
            showMaskOverlay = true

            // Store in cache
            if let db = appDatabase, let photo = targets.first {
                let cacheRepo = SegmentationCacheRepository(db: db)
                if let json = Self.encodeSegmentsCache(segments) {
                    try? await cacheRepo.storeSegments(forPhoto: photo.id, segmentsJSON: json)
                }
            }
        } catch {
            print("[AdjustmentPanelView] Vision segmentation failed: \(error)")
        }
        isAutoSegmenting = false
    }

    // MARK: - Segment cache serialization

    private struct CachedSegment: Codable {
        let id: Int
        let label: String
        let kind: String
        let maskPixelsBase64: String
        let width: Int
        let height: Int
        let coverage: Float
    }

    private static func encodeSegmentsCache(_ segments: [AppleVisionSegment]) -> String? {
        let cached = segments.map { seg in
            CachedSegment(
                id: seg.id,
                label: seg.label,
                kind: seg.kind.rawValue,
                maskPixelsBase64: Data(seg.maskPixels).base64EncodedString(),
                width: seg.width,
                height: seg.height,
                coverage: seg.coverage
            )
        }
        guard let data = try? JSONEncoder().encode(cached) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeSegmentsCache(_ json: String) -> [AppleVisionSegment]? {
        guard let data = json.data(using: .utf8),
              let cached = try? JSONDecoder().decode([CachedSegment].self, from: data) else { return nil }
        return cached.compactMap { cs in
            guard let kind = AppleVisionSegment.SegmentKind(rawValue: cs.kind),
                  let pixelData = Data(base64Encoded: cs.maskPixelsBase64) else { return nil }
            return AppleVisionSegment(
                id: cs.id,
                label: cs.label,
                kind: kind,
                maskPixels: Array(pixelData),
                width: cs.width,
                height: cs.height,
                coverage: cs.coverage
            )
        }
    }

    private func addSegmentAsMaskLayer(_ segment: AppleVisionSegment) {
        let layer = AdjustmentLayer(
            label: segment.label,
            sources: [MaskSource(sourceType: .bitmap(rle: Data(segment.maskPixels), width: segment.width, height: segment.height))]
        )
        maskLayersBinding.wrappedValue.append(layer)
        selectedMaskIdBinding.wrappedValue = layer.id
        showMaskOverlay = true
        // Remove from auto-segments list once added
        autoSegments.removeAll { $0.id == segment.id }
        nudgePreview()
    }

    private func colorForSegmentKind(_ kind: AppleVisionSegment.SegmentKind) -> Color {
        switch kind {
        case .person:       return .blue
        case .personFace:   return .orange
        case .foreground:   return .green
        case .background:   return .purple
        case .sky:          return .cyan
        case .salientObject: return .yellow
        }
    }

    // MARK: - DB persistence

    private func loadFromDB() async {
        guard let db = appDatabase,
              let photo = targets.first else { return }

        let json = try? await db.dbPool.read { d -> String? in
            try String.fetchOne(d, sql: "SELECT adjustments_json FROM photo_assets WHERE id = ?",
                                arguments: [photo.id])
        }
        guard let json, let saved = PhotoAdjustments.decode(from: json) else { return }

        exposure      = saved.exposure
        contrast      = saved.contrast
        highlights    = saved.highlights
        shadows       = saved.shadows
        whites        = saved.whites
        blacks        = saved.blacks
        saturation    = saved.saturation
        vibrance      = saved.vibrance
        temperature   = saved.temperature
        tint          = saved.tint
        clarity       = saved.clarity
        dehaze        = saved.dehaze
        useToneCurve  = saved.useToneCurve
        if let presetName = saved.toneCurvePreset {
            selectedPreset = ImageAdjustment.ToneCurvePreset(rawValue: presetName)
        }
        adj.colorGrading = saved.colorGrading
        adj.hsl          = saved.hsl
        adj.colorBalance = saved.colorBalance
        adj.calibration  = saved.calibration
        nudgePreview()
    }

    private func loadMasksFromDB() async {
        guard let db = appDatabase,
              let photo = targets.first else { return }
        let masksJson = try? await db.dbPool.read { d -> String? in
            try String.fetchOne(d, sql: "SELECT masks_json FROM photo_assets WHERE id = ?",
                                arguments: [photo.id])
        }
        let decoded = MaskLayerStore.decode(from: masksJson)
        if let ext = externalMaskLayers {
            ext.wrappedValue = decoded
        } else {
            _maskLayers = decoded
        }
    }

    private func persistToDB() async {
        guard let db = appDatabase else { return }

        var toSave = adj
        toSave.exposure        = exposure
        toSave.contrast        = contrast
        toSave.highlights      = highlights
        toSave.shadows         = shadows
        toSave.whites          = whites
        toSave.blacks          = blacks
        toSave.saturation      = saturation
        toSave.vibrance        = vibrance
        toSave.temperature     = temperature
        toSave.tint            = tint
        toSave.clarity         = clarity
        toSave.dehaze          = dehaze
        toSave.useToneCurve    = useToneCurve
        toSave.toneCurvePreset = selectedPreset?.rawValue

        guard let json = toSave.encodeToJSON() else { return }
        let now = ISO8601DateFormatter().string(from: Date())

        let masksStr = MaskLayerStore.encode(maskLayers)

        for photo in targets {
            try? await db.dbPool.write { d in
                try d.execute(
                    sql: "UPDATE photo_assets SET adjustments_json = ?, updated_at = ? WHERE id = ?",
                    arguments: [json, now, photo.id]
                )
            }

            // Persist masks_json
            try? await db.dbPool.write { d in
                if let masksStr {
                    try d.execute(
                        sql: "UPDATE photo_assets SET masks_json = ? WHERE id = ?",
                        arguments: [masksStr, photo.id]
                    )
                } else {
                    try d.execute(
                        sql: "UPDATE photo_assets SET masks_json = NULL WHERE id = ?",
                        arguments: [photo.id]
                    )
                }
            }

            // Snapshot for rollback history (includes masks)
            let snapshot = AdjustmentSnapshot(
                id: UUID().uuidString,
                photoAssetId: photo.id,
                label: nil,
                adjustmentJSON: json,
                masksJSON: masksStr,
                thumbnailPath: nil,
                isCurrentState: true,
                createdAt: Date()
            )
            let snapshotRepo = AdjustmentSnapshotRepository(db: db)
            try? await snapshotRepo.saveSnapshot(snapshot)
        }
    }

    // MARK: - Non-destructive original preservation

    /// Resolve the pristine original file path for a photo.
    /// On first bake, copies the source file to the originals directory and records the path
    /// in `original_file_path` so future bakes always start from untouched pixels.
    private func resolveOriginalPath(photo: PhotoAsset, db: AppDatabase) async -> String {
        // Check if we already have a saved original
        let existingOriginal = try? await db.dbPool.read { d -> String? in
            try String.fetchOne(d,
                sql: "SELECT original_file_path FROM photo_assets WHERE id = ?",
                arguments: [photo.id])
        }

        if let orig = existingOriginal, FileManager.default.fileExists(atPath: orig) {
            return orig
        }

        // First bake — preserve the current source file as the original
        let sourceURL = URL(fileURLWithPath: photo.filePath)
        let originalsDir = ProxyGenerationActor.originalsDirectory()
        let baseName = (photo.canonicalName as NSString).deletingPathExtension
        let ext = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension
        let preservedURL = originalsDir.appendingPathComponent("_original_\(baseName).\(ext)")

        // Copy (not move) the source file to preserve the original — only if accessible
        if !FileManager.default.fileExists(atPath: preservedURL.path),
           FileManager.default.isReadableFile(atPath: sourceURL.path) {
            try? FileManager.default.copyItem(at: sourceURL, to: preservedURL)
        }

        // Record in DB if copy succeeded
        if FileManager.default.fileExists(atPath: preservedURL.path) {
            let now = ISO8601DateFormatter().string(from: Date())
            try? await db.dbPool.write { d in
                try d.execute(
                    sql: "UPDATE photo_assets SET original_file_path = ?, updated_at = ? WHERE id = ?",
                    arguments: [preservedURL.path, now, photo.id]
                )
            }
            return preservedURL.path
        }

        // Fallback: use proxy JPEG when source is not accessible (drive not mounted / sandbox)
        if let pp = photo.proxyPath, FileManager.default.fileExists(atPath: pp) {
            return pp
        }
        let proxyURL = ProxyGenerationActor.proxiesDirectory()
            .appendingPathComponent(baseName + ".jpg")
        if FileManager.default.fileExists(atPath: proxyURL.path) {
            return proxyURL.path
        }

        // Last resort: return file_path even though it may not be accessible
        return photo.filePath
    }

    // MARK: - Image loading

    private func loadOriginalImage() async {
        guard let photo = targets.first else { return }
        let baseName  = (photo.canonicalName as NSString).deletingPathExtension
        let sourceURL = URL(fileURLWithPath: photo.filePath)

        // Prefer the pristine original for preview (avoids stacking adjustments on baked pixels)
        let originalPath: String? = if let db = appDatabase {
            try? await db.dbPool.read { d -> String? in
                try String.fetchOne(d,
                    sql: "SELECT original_file_path FROM photo_assets WHERE id = ?",
                    arguments: [photo.id])
            }
        } else {
            nil
        }

        let proxyPath = photo.proxyPath
        let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            // Try pristine original first
            if let origPath = originalPath,
               let origImg = NSImage(contentsOfFile: origPath) {
                return origImg
            }
            // Fall back to current source file
            let opts: CFDictionary? = sourceURL.pathExtension.lowercased() == "dng"
                ? [kCGImageSourceTypeIdentifierHint: UTType.tiff.identifier] as CFDictionary
                : nil
            if let src = CGImageSourceCreateWithURL(sourceURL as CFURL, opts),
               let cg  = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            // Fall back to proxy JPEG (source drive may not be mounted)
            if let pp = proxyPath, let proxyImg = NSImage(contentsOfFile: pp) {
                return proxyImg
            }
            let proxyURL = ProxyGenerationActor.proxiesDirectory()
                .appendingPathComponent(baseName + ".jpg")
            return NSImage(contentsOf: proxyURL)
        }.value
        originalImage = img
        previewImage  = img
        // Build 512px preview base for fast live renders (~10× fewer pixels than 1600px proxy)
        if let cg = img?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            previewBaseCG = await Task.detached(priority: .userInitiated) {
                Self.scale(cg, maxEdge: 512) ?? cg
            }.value
        }
    }

    // MARK: - Live preview

    private func nudgePreview() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            previewTrigger &+= 1
        }
    }

    // MARK: - Auto Adjust

    private func autoAdjustLevels() {
        guard let cg = previewBaseCG else { return }

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

        let countD = Double(count)

        func percentile(_ pct: Double) -> Int {
            let target = Int(countD * pct)
            var cum = 0
            for i in 0..<256 {
                cum += lumHist[i]
                if cum >= target { return i }
            }
            return 255
        }

        let p01  = percentile(0.01)
        let p05  = percentile(0.05)
        let p25  = percentile(0.25)
        let p50  = percentile(0.50)
        let p75  = percentile(0.75)
        let p99  = percentile(0.99)

        let shadowPixels = lumHist[0..<64].reduce(0, +)
        let highlightPixels = lumHist[192..<256].reduce(0, +)
        let shadowFrac = Double(shadowPixels) / countD
        let highlightFrac = Double(highlightPixels) / countD

        // Exposure: gentle nudge toward median ~128
        let medianDelta = 128.0 - Double(p50)
        let newExposure = max(-2.0, min(2.0, round((medianDelta / 80.0) * 20) / 20))

        // Contrast: only boost, never reduce
        let iqr = Double(p75 - p25)
        let contrastAdjust = max(0, (80.0 - iqr) * 0.15)
        let newContrast = Int(min(25, contrastAdjust))

        // Highlights: only recover if genuinely clipped
        let newHighlights: Int
        if highlightFrac > 0.08 {
            let strength = min(1.0, (highlightFrac - 0.08) / 0.25)
            newHighlights = Int(max(-40, -strength * 30))
        } else { newHighlights = 0 }

        // Shadows: only lift if truly crushed
        let newShadows: Int
        if shadowFrac > 0.25 && p05 < 20 {
            let strength = min(1.0, (shadowFrac - 0.25) / 0.3)
            newShadows = Int(min(25, strength * 20))
        } else { newShadows = 0 }

        // Whites/Blacks: gentle percentile targeting
        let newWhites = Int(max(-20, min(30, (245.0 - Double(p99)) * 0.3)))
        let newBlacks = Int(max(-20, min(15, (10.0 - Double(p01)) * 0.3)))

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
        guard let cgSrc = previewBaseCG ??
                originalImage?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        let capExposure    = exposure
        let capContrast    = contrast
        let capHighlights  = highlights
        let capShadows     = shadows
        let capWhites      = whites
        let capBlacks      = blacks
        let capSaturation  = saturation
        let capVibrance    = vibrance
        let capTemp        = temperature
        let capTint        = tint
        let capClarity     = clarity
        let capDehaze      = dehaze
        let capUseCurve    = useToneCurve
        let capPreset      = selectedPreset
        let capAdj         = adj
        let capMaskLayers  = maskLayers.filter { $0.isActive }

        let rendered = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            var ci = CIImage(cgImage: cgSrc)

            // 1. Temperature/Tint — first in chain for white balance
            ci = AdjustmentFilterPipeline.applyTemperatureTint(ci, temperature: capTemp, tint: capTint)

            // 2. Exposure
            if abs(capExposure) > 0.01 {
                let f = CIFilter(name: "CIExposureAdjust")!
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(Float(capExposure), forKey: "inputEV")
                if let out = f.outputImage { ci = out }
            }

            // 3. Contrast + Saturation
            let contrastFactor   = Float(1.0 + Double(capContrast)   / 667.0)
            let saturationFactor = Float(max(0, 1.0 + Double(capSaturation) / 100.0))
            if abs(contrastFactor - 1) > 0.005 || abs(saturationFactor - 1) > 0.005 {
                let f = CIFilter(name: "CIColorControls")!
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(contrastFactor,   forKey: kCIInputContrastKey)
                f.setValue(saturationFactor, forKey: kCIInputSaturationKey)
                if let out = f.outputImage { ci = out }
            }

            // 4. Vibrance — global (was missing before)
            if capVibrance != 0, let f = CIFilter(name: "CIVibrance") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(Float(capVibrance) / 100.0, forKey: "inputAmount")
                if let out = f.outputImage { ci = out }
            }

            // 5. Highlights/Shadows — luminance-preserving tone curve
            ci = AdjustmentFilterPipeline.applyHighlightsShadows(ci, highlights: capHighlights, shadows: capShadows)

            // 6. Whites & Blacks — smoother non-linear tone curve
            ci = AdjustmentFilterPipeline.applyWhitesBlacks(ci, whites: capWhites, blacks: capBlacks)

            // 7. Dehaze
            ci = AdjustmentFilterPipeline.applyDehaze(ci, amount: capDehaze)

            // 8. HSL / Color Grading / Color Balance / Calibration — 3D LUT
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

            // 9. Clarity — local contrast
            ci = AdjustmentFilterPipeline.applyClarity(ci, amount: capClarity)

            // 10. Tone curve preset (user-selected S-curves etc.)
            if capUseCurve, let preset = capPreset {
                let pts = preset.points
                if pts.count >= 5 {
                    let f = CIFilter(name: "CIToneCurve")!
                    f.setValue(ci, forKey: kCIInputImageKey)
                    let vecs = pts.prefix(5).map { CIVector(x: CGFloat($0.input) / 255,
                                                             y: CGFloat($0.output) / 255) }
                    f.setValue(vecs[0], forKey: "inputPoint0")
                    f.setValue(vecs[1], forKey: "inputPoint1")
                    f.setValue(vecs[2], forKey: "inputPoint2")
                    f.setValue(vecs[3], forKey: "inputPoint3")
                    f.setValue(vecs[4], forKey: "inputPoint4")
                    if let out = f.outputImage { ci = out }
                }
            }

            // 11. Apply mask layers via CIBlendWithMask
            if !capMaskLayers.isEmpty {
                ci = MaskRenderingService.applyAdjustmentLayers(
                    capMaskLayers,
                    base: ci,
                    sourceCG: cgSrc
                )
            }

            guard let cgOut = Self.sharedCIContext.createCGImage(ci, from: ci.extent) else { return nil }
            return NSImage(cgImage: cgOut, size: NSSize(width: cgOut.width, height: cgOut.height))
        }.value

        previewImage = rendered
    }

    // MARK: - Helpers

    private func adjustmentCard<Content: View>(
        _ title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(.top, 8)
        } label: {
            Text(title).font(.subheadline.weight(.semibold))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func adjustmentCardWithAction<Content: View>(
        _ title: String,
        isExpanded: Binding<Bool>,
        action: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(.top, 8)
        } label: {
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
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func adjustmentSlider(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double = 1,
        format: String = "%.0f"
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 80, alignment: .leading)
                .foregroundStyle(.secondary)
            Slider(value: value, in: range, step: step)
                .onChange(of: value.wrappedValue) { nudgePreview() }
            Text(String(format: format, value.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func intBinding(_ binding: Binding<Int>) -> Binding<Double> {
        Binding(
            get: { Double(binding.wrappedValue) },
            set: { binding.wrappedValue = Int($0.rounded()) }
        )
    }

    // MARK: - Static image helpers (used from detached tasks)

    nonisolated private static func scale(_ image: CGImage, maxEdge: Int) -> CGImage? {
        let w = image.width, h = image.height
        guard max(w, h) > maxEdge else { return nil }
        let scale = Double(maxEdge) / Double(max(w, h))
        let newW = max(1, Int(Double(w) * scale))
        let newH = max(1, Int(Double(h) * scale))
        guard let ctx = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage()
    }

    nonisolated private static func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw NSError(domain: "AdjustmentPanel", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create JPEG destination at \(url.lastPathComponent)"])
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "AdjustmentPanel", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "JPEG finalization failed for \(url.lastPathComponent)"])
        }
    }
}
