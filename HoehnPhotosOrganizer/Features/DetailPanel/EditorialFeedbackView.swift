import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

// MARK: - ReviewScope

/// Scope of editorial review to request from Claude.
enum ReviewScope: String, CaseIterable, Identifiable {
    case full           = "Full Review"
    case adjustments    = "Adjustments"
    case cropsOnly      = "Crops & Composition"
    case geometryOnly   = "Geometry & Straighten"
    case metadataOnly   = "Metadata & Tags"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .full:         return "sparkles"
        case .adjustments:  return "slider.horizontal.3"
        case .cropsOnly:    return "crop"
        case .geometryOnly: return "perspective"
        case .metadataOnly: return "tag.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .full:         return "Exposure, crops, masking, geometry, metadata"
        case .adjustments:  return "Exposure, contrast, highlights, shadows, color"
        case .cropsOnly:    return "Crop suggestions and composition analysis"
        case .geometryOnly: return "Horizon straighten, perspective correction"
        case .metadataOnly: return "Location, subjects, mood, tags"
        }
    }
}

// MARK: - FeedbackSection

private enum FeedbackSection: String, CaseIterable, Identifiable {
    case adjustments = "Adjustments"
    case crops       = "Crops"
    case analysis    = "Analysis"
    case masking     = "Masking"
    case geometry    = "Geometry"
    case metadata    = "Metadata"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .adjustments: return "slider.horizontal.3"
        case .crops:       return "crop"
        case .analysis:    return "text.alignleft"
        case .masking:     return "paintbrush.pointed.fill"
        case .geometry:    return "perspective"
        case .metadata:    return "tag.fill"
        }
    }
}

// MARK: - EditorialFeedbackView

struct EditorialFeedbackView: View {

    let photo: PhotoAsset
    @ObservedObject var viewModel: LibraryViewModel

    @Environment(\.appDatabase) private var appDatabase: AppDatabase?
    @Environment(\.dismiss) private var dismiss

    // Review scope & navigation
    @State private var reviewScope: ReviewScope = .full
    @State private var selectedSection: FeedbackSection = .adjustments

    // Image preview
    @State private var proxyImage: NSImage?
    @State private var adjustedPreviewImage: NSImage?
    @State private var showingAdjusted = false
    @State private var renderingPreview = false

    // Live adjustment editing
    @State private var liveAdj: LiveAdj?
    @State private var toneExpanded = true
    @State private var colorExpanded = true
    @State private var renderTask: Task<Void, Never>?

    // Actions
    @State private var generatedCurve: CurveData?
    @State private var showingCurveApplication = false
    @State private var curveExportError: String?
    @State private var adjustmentsApplied = false
    @State private var enrichmentApplied = false
    @State private var savedToThread = false

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.editorialFeedbackLoading,
                   viewModel.editorialFeedbackPhotoId == photo.id {
                    loadingView
                } else if let error = viewModel.editorialFeedbackError,
                          viewModel.editorialFeedbackPhotoId == photo.id {
                    errorView(message: error)
                } else if let feedback = viewModel.editorialFeedback,
                          viewModel.editorialFeedbackPhotoId == photo.id {
                    mainLayout(feedback)
                } else {
                    emptyStateView
                }
            }
            .navigationTitle("Editorial Feedback")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .frame(minWidth: 1300, minHeight: 880)
        .onAppear {
            loadProxyImage()
            let isSamePhoto = viewModel.editorialFeedbackPhotoId == photo.id
            // Restore UI state if feedback already exists for this photo
            if isSamePhoto, let feedback = viewModel.editorialFeedback {
                selectedSection = feedback.adjustments != nil ? .adjustments : .analysis
                if let adj = feedback.adjustments, liveAdj == nil { liveAdj = LiveAdj(adj) }
            }
        }
        .onChange(of: viewModel.editorialFeedback) { _, feedback in
            guard viewModel.editorialFeedbackPhotoId == photo.id else { return }
            if let feedback {
                selectedSection = feedback.adjustments != nil ? .adjustments : .analysis
                if let adj = feedback.adjustments {
                    if liveAdj == nil { liveAdj = LiveAdj(adj) }
                    renderAdjustedPreview(adj: adj)
                }
            }
        }
        .onChange(of: proxyImage) { _, img in
            if img != nil, let adj = viewModel.editorialFeedback?.adjustments {
                if liveAdj == nil { liveAdj = LiveAdj(adj) }
                renderAdjustedPreview(adj: adj)
            }
        }
    }

    // MARK: - Main Layout

    private func mainLayout(_ feedback: EditorialFeedback) -> some View {
        HStack(spacing: 0) {
            leftSidebar(feedback)
            Divider()
            VStack(spacing: 0) {
                rightContent(feedback)
                Divider()
                actionBar(for: feedback)
            }
        }
    }

    // MARK: - Left Sidebar

    private func leftSidebar(_ feedback: EditorialFeedback) -> some View {
        VStack(spacing: 0) {
            // Photo preview with toggle
            imagePreviewArea(feedback)
                .frame(height: 180)

            Divider()

            // Score + readiness chips
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(scoreColor(feedback.compositionScore).opacity(0.15))
                            .frame(width: 44, height: 44)
                        VStack(spacing: 0) {
                            Text("\(feedback.compositionScore)")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundStyle(scoreColor(feedback.compositionScore))
                            Text("/10")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scoreLabel(feedback.compositionScore))
                            .font(.system(size: 13, weight: .semibold))
                        Text("Assessed by Claude")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }

                let isReady = feedback.printReadiness.lowercased() == "ready"
                Label(isReady ? "Print Ready" : "Needs Work",
                      systemImage: isReady ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isReady ? .green : .orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Section navigation
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(availableSections(for: feedback)) { section in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedSection = section
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: section.icon)
                                    .font(.system(size: 12))
                                    .frame(width: 16)
                                Text(section.rawValue)
                                    .font(.system(size: 13))
                                Spacer()
                                if section == .adjustments, showingAdjusted {
                                    Image(systemName: "eye.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.blue.opacity(0.7))
                                }
                            }
                            .foregroundStyle(selectedSection == section ? .white : .primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selectedSection == section ? Color.accentColor : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }

            Spacer(minLength: 0)
        }
        .frame(width: 210)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Image Preview Area

    private func imagePreviewArea(_ feedback: EditorialFeedback) -> some View {
        ZStack {
            Color.black

            if let img = displayImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }

            if renderingPreview {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(6)
                    .background(Color.black.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if feedback.adjustments != nil {
                Button {
                    if adjustedPreviewImage == nil && !renderingPreview, let adj = feedback.adjustments {
                        renderAdjustedPreview(adj: adj)
                    }
                    showingAdjusted.toggle()
                } label: {
                    Label(showingAdjusted ? "Original" : "Adjusted",
                          systemImage: showingAdjusted ? "photo" : "wand.and.stars")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .padding(6)
            }
        }
    }

    private var displayImage: NSImage? {
        showingAdjusted ? (adjustedPreviewImage ?? proxyImage) : proxyImage
    }

    // MARK: - Right Content

    private func rightContent(_ feedback: EditorialFeedback) -> some View {
        ScrollView {
            Group {
                switch selectedSection {
                case .adjustments:
                    adjustmentsPanel(feedback)
                case .crops:
                    cropsPanel(feedback.cropSuggestions)
                case .analysis:
                    analysisPanel(feedback)
                case .masking:
                    maskingPanel(feedback)
                case .geometry:
                    if let geo = feedback.geometryCorrection {
                        geometryPanel(geo)
                    }
                case .metadata:
                    if let enrichment = feedback.metadataEnrichment {
                        metadataPanel(enrichment)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Before/After Preview

    private var beforeAfterPreview: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .bottomLeading) {
                Color.black
                if let img = proxyImage {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                }
                Text("Before")
                    .font(.caption2.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(8)
            }

            Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1)

            ZStack(alignment: .bottomLeading) {
                Color.black
                if let img = adjustedPreviewImage {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else if renderingPreview {
                    ProgressView().scaleEffect(0.8).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("Generating preview…")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text("After")
                    .font(.caption2.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity).frame(height: 340)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Adjustments Panel

    private func adjustmentsPanel(_ feedback: EditorialFeedback) -> some View {
        let adj = feedback.adjustments
        let live = liveAdj ?? adj.map { LiveAdj($0) }
        let willDesaturate = (live?.saturation ?? 0) <= -90 || (live?.vibrance ?? 0) <= -90

        return VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Suggested Adjustments", subtitle: nil)

            beforeAfterPreview

            // Tone group
            DisclosureGroup(isExpanded: $toneExpanded) {
                VStack(spacing: 6) {
                    liveAdjRow("Exposure",
                        value: adjBinding(get: { liveAdj?.exposure ?? 0 }, set: { liveAdj?.exposure = $0 }),
                        in: -5...5, step: 0.05,
                        format: { v in v == 0 ? "0 EV" : String(format: "%+.2f EV", v) })
                    liveAdjRow("Contrast",
                        value: adjBinding(get: { liveAdj?.contrast ?? 0 }, set: { liveAdj?.contrast = $0 }),
                        in: -100...100,
                        format: { formatDeltaD($0) })
                    liveAdjRow("Highlights",
                        value: adjBinding(get: { liveAdj?.highlights ?? 0 }, set: { liveAdj?.highlights = $0 }),
                        in: -100...100,
                        format: { formatDeltaD($0) })
                    liveAdjRow("Shadows",
                        value: adjBinding(get: { liveAdj?.shadows ?? 0 }, set: { liveAdj?.shadows = $0 }),
                        in: -100...100,
                        format: { formatDeltaD($0) })
                    liveAdjRow("Whites",
                        value: adjBinding(get: { liveAdj?.whites ?? 0 }, set: { liveAdj?.whites = $0 }),
                        in: -100...100,
                        format: { formatDeltaD($0) })
                    liveAdjRow("Blacks",
                        value: adjBinding(get: { liveAdj?.blacks ?? 0 }, set: { liveAdj?.blacks = $0 }),
                        in: -100...100,
                        format: { formatDeltaD($0) })
                }
                .padding(.top, 10)
            } label: {
                Label("Tone", systemImage: "sun.max").font(.headline)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))

            // Color group
            DisclosureGroup(isExpanded: $colorExpanded) {
                VStack(spacing: 6) {
                    liveAdjRow("Saturation",
                        value: adjBinding(get: { liveAdj?.saturation ?? 0 }, set: { liveAdj?.saturation = $0 }),
                        in: -100...100,
                        format: { formatDeltaD($0) })
                    liveAdjRow("Vibrance",
                        value: adjBinding(get: { liveAdj?.vibrance ?? 0 }, set: { liveAdj?.vibrance = $0 }),
                        in: -100...100,
                        format: { formatDeltaD($0) })
                }
                .padding(.top, 10)
            } label: {
                Label("Color", systemImage: "paintpalette").font(.headline)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))

            if let rationale = adj?.rationale {
                Text(rationale).font(.callout).foregroundStyle(.secondary)
            }

            if willDesaturate {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Applying will convert to black & white — useful for evaluating tonal relationships for alt-process printing.")
                        .font(.callout).foregroundStyle(.orange)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.08)))
            }

            // Suggestions carousel
            let hasSuggestions = !feedback.cropSuggestions.isEmpty || !feedback.suggestedEditDirections.isEmpty || !feedback.maskingHints.isEmpty || !(feedback.regionalAdjustments?.isEmpty ?? true)
            if hasSuggestions {
                suggestionsCarousel(feedback)
            }

            if adjustmentsApplied {
                Label("Applied to adjustments", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if let adj {
                Button("Apply to Adjustments") {
                    let effectiveAdj = liveAdj.map { live in
                        SuggestedAdjustments(
                            exposure:   live.exposure   == 0 ? nil : live.exposure,
                            contrast:   live.contrast   == 0 ? nil : Int(live.contrast),
                            highlights: live.highlights == 0 ? nil : Int(live.highlights),
                            shadows:    live.shadows    == 0 ? nil : Int(live.shadows),
                            whites:     live.whites     == 0 ? nil : Int(live.whites),
                            blacks:     live.blacks     == 0 ? nil : Int(live.blacks),
                            saturation: live.saturation == 0 ? nil : Int(live.saturation),
                            vibrance:   live.vibrance   == 0 ? nil : Int(live.vibrance),
                            rationale:  adj.rationale
                        )
                    } ?? adj
                    Task {
                        await viewModel.applyEditorialAdjustments(to: photo.id, adjustments: effectiveAdj, db: appDatabase)
                        adjustmentsApplied = true
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Suggestions Carousel

    private func suggestionsCarousel(_ feedback: EditorialFeedback) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Claude's Suggestions", systemImage: "sparkles").font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(feedback.cropSuggestions) { crop in
                        CropSuggestionCard(crop: crop, proxyImage: proxyImage)
                    }
                    ForEach(feedback.suggestedEditDirections, id: \.self) { direction in
                        EditDirectionCard(text: direction)
                    }
                    ForEach(feedback.maskingHints.prefix(3), id: \.self) { hint in
                        EditDirectionCard(text: hint, icon: "paintbrush.pointed.fill", color: Color(red: 0.85, green: 0.35, blue: 0.1))
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Live Adj Helpers

    private func adjBinding(get: @escaping () -> Double, set: @escaping (Double) -> Void) -> Binding<Double> {
        Binding(get: get, set: { v in set(v); schedulePreviewRender() })
    }

    private func liveAdjRow(
        _ label: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double = 1,
        format: (Double) -> String
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Slider(value: value, in: range, step: step)
                .controlSize(.small)
            Text(format(value.wrappedValue))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(value.wrappedValue > 0 ? Color.blue : value.wrappedValue < 0 ? Color.red : Color.secondary)
                .frame(width: 72, alignment: .trailing)
        }
        .frame(height: 24)
    }

    private func schedulePreviewRender() {
        renderTask?.cancel()
        guard let src = proxyImage, let live = liveAdj else { return }
        let adj = SuggestedAdjustments(
            exposure:   live.exposure   == 0 ? nil : live.exposure,
            contrast:   live.contrast   == 0 ? nil : Int(live.contrast),
            highlights: live.highlights == 0 ? nil : Int(live.highlights),
            shadows:    live.shadows    == 0 ? nil : Int(live.shadows),
            whites:     live.whites     == 0 ? nil : Int(live.whites),
            blacks:     live.blacks     == 0 ? nil : Int(live.blacks),
            saturation: live.saturation == 0 ? nil : Int(live.saturation),
            vibrance:   live.vibrance   == 0 ? nil : Int(live.vibrance),
            rationale:  nil
        )
        renderTask = Task {
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }
            renderingPreview = true
            let result = await Task.detached(priority: .userInitiated) {
                Self.applyAdjustmentsCI(to: src, adj: adj)
            }.value
            adjustedPreviewImage = result
            renderingPreview = false
        }
    }

    private func formatDeltaD(_ v: Double) -> String {
        v == 0 ? "0" : v > 0 ? "+\(Int(v))" : "\(Int(v))"
    }

    // MARK: - Crops Panel

    private func cropsPanel(_ crops: [CropSuggestion]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Crop Suggestions", subtitle: "\(crops.count) option\(crops.count == 1 ? "" : "s")")
            ForEach(crops) { crop in
                CropSuggestionRow(crop: crop, proxyURL: proxyURL)
            }
        }
    }

    // MARK: - Analysis Panel

    private func analysisPanel(_ feedback: EditorialFeedback) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Analysis", subtitle: nil)

            Text(feedback.analysis)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if !feedback.strengths.isEmpty {
                labeledList("Strengths", items: feedback.strengths, color: .green)
            }
            if !feedback.areasForImprovement.isEmpty {
                labeledList("Areas for Improvement", items: feedback.areasForImprovement, color: .orange)
            }
            if !feedback.suggestedEditDirections.isEmpty {
                labeledList("Suggested Edits", items: feedback.suggestedEditDirections, color: .blue)
            }

            Divider()

            // Curve generation
            if let curve = generatedCurve {
                HStack {
                    Label("Curve generated (\(curve.format.uppercased()))", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Save") { saveCurveFile(curve) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Apply to Photoshop") { showingCurveApplication = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .sheet(isPresented: $showingCurveApplication) {
                    CurveApplicationView(curveData: curve, viewModel: viewModel)
                }
            } else {
                Button("Generate Curve File") { generateCurve(from: feedback) }
                    .buttonStyle(.bordered)
                if let err = curveExportError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Masking Panel

    private func maskingPanel(_ feedback: EditorialFeedback) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Masking & Regional Adjustments", subtitle: "Selective adjustments by region")

            // Structured regional adjustments
            if let regions = feedback.regionalAdjustments, !regions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Regional Adjustments", systemImage: "circle.dashed")
                        .font(.subheadline.weight(.semibold))

                    ForEach(regions, id: \.regionLabel) { region in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(region.regionLabel.capitalized)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.yellow.opacity(0.15)))
                                if let hint = region.geometryHint {
                                    Text(hint)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(region.regionDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            let adj = region.adjustments
                            HStack(spacing: 12) {
                                if let e = adj.exposure { adjustmentChip("Exp", value: String(format: "%+.1f", e)) }
                                if let c = adj.contrast { adjustmentChip("Con", value: "\(c > 0 ? "+" : "")\(c)") }
                                if let h = adj.highlights { adjustmentChip("Hi", value: "\(h > 0 ? "+" : "")\(h)") }
                                if let s = adj.shadows { adjustmentChip("Sh", value: "\(s > 0 ? "+" : "")\(s)") }
                                if let sat = adj.saturation { adjustmentChip("Sat", value: "\(sat > 0 ? "+" : "")\(sat)") }
                            }
                            .font(.caption2.monospacedDigit())
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
                    }
                }
            }

            // Legacy burn/dodge hints
            if !feedback.maskingHints.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Burn & Dodge Hints", systemImage: "paintbrush.pointed.fill")
                        .font(.subheadline.weight(.semibold))
                    labeledList(nil, items: feedback.maskingHints, color: Color(red: 0.85, green: 0.35, blue: 0.1))
                }
            }
        }
    }

    @ViewBuilder
    private func adjustmentChip(_ label: String, value: String) -> some View {
        HStack(spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    // MARK: - Geometry Panel

    private func geometryPanel(_ geo: GeometryCorrection) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Geometry Correction", subtitle: nil)

            VStack(alignment: .leading, spacing: 10) {
                if let deg = geo.rotationDegrees {
                    geoRow(label: "Rotation", value: "\(deg > 0 ? "+" : "")\(String(format: "%.1f", deg))°", icon: "rotate.left")
                }
                if let vp = geo.verticalPerspective {
                    geoRow(label: "Vertical", value: "\(vp > 0 ? "+" : "")\(Int(vp))", icon: "building.2")
                }
                if let hp = geo.horizontalPerspective {
                    geoRow(label: "Horizontal", value: "\(hp > 0 ? "+" : "")\(Int(hp))", icon: "arrow.left.and.right")
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )

            if let rationale = geo.rationale {
                Text(rationale)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Apply via Lens Correction or Transform panel in your editor.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func geoRow(label: String, value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.callout.bold())
        }
    }

    // MARK: - Metadata Panel

    private func metadataPanel(_ enrichment: MetadataEnrichment) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Suggested Metadata", subtitle: "Inferred from image context")

            VStack(alignment: .leading, spacing: 8) {
                if let loc = enrichment.locationName {
                    MetadataChip(label: "Location", value: loc, icon: "mappin")
                }
                if let venue = enrichment.venue {
                    MetadataChip(label: "Venue", value: venue, icon: "building.2")
                }
                if let coords = enrichment.coordinates {
                    MetadataChip(label: "GPS", value: String(format: "%.4f, %.4f", coords.lat, coords.lon), icon: "location")
                }
                if let mood = enrichment.mood {
                    MetadataChip(label: "Mood", value: mood, icon: "theatermasks")
                }
                if let subjects = enrichment.subjects, !subjects.isEmpty {
                    MetadataChip(label: "Subjects", value: subjects.joined(separator: ", "), icon: "tag")
                }
                if let style = enrichment.decadeStyle {
                    MetadataChip(label: "Style", value: style, icon: "camera.vintage")
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )

            if enrichmentApplied {
                Label("Applied to metadata", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Apply to Metadata") {
                    Task {
                        await viewModel.applyEditorialEnrichment(to: photo.id, enrichment: enrichment, db: appDatabase)
                        enrichmentApplied = true
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Action Bar

    private func actionBar(for feedback: EditorialFeedback) -> some View {
        HStack(spacing: 12) {
            if let usage = viewModel.editorialTokenUsage {
                Text("Claude · \(usage.inputTokens) in / \(usage.outputTokens) out · est. $\(String(format: "%.4f", usage.estimatedCostUSD))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Discard") {
                viewModel.editorialFeedback = nil
                dismiss()
            }
            .buttonStyle(.bordered)

            Button(savedToThread ? "Saved ✓" : "Accept & Save to Thread") {
                let f = feedback
                Task { await acceptAndSave(feedback: f) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(savedToThread)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Loading / Error / Empty

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView().scaleEffect(1.4)
            Text("Requesting critique from Claude…").font(.headline)
            Text("This may take 10–30 seconds.")
                .foregroundStyle(.secondary).font(.caption)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40)).foregroundStyle(.orange)
            Text("Request Failed").font(.title3.bold())
            Text(message).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
            Button("Retry") {
                Task { await viewModel.requestEditorialFeedback(for: photo.id, scope: reviewScope, db: appDatabase) }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 24) {
            // Photo thumbnail
            if let img = proxyImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            }

            VStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 36))
                    .foregroundStyle(.purple.opacity(0.6))
                Text("Request Editorial Review")
                    .font(.title3.bold())
                Text("Claude will analyze your photo and provide feedback.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Scope picker
            VStack(alignment: .leading, spacing: 8) {
                Text("Review Type")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)

                VStack(spacing: 4) {
                    ForEach(ReviewScope.allCases) { scope in
                        Button {
                            reviewScope = scope
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: scope.icon)
                                    .font(.system(size: 14))
                                    .foregroundStyle(reviewScope == scope ? .white : .secondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(scope.rawValue)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(reviewScope == scope ? .white : .primary)
                                    Text(scope.subtitle)
                                        .font(.system(size: 11))
                                        .foregroundStyle(reviewScope == scope ? Color.white.opacity(0.8) : Color.secondary)
                                }
                                Spacer()
                                if reviewScope == scope {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(reviewScope == scope ? Color.accentColor : Color.primary.opacity(0.04))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: 380)

            Button {
                Task { await viewModel.requestEditorialFeedback(for: photo.id, scope: reviewScope, db: appDatabase) }
            } label: {
                Label("Request Review", systemImage: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Shared helpers

    private func sectionHeader(_ title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.bold())
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func labeledList(_ title: String?, items: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.headline)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(color).frame(width: 6, height: 6).padding(.top, 6)
                        Text(item).font(.callout).foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func availableSections(for feedback: EditorialFeedback) -> [FeedbackSection] {
        var sections: [FeedbackSection] = []
        if feedback.adjustments != nil          { sections.append(.adjustments) }
        if !feedback.cropSuggestions.isEmpty    { sections.append(.crops) }
        sections.append(.analysis)
        if !feedback.maskingHints.isEmpty || !(feedback.regionalAdjustments?.isEmpty ?? true) { sections.append(.masking) }
        if feedback.geometryCorrection != nil   { sections.append(.geometry) }
        if feedback.metadataEnrichment != nil   { sections.append(.metadata) }
        return sections
    }

    // MARK: - Image loading

    private func loadProxyImage() {
        guard proxyImage == nil else { return }
        DispatchQueue.global(qos: .utility).async {
            let img = NSImage(contentsOf: proxyURL)
            DispatchQueue.main.async { proxyImage = img }
        }
    }

    // MARK: - Adjustment preview rendering

    private func renderAdjustedPreview(adj: SuggestedAdjustments) {
        guard let src = proxyImage, adjustedPreviewImage == nil, !renderingPreview else { return }
        renderingPreview = true
        let adjCopy = adj
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.applyAdjustmentsCI(to: src, adj: adjCopy)
            }.value
            adjustedPreviewImage = result
            renderingPreview = false
        }
    }

    private static func applyAdjustmentsCI(to nsImage: NSImage, adj: SuggestedAdjustments) -> NSImage? {
        guard let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let ciImage = CIImage(bitmapImageRep: bitmap) else { return nil }

        // Log the raw values from Claude and the computed CIFilter parameters
        var logLines: [String] = ["[Editorial Adjustments] Raw values from Claude:"]
        logLines.append("  exposure=\(adj.exposure.map { String(format: "%.2f", $0) } ?? "nil") contrast=\(adj.contrast.map(String.init) ?? "nil") highlights=\(adj.highlights.map(String.init) ?? "nil") shadows=\(adj.shadows.map(String.init) ?? "nil")")
        logLines.append("  whites=\(adj.whites.map(String.init) ?? "nil") blacks=\(adj.blacks.map(String.init) ?? "nil") saturation=\(adj.saturation.map(String.init) ?? "nil") vibrance=\(adj.vibrance.map(String.init) ?? "nil")")

        var image = ciImage

        // Exposure (CIExposureAdjust: inputEV in stops)
        if let ev = adj.exposure, ev != 0 {
            let f = CIFilter(name: "CIExposureAdjust")!
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(Float(ev), forKey: "inputEV")
            image = f.outputImage ?? image
        }

        // Contrast + Saturation (CIColorControls)
        // CIColorControls contrast: 1.0 = neutral. Useful range ~0.85–1.15.
        // Lightroom ±100 ≈ CIColorControls ±0.15, so divide by 667.
        let contrastF   = adj.contrast.map   { Float(1.0 + Double($0) / 667.0) }
        let saturationF = adj.saturation.map { Float(max(0, 1.0 + Double($0) / 100.0)) }
        if contrastF != nil || saturationF != nil {
            let f = CIFilter(name: "CIColorControls")!
            f.setValue(image, forKey: kCIInputImageKey)
            if let c = contrastF   { f.setValue(c, forKey: kCIInputContrastKey) }
            if let s = saturationF { f.setValue(s, forKey: kCIInputSaturationKey) }
            image = f.outputImage ?? image
        }

        // Vibrance (CIVibrance: –1 to 1, 0 = neutral)
        if let vibrance = adj.vibrance, vibrance != 0 {
            let f = CIFilter(name: "CIVibrance")!
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(Float(Double(vibrance) / 100.0), forKey: "inputAmount")
            image = f.outputImage ?? image
        }

        // Highlights + Shadows (CIHighlightShadowAdjust)
        // inputHighlightAmount: 1.0 = neutral (default), <1 = recover highlights, >1 = boost.
        // Lightroom: +highlights = brighten, -highlights = recover.
        // Map: +100 → 1.75 (boost), -100 → 0.25 (recover).
        // inputShadowAmount: 0.0 = neutral. Useful range roughly -0.5…+0.5.
        // Map: -100 → -0.5 (darken), +100 → +0.5 (open).
        let hl = adj.highlights.map { Float(1.0 + Double($0) / 133.0) }
        let sh = adj.shadows.map    { Float(Double($0) / 200.0) }
        if hl != nil || sh != nil {
            let f = CIFilter(name: "CIHighlightShadowAdjust")!
            f.setValue(image, forKey: kCIInputImageKey)
            if let h = hl { f.setValue(h, forKey: "inputHighlightAmount") }
            if let s = sh { f.setValue(s, forKey: "inputShadowAmount") }
            image = f.outputImage ?? image
        }

        // Whites + Blacks via CIToneCurve
        // Subtle endpoint shifts. Blacks ±100 → ±0.05 lift/crush. Whites ±100 → ±0.05.
        let blacksVal = adj.blacks ?? 0
        let whitesVal = adj.whites ?? 0
        if blacksVal != 0 || whitesVal != 0 {
            let blackOut = Float(blacksVal) / 100.0 * 0.05
            let whiteOut = 1.0 + Float(whitesVal) / 100.0 * 0.05
            let range    = whiteOut - blackOut
            let f = CIFilter(name: "CIToneCurve")!
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(CIVector(x: 0,    y: CGFloat(blackOut)),                forKey: "inputPoint0")
            f.setValue(CIVector(x: 0.25, y: CGFloat(blackOut + 0.25 * range)), forKey: "inputPoint1")
            f.setValue(CIVector(x: 0.5,  y: CGFloat(blackOut + 0.5  * range)), forKey: "inputPoint2")
            f.setValue(CIVector(x: 0.75, y: CGFloat(blackOut + 0.75 * range)), forKey: "inputPoint3")
            f.setValue(CIVector(x: 1,    y: CGFloat(whiteOut)),                forKey: "inputPoint4")
            image = f.outputImage ?? image
        }

        // Log computed CIFilter values
        logLines.append("[Editorial Adjustments] CIFilter values applied:")
        if let c = contrastF   { logLines.append("  CIColorControls.contrast = \(String(format: "%.4f", c)) (neutral=1.0)") }
        if let s = saturationF { logLines.append("  CIColorControls.saturation = \(String(format: "%.4f", s)) (neutral=1.0)") }
        if let h = hl { logLines.append("  CIHighlightShadow.highlight = \(String(format: "%.4f", h)) (neutral=1.0, <1=recover, >1=boost)") }
        if let s = sh { logLines.append("  CIHighlightShadow.shadow = \(String(format: "%.4f", s)) (neutral=0.0, >0=open, <0=darken)") }
        if blacksVal != 0 || whitesVal != 0 {
            let blackOut = Float(blacksVal) / 100.0 * 0.05
            let whiteOut = 1.0 + Float(whitesVal) / 100.0 * 0.05
            logLines.append("  ToneCurve: black=\(String(format: "%.3f", blackOut)) white=\(String(format: "%.3f", whiteOut))")
        }
        print(logLines.joined(separator: "\n"))

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    // MARK: - Accept & Save

    /// Saves the editorial feedback as a thread entry (ai_turn) and dismisses.
    @MainActor
    private func acceptAndSave(feedback: EditorialFeedback) async {
        guard let db = appDatabase else { dismiss(); return }

        // Build a human-readable summary for the thread
        var lines: [String] = []
        lines.append("Score: \(feedback.compositionScore)/10 · \(feedback.printReadiness.capitalized)")
        lines.append(feedback.analysis)
        if let adj = feedback.adjustments, let rationale = adj.rationale {
            lines.append("Adjustments: \(rationale)")
        }
        if let regions = feedback.regionalAdjustments, !regions.isEmpty {
            for region in regions {
                lines.append("Region '\(region.regionLabel)': \(region.regionDescription)")
            }
        }
        if !feedback.maskingHints.isEmpty {
            lines.append("Masking: \(feedback.maskingHints.joined(separator: "; "))")
        }
        let body = lines.joined(separator: "\n\n")

        let contentDict: [String: String] = ["text": body, "source": "claude_editorial"]
        let contentJson = (try? JSONSerialization.data(withJSONObject: contentDict))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"text\":\"\(body)\"}"

        let threadRepo = ThreadRepository(db: db)
        try? await threadRepo.addEntry(
            photoId: photo.id,
            kind: "ai_turn",
            contentJson: contentJson,
            authoredBy: "ai"
        )

        // Emit metadata enrichment event if enrichment was applied
        if let enrichment = feedback.metadataEnrichment {
            var fields: [String] = []
            if enrichment.locationName != nil { fields.append("location") }
            if enrichment.venue != nil        { fields.append("venue") }
            if enrichment.mood != nil         { fields.append("mood") }
            if let s = enrichment.subjects, !s.isEmpty { fields.append("subjects") }
            if !fields.isEmpty {
                Task { try? await viewModel.activityService?.emitMetadataEnrichment(
                    photoAssetId: photo.id, fields: fields
                ) }
            }
        }

        savedToThread = true

        // Small delay so the "Saved ✓" label is visible, then dismiss
        try? await Task.sleep(nanoseconds: 700_000_000)
        dismiss()
    }

    // MARK: - Curve actions

    private func generateCurve(from feedback: EditorialFeedback) {
        Task {
            do {
                let service = CurveGenerationService()
                generatedCurve = try await service.generateCurveFromFeedback(feedback)
                curveExportError = nil
            } catch {
                curveExportError = error.localizedDescription
            }
        }
    }

    private func saveCurveFile(_ curve: CurveData) {
        let panel = NSSavePanel()
        panel.title = "Save Curve File"
        panel.nameFieldStringValue = "editorial-curve-\(photo.canonicalName.prefix(20)).\(curve.format)"
        panel.allowedContentTypes = curve.format == "csv" ? [.commaSeparatedText] : [.data]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try curve.data.write(to: url) }
            catch { curveExportError = "Could not save: \(error.localizedDescription)" }
        }
    }

    // MARK: - Computed helpers

    private var proxyURL: URL {
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)
        ) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let proxyDir = appSupport
            .appendingPathComponent("HoehnPhotosOrganizer")
            .appendingPathComponent("proxies")
        let base = (photo.canonicalName as NSString).deletingPathExtension
        return proxyDir.appendingPathComponent(base + ".jpg")
    }

    private func formatDelta(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }

    private func scoreColor(_ score: Int) -> Color {
        switch score {
        case 8...10: return .green
        case 6...7:  return .blue
        case 4...5:  return .orange
        default:     return .red
        }
    }

    private func scoreLabel(_ score: Int) -> String {
        switch score {
        case 9...10: return "Exceptional"
        case 7...8:  return "Strong"
        case 5...6:  return "Moderate"
        case 3...4:  return "Developing"
        default:     return "Needs Work"
        }
    }
}

// MARK: - AdjustmentPreviewRow

private struct AdjustmentPreviewRow: View {
    let label: String
    let value: String?
    let rawValue: Double
    let maxAbsValue: Double
    let isPositive: Bool

    var body: some View {
        if let value {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)

                GeometryReader { geo in
                    let total = geo.size.width
                    let center = total / 2
                    let fraction = min(abs(rawValue) / maxAbsValue, 1.0)
                    let barWidth = total / 2 * fraction
                    let barX = isPositive ? center : center - barWidth

                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 6)
                        Rectangle()
                            .fill(Color.primary.opacity(0.2))
                            .frame(width: 1, height: 10)
                            .offset(x: center - 0.5)
                        if fraction > 0 {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(isPositive ? Color.blue.opacity(0.7) : Color.red.opacity(0.7))
                                .frame(width: max(barWidth, 2), height: 6)
                                .offset(x: barX)
                        }
                    }
                }
                .frame(height: 10)

                Text(value)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(isPositive ? .blue : .red)
                    .frame(width: 60, alignment: .trailing)
            }
            .frame(height: 22)
        }
    }
}

// MARK: - CropSuggestionRow

private struct CropSuggestionRow: View {
    let crop: CropSuggestion
    let proxyURL: URL
    @State private var proxyImage: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                if let img = proxyImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 140, height: 95)
                        .clipped()
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 140, height: 95)
                }
                GeometryReader { geo in
                    let w = geo.size.width, h = geo.size.height
                    let rect = CGRect(
                        x: crop.leftPct * w,  y: crop.topPct * h,
                        width: (crop.rightPct - crop.leftPct) * w,
                        height: (crop.bottomPct - crop.topPct) * h
                    )
                    Canvas { ctx, _ in
                        ctx.fill(Path(rect), with: .color(.blue.opacity(0.12)))
                        ctx.stroke(Path(rect), with: .color(.blue), lineWidth: 1.5)
                    }
                }
                .frame(width: 140, height: 95)
            }
            .cornerRadius(6)
            .clipped()

            VStack(alignment: .leading, spacing: 4) {
                Text(crop.label).font(.headline)
                Text(crop.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .onAppear {
            guard proxyImage == nil else { return }
            DispatchQueue.global(qos: .utility).async {
                let img = NSImage(contentsOf: proxyURL)
                DispatchQueue.main.async { proxyImage = img }
            }
        }
    }
}

// MARK: - LiveAdj

private struct LiveAdj {
    var exposure:   Double
    var contrast:   Double
    var highlights: Double
    var shadows:    Double
    var whites:     Double
    var blacks:     Double
    var saturation: Double
    var vibrance:   Double

    init(_ adj: SuggestedAdjustments) {
        exposure   = adj.exposure   ?? 0
        contrast   = Double(adj.contrast   ?? 0)
        highlights = Double(adj.highlights ?? 0)
        shadows    = Double(adj.shadows    ?? 0)
        whites     = Double(adj.whites     ?? 0)
        blacks     = Double(adj.blacks     ?? 0)
        saturation = Double(adj.saturation ?? 0)
        vibrance   = Double(adj.vibrance   ?? 0)
    }
}

// MARK: - CropSuggestionCard (carousel)

private struct CropSuggestionCard: View {
    let crop: CropSuggestion
    let proxyImage: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color.black
                if let img = proxyImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 160, height: 110)
                        .clipped()
                }
                GeometryReader { geo in
                    let w = geo.size.width, h = geo.size.height
                    let rect = CGRect(
                        x: crop.leftPct * w, y: crop.topPct * h,
                        width: (crop.rightPct - crop.leftPct) * w,
                        height: (crop.bottomPct - crop.topPct) * h
                    )
                    Canvas { ctx, _ in
                        // Dim outside crop
                        var outside = Path(CGRect(origin: .zero, size: CGSize(width: w, height: h)))
                        outside.addRect(rect)
                        ctx.fill(outside, with: .color(.black.opacity(0.45)))
                        ctx.stroke(Path(rect), with: .color(.white), lineWidth: 1.5)
                    }
                }
            }
            .frame(width: 160, height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(crop.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(crop.description)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 160)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - EditDirectionCard (carousel)

private struct EditDirectionCard: View {
    let text: String
    var icon: String = "sparkles"
    var color: Color = .blue

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(color)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 180, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - MetadataChip

private struct MetadataChip: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label + ":")
                .font(.callout.bold())
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer()
        }
    }
}
