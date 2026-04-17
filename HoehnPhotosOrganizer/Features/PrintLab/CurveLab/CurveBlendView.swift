import SwiftUI
import UniformTypeIdentifiers

// MARK: - CurveBlendView

/// Quad Curve Blending: load two .quad files and blend them using 5-zone sliders.
/// Mirrors the Piezography PPEv2 "Quad Curve Blending" workflow.
struct CurveBlendView: View {

    @ObservedObject var viewModel: CurveLabViewModel

    @State private var displayMode: BlendDisplayMode = .blended
    @State private var enabledChannels: Set<String> = ["K", "C", "M", "Y", "LC", "LM", "LK", "LLK"]
    @State private var showIndividualInks = false
    @State private var showCurve1Picker = false
    @State private var showCurve2Picker = false
    @State private var blendDebounceTask: Task<Void, Never>?

    private enum BlendDisplayMode: String, CaseIterable {
        case curve1 = "Curve 1"
        case blended = "Blended"
        case curve2 = "Curve 2"
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: curve loading + zone sliders
            leftPanel
                .frame(width: 280)

            Divider()

            // Center: blended curve graph + controls
            centerPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: viewModel.blendWeights) { _ in
            debouncedBlend()
        }
        .onChange(of: viewModel.blendWeights2) { _ in
            debouncedBlend()
        }
        .onChange(of: viewModel.blendCurve1) { _ in
            viewModel.computeBlend()
        }
        .onChange(of: viewModel.blendCurve2) { _ in
            viewModel.computeBlend()
        }
    }

    private func debouncedBlend() {
        blendDebounceTask?.cancel()
        blendDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000) // 30ms debounce
            guard !Task.isCancelled else { return }
            viewModel.computeBlend()
        }
    }

    // MARK: - Left Panel

    private var leftPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Link toggle
                HStack {
                    Toggle(isOn: $viewModel.linkedSliders) {
                        Text("Link Sliders")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                }
                .padding(.bottom, -4)

                // Curve 1
                curveSection(
                    label: "CURVE 1",
                    quad: viewModel.blendCurve1,
                    showPicker: $showCurve1Picker,
                    onPick: { viewModel.blendCurve1 = $0 },
                    onClear: { viewModel.blendCurve1 = nil }
                )

                curve1ZoneSliders

                Divider()

                // Curve 2
                curveSection(
                    label: "CURVE 2",
                    quad: viewModel.blendCurve2,
                    showPicker: $showCurve2Picker,
                    onPick: { viewModel.blendCurve2 = $0 },
                    onClear: { viewModel.blendCurve2 = nil }
                )

                curve2ZoneSliders

                Spacer()
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Curve Section

    private func curveSection(
        label: String,
        quad: QTRQuadFile?,
        showPicker: Binding<Bool>,
        onPick: @escaping (QTRQuadFile) -> Void,
        onClear: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(label)

            if let quad = quad {
                // Loaded state
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(quad.fileName.replacingOccurrences(of: ".quad", with: ""))
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        Button {
                            onClear()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }

                    // Mini curve preview
                    miniCurveGraph(channels: quad.activeChannels)
                        .frame(height: 100)
                        .drawingGroup()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                        )

                    // Channel badges
                    channelBadges(quad.activeChannels)
                }
            } else {
                // Empty state
                Button {
                    if viewModel.quadFiles.isEmpty {
                        viewModel.loadFilesFromDisk()
                    }
                    showPicker.wrappedValue = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 12))
                        Text("Load \(label.capitalized)")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                    )
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: showPicker, arrowEdge: .trailing) {
                    curvePickerPopover(onPick: onPick, dismiss: { showPicker.wrappedValue = false })
                }
            }
        }
    }

    // MARK: - Curve Picker Popover

    private func curvePickerPopover(
        onPick: @escaping (QTRQuadFile) -> Void,
        dismiss: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SELECT QUAD FILE")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(viewModel.quadFiles.count) files")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if viewModel.quadFiles.isEmpty {
                VStack(spacing: 8) {
                    Text("No .quad files found")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(viewModel.selectedProfile!.quadDirectoryPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Button("Refresh") {
                        viewModel.loadFilesFromDisk()
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(viewModel.quadFiles) { quad in
                            Button {
                                onPick(quad)
                                dismiss()
                            } label: {
                                HStack(spacing: 8) {
                                    miniCurveGraph(channels: quad.activeChannels)
                                        .frame(width: 48, height: 32)
                                        .drawingGroup()
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(quad.fileName.replacingOccurrences(of: ".quad", with: ""))
                                            .font(.system(size: 11, weight: .medium))
                                            .lineLimit(1)
                                        HStack(spacing: 3) {
                                            ForEach(quad.activeChannels.prefix(4)) { ch in
                                                Text(ch.name)
                                                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                                                    .foregroundStyle(channelColor(ch.name))
                                            }
                                            if quad.activeChannels.count > 4 {
                                                Text("+\(quad.activeChannels.count - 4)")
                                                    .font(.system(size: 8))
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(Color.primary.opacity(0.02))
                        }
                    }
                }
                .frame(width: 300, height: min(CGFloat(viewModel.quadFiles.count) * 50, 400))
            }
        }
    }

    // MARK: - Zone Sliders

    private var curve1ZoneSliders: some View {
        VStack(spacing: 6) {
            zoneSlider("Whites", value: curve1Binding(\.whites))
            zoneSlider("Lights", value: curve1Binding(\.lights))
            zoneSlider("Midtones", value: curve1Binding(\.midtones))
            zoneSlider("Darks", value: curve1Binding(\.darks))
            zoneSlider("Blacks", value: curve1Binding(\.blacks))
        }
    }

    private var curve2ZoneSliders: some View {
        VStack(spacing: 6) {
            zoneSlider("Whites", value: curve2Binding(\.whites))
            zoneSlider("Lights", value: curve2Binding(\.lights))
            zoneSlider("Midtones", value: curve2Binding(\.midtones))
            zoneSlider("Darks", value: curve2Binding(\.darks))
            zoneSlider("Blacks", value: curve2Binding(\.blacks))
        }
    }

    /// Curve 1 binding: when linked, Curve 2 = 100 - Curve 1.
    private func curve1Binding(_ keyPath: WritableKeyPath<BlendWeights, Double>) -> Binding<Double> {
        Binding(
            get: { viewModel.blendWeights[keyPath: keyPath] },
            set: { newValue in
                viewModel.blendWeights[keyPath: keyPath] = newValue
            }
        )
    }

    /// Curve 2 binding: derived as (100 - curve1) when linked, or independent when unlinked.
    /// In independent mode, curve2 weights are stored separately in blendWeights2 and
    /// each slider is freely adjustable 0-100. The blend normalizes: w1/(w1+w2), w2/(w1+w2).
    private func curve2Binding(_ keyPath: WritableKeyPath<BlendWeights, Double>) -> Binding<Double> {
        if viewModel.linkedSliders {
            return Binding(
                get: { 100 - viewModel.blendWeights[keyPath: keyPath] },
                set: { newValue in
                    viewModel.blendWeights[keyPath: keyPath] = 100 - newValue
                }
            )
        } else {
            // Independent mode: curve2 has its own weight, stored in blendWeights2
            return Binding(
                get: { viewModel.blendWeights2[keyPath: keyPath] },
                set: { newValue in
                    viewModel.blendWeights2[keyPath: keyPath] = newValue
                }
            )
        }
    }

    private func zoneSlider(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .frame(width: 70, alignment: .leading)
            Slider(value: value, in: 0...100, step: 1)
            Text(String(format: "%.0f", value.wrappedValue))
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 28, alignment: .trailing)
        }
    }

    // MARK: - Center Panel

    private var centerPanel: some View {
        VStack(spacing: 0) {
            centerToolbar
            Divider()

            VStack(spacing: 16) {
                // Main curve graph
                blendedCurveGraph
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .drawingGroup()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                    )

                // Channel toggles
                channelToggleBar

                // Show individual inks toggle
                HStack {
                    Toggle(isOn: $showIndividualInks) {
                        Text("Show Individual Ink Graphs")
                            .font(.system(size: 11))
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                }

                // Individual channel graphs
                if showIndividualInks, let quad = displayQuad {
                    individualInkGraphs(quad)
                }

                // Save button
                HStack {
                    Spacer()
                    Button {
                        saveBlendedCurve()
                    } label: {
                        Label("Save Blended Curve", systemImage: "square.and.arrow.down")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(viewModel.blendedResult == nil)
                }
            }
            .padding(20)
        }
    }

    private var centerToolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $displayMode) {
                ForEach(BlendDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 320)

            Spacer()

            // Status
            if viewModel.blendCurve1 != nil && viewModel.blendCurve2 != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 12))
                Text("Ready to blend")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                Text("Load two curves to begin")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// The quad file to display based on the segmented control selection.
    private var displayQuad: QTRQuadFile? {
        switch displayMode {
        case .curve1:  return viewModel.blendCurve1
        case .blended: return viewModel.blendedResult
        case .curve2:  return viewModel.blendCurve2
        }
    }

    // MARK: - Blended Curve Graph

    private var blendedCurveGraph: some View {
        ZStack {
            Canvas { context, size in
                // Background
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(Color(nsColor: .textBackgroundColor).opacity(0.5))
                )

                // Grid lines
                let gridColor = Color.secondary.opacity(0.08)
                let gridSteps = 10
                for i in 1..<gridSteps {
                    let x = CGFloat(i) / CGFloat(gridSteps) * size.width
                    let y = CGFloat(i) / CGFloat(gridSteps) * size.height
                    context.stroke(
                        Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                        with: .color(gridColor)
                    )
                    context.stroke(
                        Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) },
                        with: .color(gridColor)
                    )
                }

                // Zone shading (5 zones, alternating subtle fill)
                let zoneWidth = size.width / 5.0
                for z in 0..<5 {
                    if z % 2 == 1 {
                        let rect = CGRect(x: CGFloat(z) * zoneWidth, y: 0, width: zoneWidth, height: size.height)
                        context.fill(Path(rect), with: .color(Color.secondary.opacity(0.03)))
                    }
                }

                // Zone labels at bottom
                let zoneLabels = ["W", "L", "M", "D", "B"]
                for (z, label) in zoneLabels.enumerated() {
                    let x = (CGFloat(z) + 0.5) * zoneWidth
                    context.draw(
                        Text(label)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.4)),
                        at: CGPoint(x: x, y: size.height - 8)
                    )
                }

                // Diagonal reference
                context.stroke(
                    Path { p in p.move(to: CGPoint(x: 0, y: size.height)); p.addLine(to: CGPoint(x: size.width, y: 0)) },
                    with: .color(Color.secondary.opacity(0.15)),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )

                // Draw channels
                guard let quad = displayQuad else { return }
                for channel in quad.channels {
                    guard enabledChannels.contains(channel.name), channel.isActive else { continue }
                    let curve = channel.normalizedCurve
                    guard !curve.isEmpty else { continue }

                    // Subsample every 4th point for smoother Catmull-Rom rendering
                    let step = max(1, curve.count / 64)
                    var sampled: [(input: Double, output: Double)] = []
                    for i in stride(from: 0, to: curve.count, by: step) {
                        sampled.append(curve[i])
                    }
                    if let last = curve.last, sampled.last?.input != last.input {
                        sampled.append(last)
                    }

                    let points = sampled.map { pt in
                        CGPoint(x: pt.input * size.width, y: size.height - pt.output * size.height)
                    }

                    var path = Path()
                    guard points.count >= 2 else { continue }
                    path.move(to: points[0])

                    for i in 0..<(points.count - 1) {
                        let p0 = i > 0 ? points[i - 1] : points[i]
                        let p1 = points[i]
                        let p2 = points[i + 1]
                        let p3 = i + 2 < points.count ? points[i + 2] : points[i + 1]

                        let cp1 = CGPoint(
                            x: p1.x + (p2.x - p0.x) / 6.0,
                            y: p1.y + (p2.y - p0.y) / 6.0
                        )
                        let cp2 = CGPoint(
                            x: p2.x - (p3.x - p1.x) / 6.0,
                            y: p2.y - (p3.y - p1.y) / 6.0
                        )
                        path.addCurve(to: p2, control1: cp1, control2: cp2)
                    }
                    context.stroke(path, with: .color(channelColor(channel.name)), lineWidth: 1.5)
                }
            }

            // Axis labels
            VStack {
                Spacer()
                HStack {
                    Text("Input (0 = Paper White, 255 = Max Density)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            .padding(8)

            HStack {
                Text("Output")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(-90))
                Spacer()
            }
            .padding(8)

            // Empty state
            if displayQuad == nil {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("Load two curves to see the blend")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Channel Toggle Bar

    private var channelToggleBar: some View {
        HStack(spacing: 8) {
            let channelNames = viewModel.selectedProfile!.channelNames
            ForEach(channelNames, id: \.self) { name in
                Button {
                    if enabledChannels.contains(name) {
                        enabledChannels.remove(name)
                    } else {
                        enabledChannels.insert(name)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(channelColor(name))
                            .frame(width: 7, height: 7)
                        Text(name)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(enabledChannels.contains(name)
                                  ? channelColor(name).opacity(0.12)
                                  : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(enabledChannels.contains(name)
                                          ? channelColor(name).opacity(0.3)
                                          : Color.secondary.opacity(0.15),
                                          lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(enabledChannels.contains(name) ? .primary : .tertiary)
            }
            Spacer()

            Button("All") {
                enabledChannels = Set(channelNames)
            }
            .font(.system(size: 10))
            .buttonStyle(.bordered)
            .controlSize(.mini)

            Button("None") {
                enabledChannels.removeAll()
            }
            .font(.system(size: 10))
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    // MARK: - Individual Ink Graphs

    private func individualInkGraphs(_ quad: QTRQuadFile) -> some View {
        let active = quad.activeChannels.filter { enabledChannels.contains($0.name) }
        let columns = [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(active) { channel in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(channelColor(channel.name))
                            .frame(width: 6, height: 6)
                        Text(channel.name)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        Spacer()
                        Text(String(format: "%.1f%%", channel.maxInkPercent))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    singleChannelGraph(channel)
                        .frame(height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
                        )
                }
            }
        }
    }

    private func singleChannelGraph(_ channel: InkChannel) -> some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color(nsColor: .textBackgroundColor).opacity(0.5))
            )

            // Diagonal reference
            context.stroke(
                Path { p in p.move(to: CGPoint(x: 0, y: size.height)); p.addLine(to: CGPoint(x: size.width, y: 0)) },
                with: .color(Color.secondary.opacity(0.1)),
                style: StrokeStyle(lineWidth: 1, dash: [2, 2])
            )

            let curve = channel.normalizedCurve
            guard !curve.isEmpty else { return }

            // Subsample for smoother Catmull-Rom rendering
            let step = max(1, curve.count / 64)
            var sampled: [(input: Double, output: Double)] = []
            for i in stride(from: 0, to: curve.count, by: step) {
                sampled.append(curve[i])
            }
            if let last = curve.last, sampled.last?.input != last.input {
                sampled.append(last)
            }

            let points = sampled.map { pt in
                CGPoint(x: pt.input * size.width, y: size.height - pt.output * size.height)
            }

            var path = Path()
            guard points.count >= 2 else { return }
            path.move(to: points[0])

            for i in 0..<(points.count - 1) {
                let p0 = i > 0 ? points[i - 1] : points[i]
                let p1 = points[i]
                let p2 = points[i + 1]
                let p3 = i + 2 < points.count ? points[i + 2] : points[i + 1]

                let cp1 = CGPoint(
                    x: p1.x + (p2.x - p0.x) / 6.0,
                    y: p1.y + (p2.y - p0.y) / 6.0
                )
                let cp2 = CGPoint(
                    x: p2.x - (p3.x - p1.x) / 6.0,
                    y: p2.y - (p3.y - p1.y) / 6.0
                )
                path.addCurve(to: p2, control1: cp1, control2: cp2)
            }
            context.stroke(path, with: .color(channelColor(channel.name)), lineWidth: 1.5)
        }
    }

    // MARK: - Mini Curve Graph

    private func miniCurveGraph(channels: [InkChannel]) -> some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color(nsColor: .textBackgroundColor).opacity(0.5))
            )

            // Grid
            let gridColor = Color.secondary.opacity(0.08)
            for i in 1..<5 {
                let x = CGFloat(i) / 5.0 * size.width
                let y = CGFloat(i) / 5.0 * size.height
                context.stroke(
                    Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                    with: .color(gridColor)
                )
                context.stroke(
                    Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) },
                    with: .color(gridColor)
                )
            }

            // Diagonal
            context.stroke(
                Path { p in p.move(to: CGPoint(x: 0, y: size.height)); p.addLine(to: CGPoint(x: size.width, y: 0)) },
                with: .color(Color.secondary.opacity(0.15)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )

            // Channels
            for channel in channels {
                let curve = channel.normalizedCurve
                guard !curve.isEmpty else { continue }

                // Subsample for smoother Catmull-Rom rendering
                let step = max(1, curve.count / 64)
                var sampled: [(input: Double, output: Double)] = []
                for i in stride(from: 0, to: curve.count, by: step) {
                    sampled.append(curve[i])
                }
                if let last = curve.last, sampled.last?.input != last.input {
                    sampled.append(last)
                }

                let points = sampled.map { pt in
                    CGPoint(x: pt.input * size.width, y: size.height - pt.output * size.height)
                }

                var path = Path()
                guard points.count >= 2 else { continue }
                path.move(to: points[0])

                for i in 0..<(points.count - 1) {
                    let p0 = i > 0 ? points[i - 1] : points[i]
                    let p1 = points[i]
                    let p2 = points[i + 1]
                    let p3 = i + 2 < points.count ? points[i + 2] : points[i + 1]

                    let cp1 = CGPoint(
                        x: p1.x + (p2.x - p0.x) / 6.0,
                        y: p1.y + (p2.y - p0.y) / 6.0
                    )
                    let cp2 = CGPoint(
                        x: p2.x - (p3.x - p1.x) / 6.0,
                        y: p2.y - (p3.y - p1.y) / 6.0
                    )
                    path.addCurve(to: p2, control1: cp1, control2: cp2)
                }
                context.stroke(path, with: .color(channelColor(channel.name)), lineWidth: 1.5)
            }
        }
    }

    // MARK: - Channel Badges

    private func channelBadges(_ channels: [InkChannel]) -> some View {
        HStack(spacing: 4) {
            ForEach(channels) { ch in
                Text(ch.name)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(channelColor(ch.name).opacity(0.15))
                    )
                    .foregroundStyle(channelColor(ch.name))
            }
            Spacer()
        }
    }

    // MARK: - Save Blended Curve

    private func saveBlendedCurve() {
        guard let blended = viewModel.blendedResult else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "quad")].compactMap { $0 }
        panel.nameFieldStringValue = blended.fileName
        panel.message = "Save the blended .quad curve"
        panel.prompt = "Save"

        // Default to the printer's quad directory if it exists
        let printerDir = viewModel.selectedProfile!.quadDirectoryPath
        if FileManager.default.fileExists(atPath: printerDir) {
            panel.directoryURL = URL(fileURLWithPath: printerDir)
        }

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let content = QTRFileParser.serializeQuadFile(blended)
            try? content.write(to: url, atomically: true, encoding: .utf8)

            // If saved into the printer directory, reload
            if url.deletingLastPathComponent().path == printerDir {
                Task { @MainActor in
                    viewModel.loadFilesFromDisk()
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func channelColor(_ name: String) -> Color {
        switch name {
        case "K":   return .primary
        case "C":   return .cyan
        case "M":   return .pink
        case "Y":   return .yellow
        case "LC":  return .teal
        case "LM":  return .purple
        case "LK":  return .gray
        case "LLK": return .mint
        default:    return .secondary
        }
    }
}
