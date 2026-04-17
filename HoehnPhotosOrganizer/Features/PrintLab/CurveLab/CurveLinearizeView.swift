import SwiftUI
import UniformTypeIdentifiers

// MARK: - CurveLinearizeView

/// QTR-style linearization tool: three-panel layout with measurement data table,
/// L*/a*/b* graph with controls, and output ink curves with save.
struct CurveLinearizeView: View {

    @ObservedObject var viewModel: CurveLabViewModel

    @State private var enabledChannels: Set<String> = ["K", "C", "M", "Y", "LC", "LM", "LK", "LLK"]
    @State private var saveFileName: String = "Linearized.quad"
    @State private var collapsedSections: Set<String> = []
    @State private var showAllMeasurements = false
    @State private var isLinearizing = false
    @State private var smoothingDebounceTask: Task<Void, Never>?
    @State private var showExportPicker = false

    // Zone blend weights for linearization output
    @State private var linearizeBlendHighlights: Double = 100
    @State private var linearizeBlendMidtones: Double = 100
    @State private var linearizeBlendShadows: Double = 100

    var body: some View {
        HStack(spacing: 0) {
            leftPanel
                .frame(width: 220)

            Divider()

            centerPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            rightPanel
                .frame(width: 320)
        }
        .onAppear {
            if viewModel.quadFiles.isEmpty && !viewModel.isLoadingFiles {
                viewModel.loadFilesFromDisk()
            }
        }
    }

    // MARK: - Left Panel — Measurement Data Table

    private var leftPanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("MEASUREMENTS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                // Plus button for manual file open
                Button {
                    viewModel.openAdHocMeasurementFile()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open measurement file")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Recent export files section
                    collapsibleSection("Recent Exports") {
                        recentExportsSection
                    }

                    Divider()

                    // Measurement sorting — above data
                    collapsibleSection("Sorting") {
                        HStack(spacing: 6) {
                            Button("Pivot") { viewModel.pivotMeasurement() }
                                .font(.system(size: 10))
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .disabled(viewModel.linearizeMeasurement == nil)

                            Button("Sort") { viewModel.sortMeasurement() }
                                .font(.system(size: 10))
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .disabled(viewModel.linearizeMeasurement == nil)

                            Button("Revert") { viewModel.revertMeasurement() }
                                .font(.system(size: 10))
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .disabled(viewModel.linearizeMeasurement == nil)

                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }

                    Divider()

                    // Measurement data — collapsible, truncated
                    collapsibleSection("Measurement Data\(viewModel.linearizeMeasurement.map { " (\($0.steps.count) steps)" } ?? "")") {
                        measurementDataSection
                    }
                }
            }

            // Current filename at bottom
            if let meas = viewModel.linearizeMeasurement {
                Divider()
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(meas.fileName)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Recent Exports

    private var recentExportsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let profile = viewModel.selectedProfile {
                let exportPath = profile.quadDirectoryPath + "/export"
                let recentFiles = recentExportFiles(at: exportPath)
                if recentFiles.isEmpty {
                    Text("No exports found")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                } else {
                    ForEach(Array(recentFiles.prefix(3).enumerated()), id: \.offset) { _, file in
                        Button {
                            loadExportFile(file)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                Text(file.lastPathComponent)
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(fileDate(file))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.quaternary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Text("Select a profile first")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
        }
    }

    private func recentExportFiles(at path: String) -> [URL] {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        guard let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() == "txt" }
            .sorted { a, b in
                let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return aDate > bDate
            }
    }

    private func fileDate(_ url: URL) -> String {
        guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func loadExportFile(_ url: URL) {
        guard let measurement = try? QTRFileParser.parseMeasurement(at: url) else { return }
        viewModel.linearizeMeasurement = measurement
        viewModel.linearizeOriginalMeasurement = measurement
    }

    // MARK: - Measurement Data (truncated)

    private var measurementDataSection: some View {
        Group {
            if let meas = viewModel.linearizeMeasurement {
                VStack(spacing: 0) {
                    // Table header
                    HStack(spacing: 0) {
                        Text("Step")
                            .frame(width: 36, alignment: .trailing)
                        Text("L*")
                            .frame(width: 52, alignment: .trailing)
                        Text("a*")
                            .frame(width: 52, alignment: .trailing)
                        Text("b*")
                            .frame(width: 52, alignment: .trailing)
                    }
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .controlBackgroundColor))

                    Divider()

                    let anomalyIndices = anomalousStepIndices(meas)
                    let maxVisible = showAllMeasurements ? meas.steps.count : min(15, meas.steps.count)
                    let visibleSteps = Array(meas.steps.prefix(maxVisible))

                    ForEach(Array(visibleSteps.enumerated()), id: \.offset) { index, step in
                        HStack(spacing: 0) {
                            Text("\(step.stepNumber)")
                                .frame(width: 36, alignment: .trailing)
                            Text(String(format: "%.2f", step.labL))
                                .frame(width: 52, alignment: .trailing)
                            Text(String(format: "%.2f", step.labA))
                                .frame(width: 52, alignment: .trailing)
                            Text(String(format: "%.2f", step.labB))
                                .frame(width: 52, alignment: .trailing)
                        }
                        .font(.system(size: 9, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2)
                        .background(
                            anomalyIndices.contains(index)
                                ? Color.orange.opacity(0.18)
                                : (index % 2 == 0 ? Color.clear : Color.primary.opacity(0.02))
                        )
                    }

                    if meas.steps.count > 15 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showAllMeasurements.toggle() }
                        } label: {
                            Text(showAllMeasurements ? "Show less" : "Show all \(meas.steps.count)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "ruler")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("No measurement loaded")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("Load an export file or use + to open.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
    }

    // MARK: - Collapsible Section

    private func collapsibleSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if collapsedSections.contains(title) {
                        collapsedSections.remove(title)
                    } else {
                        collapsedSections.insert(title)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: collapsedSections.contains(title) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Text(title.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !collapsedSections.contains(title) {
                content()
            }
        }
    }

    // MARK: - Center Panel — L*/a*/b* Graph + Controls

    private var centerPanel: some View {
        VStack(spacing: 0) {
            // Toolbar row with Linearize button
            HStack(spacing: 8) {
                // Stats row
                if let meas = viewModel.linearizeMeasurement {
                    statReadout(label: "D-Max", value: dMaxReadout(meas))
                    statReadout(label: "Paper White L*", value: paperWhiteReadout(meas))
                    statReadout(label: "Density Range", value: densityRangeReadout(meas))
                }
                Spacer()
                Button {
                    performLinearize()
                } label: {
                    Label("Linearize", systemImage: "line.diagonal")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.linearizeMeasurement == nil || viewModel.linearizeSourceQuad == nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Graph with overlay controls
            ZStack {
                labGraph
                    .opacity(isLinearizing ? 0.4 : 1.0)

                if isLinearizing {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Linearizing...")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                // Show Original Curves overlay toggle (top-right)
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            viewModel.showOriginalCurves.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: viewModel.showOriginalCurves ? "eye.fill" : "eye.slash")
                                    .font(.system(size: 9))
                                Text("Original")
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(viewModel.showOriginalCurves
                                          ? Color.accentColor.opacity(0.15)
                                          : Color(nsColor: .controlBackgroundColor).opacity(0.8))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Controls below graph
            VStack(spacing: 8) {
                // Controls grid
                VStack(spacing: 6) {
                    HStack {
                        Toggle(isOn: $viewModel.linearizeConfig.invertCurve) {
                            Text("Invert Quad Curve")
                                .font(.system(size: 11))
                        }
                        .toggleStyle(.checkbox)
                        Spacer()
                    }

                    // Main Smoothing — debounced
                    HStack(spacing: 8) {
                        Text("Main Smoothing")
                            .font(.system(size: 11))
                            .frame(width: 120, alignment: .leading)
                        Slider(value: $viewModel.linearizeConfig.mainSmoothing, in: 0...100, step: 1)
                            .onChange(of: viewModel.linearizeConfig.mainSmoothing) { _ in
                                debouncedRelinearize()
                            }
                        Text(String(format: "%.0f", viewModel.linearizeConfig.mainSmoothing))
                            .font(.system(size: 10, design: .monospaced))
                            .frame(width: 28, alignment: .trailing)
                    }

                    // Output Curve Type
                    HStack(spacing: 8) {
                        Text("Output Curve Type")
                            .font(.system(size: 11))
                            .frame(width: 120, alignment: .leading)
                        Picker("", selection: $viewModel.linearizeConfig.outputCurveType) {
                            ForEach(OutputCurveType.allCases) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    HStack {
                        Toggle(isOn: $viewModel.linearizeConfig.gravureCorrection) {
                            Text("Gravure/Positive Correction")
                                .font(.system(size: 11))
                        }
                        .toggleStyle(.checkbox)
                        Spacer()
                    }
                }

                // Zone blend sliders — only after linearization has been run
                if viewModel.linearizedQuad != nil {
                    Divider()
                    VStack(spacing: 4) {
                        HStack {
                            Text("ZONE BLEND")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("How much new linearization to apply per zone")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        zoneBlendSlider("Highlights", value: $linearizeBlendHighlights)
                        zoneBlendSlider("Midtones", value: $linearizeBlendMidtones)
                        zoneBlendSlider("Shadows", value: $linearizeBlendShadows)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func zoneBlendSlider(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .frame(width: 70, alignment: .leading)
            Slider(value: value, in: 0...100, step: 1)
            Text(String(format: "%.0f%%", value.wrappedValue))
                .font(.system(size: 9, design: .monospaced))
                .frame(width: 32, alignment: .trailing)
        }
    }

    private func performLinearize() {
        isLinearizing = true
        // Run on next tick to let the UI update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            viewModel.linearize()
            withAnimation(.easeInOut(duration: 0.2)) {
                isLinearizing = false
            }
        }
    }

    private func debouncedRelinearize() {
        // Only re-linearize if we already have a result
        guard viewModel.linearizedQuad != nil else { return }
        smoothingDebounceTask?.cancel()
        isLinearizing = true
        smoothingDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms debounce
            guard !Task.isCancelled else { return }
            viewModel.linearize()
            withAnimation(.easeInOut(duration: 0.2)) {
                isLinearizing = false
            }
        }
    }

    // MARK: - Right Panel — Output Ink Curves

    private var rightPanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("OUTPUT INK CURVES")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            // Ink curve graph
            inkCurveGraph
                .frame(maxWidth: .infinity)
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .padding(.horizontal, 10)
                .padding(.top, 8)

            // Controls below graph
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // Open Quad File
                    VStack(alignment: .leading, spacing: 4) {
                        if let quad = viewModel.linearizeSourceQuad {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                Text(quad.fileName)
                                    .font(.system(size: 10))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }

                        Button {
                            viewModel.openAdHocQuadFile()
                        } label: {
                            Label("Open Quad File", systemImage: "folder")
                                .font(.system(size: 11))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    // Ink channel smoothing — debounced
                    HStack(spacing: 8) {
                        Text("Ink Smoothing")
                            .font(.system(size: 11))
                            .frame(width: 90, alignment: .leading)
                        Slider(value: $viewModel.linearizeConfig.inkSmoothing, in: 0...100, step: 1)
                            .onChange(of: viewModel.linearizeConfig.inkSmoothing) { _ in
                                debouncedRelinearize()
                            }
                        Text(String(format: "%.0f", viewModel.linearizeConfig.inkSmoothing))
                            .font(.system(size: 10, design: .monospaced))
                            .frame(width: 28, alignment: .trailing)
                    }

                    // Channel toggles
                    channelToggleBar

                    Divider()

                    // Notes
                    VStack(alignment: .leading, spacing: 4) {
                        Text("NOTES")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)

                        TextEditor(text: $viewModel.linearizeNotes)
                            .font(.system(size: 10))
                            .frame(height: 60)
                            .scrollContentBackground(.hidden)
                            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    }

                    Divider()

                    // Save section
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SAVE OUTPUT")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 6) {
                            TextField("Filename", text: $saveFileName)
                                .font(.system(size: 10, design: .monospaced))
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                        }

                        Button {
                            viewModel.autoInstallLinearizedQuad()
                        } label: {
                            Label("Save as .quad file", systemImage: "square.and.arrow.down")
                                .font(.system(size: 11))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(viewModel.linearizedQuad == nil)
                    }
                }
                .padding(10)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - L*/a*/b* Graph

    private var labGraph: some View {
        ZStack {
            Canvas { context, size in
                let insetLeft: CGFloat = 36
                let insetRight: CGFloat = 36
                let insetTop: CGFloat = 12
                let insetBottom: CGFloat = 24
                let plotW = size.width - insetLeft - insetRight
                let plotH = size.height - insetTop - insetBottom
                let plotRect = CGRect(x: insetLeft, y: insetTop, width: plotW, height: plotH)

                // Background
                context.fill(Path(CGRect(origin: .zero, size: size)),
                             with: .color(Color(nsColor: .textBackgroundColor).opacity(0.5)))

                // Plot area fill
                context.fill(Path(plotRect),
                             with: .color(Color(nsColor: .textBackgroundColor).opacity(0.3)))

                // Grid lines at 10-unit intervals
                let gridColor = Color.secondary.opacity(0.1)
                for i in 0...10 {
                    let frac = CGFloat(i) / 10.0
                    // Vertical grid
                    let gx = insetLeft + frac * plotW
                    context.stroke(
                        Path { p in p.move(to: CGPoint(x: gx, y: insetTop)); p.addLine(to: CGPoint(x: gx, y: insetTop + plotH)) },
                        with: .color(gridColor)
                    )
                    // Horizontal grid
                    let gy = insetTop + frac * plotH
                    context.stroke(
                        Path { p in p.move(to: CGPoint(x: insetLeft, y: gy)); p.addLine(to: CGPoint(x: insetLeft + plotW, y: gy)) },
                        with: .color(gridColor)
                    )
                }

                // Left Y-axis labels (L*: 0-100, bottom to top)
                for i in stride(from: 0, through: 100, by: 20) {
                    let frac = CGFloat(i) / 100.0
                    let y = insetTop + plotH - frac * plotH
                    context.draw(
                        Text("\(i)")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.red.opacity(0.7)),
                        at: CGPoint(x: insetLeft - 6, y: y),
                        anchor: .trailing
                    )
                }

                // Right Y-axis labels (a*/b*: -100 to +100, bottom to top)
                for i in stride(from: -100, through: 100, by: 50) {
                    let frac = (CGFloat(i) + 100.0) / 200.0
                    let y = insetTop + plotH - frac * plotH
                    context.draw(
                        Text("\(i)")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.7)),
                        at: CGPoint(x: insetLeft + plotW + 6, y: y),
                        anchor: .leading
                    )
                }

                // X-axis labels (0-100)
                for i in stride(from: 0, through: 100, by: 20) {
                    let frac = CGFloat(i) / 100.0
                    let x = insetLeft + frac * plotW
                    context.draw(
                        Text("\(i)")
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.7)),
                        at: CGPoint(x: x, y: insetTop + plotH + 10),
                        anchor: .center
                    )
                }

                // Axis titles
                context.draw(
                    Text("L*")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.red.opacity(0.6)),
                    at: CGPoint(x: 8, y: insetTop + plotH / 2),
                    anchor: .center
                )
                context.draw(
                    Text("a*/b*")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.6)),
                    at: CGPoint(x: size.width - 8, y: insetTop + plotH / 2),
                    anchor: .center
                )
                context.draw(
                    Text("Input %")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.6)),
                    at: CGPoint(x: insetLeft + plotW / 2, y: size.height - 2),
                    anchor: .center
                )

                // Ideal linear L* reference (diagonal) — black dashed
                context.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: insetLeft, y: insetTop + plotH))
                        p.addLine(to: CGPoint(x: insetLeft + plotW, y: insetTop))
                    },
                    with: .color(Color.primary.opacity(0.25)),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 3])
                )

                // a*/b* zero line (horizontal center on right axis scale)
                let zeroY = insetTop + plotH * 0.5
                context.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: insetLeft, y: zeroY))
                        p.addLine(to: CGPoint(x: insetLeft + plotW, y: zeroY))
                    },
                    with: .color(Color.secondary.opacity(0.15)),
                    style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])
                )

                // Draw measurement curves
                guard let meas = viewModel.linearizeMeasurement, !meas.steps.isEmpty else { return }

                let stepCount = meas.steps.count

                // L* curve (red) — mapped to left Y-axis (0-100)
                drawLabCurve(context: context, steps: meas.steps, plotRect: plotRect,
                             valueExtractor: { $0.labL },
                             minVal: 0, maxVal: 100, color: .red, lineWidth: 2.0)

                // a* curve (blue) — mapped to right Y-axis (-100 to +100)
                drawLabCurve(context: context, steps: meas.steps, plotRect: plotRect,
                             valueExtractor: { $0.labA },
                             minVal: -100, maxVal: 100, color: .blue, lineWidth: 1.2)

                // b* curve (green) — mapped to right Y-axis (-100 to +100)
                drawLabCurve(context: context, steps: meas.steps, plotRect: plotRect,
                             valueExtractor: { $0.labB },
                             minVal: -100, maxVal: 100, color: .green, lineWidth: 1.2)

                // Highlight anomalous steps with orange dots
                let anomalySet = anomalousStepIndices(meas)
                for idx in anomalySet {
                    let step = meas.steps[idx]
                    let xFrac = CGFloat(idx) / CGFloat(max(stepCount - 1, 1))
                    let yFrac = CGFloat(step.labL) / 100.0
                    let px = insetLeft + xFrac * plotW
                    let py = insetTop + plotH - yFrac * plotH
                    context.fill(
                        Path(ellipseIn: CGRect(x: px - 3, y: py - 3, width: 6, height: 6)),
                        with: .color(.orange)
                    )
                }
            }

            // Legend overlay
            VStack {
                HStack(spacing: 12) {
                    Spacer()
                    legendItem(color: .red, label: "L*")
                    legendItem(color: .blue, label: "a*")
                    legendItem(color: .green, label: "b*")
                    legendItem(color: .primary.opacity(0.4), label: "Ideal", dashed: true)
                }
                .padding(.horizontal, 44)
                .padding(.top, 4)
                Spacer()
            }

            // Empty state
            if viewModel.linearizeMeasurement == nil {
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("Load a measurement file to see L*/a*/b* curves")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Ink Curve Graph

    private var inkCurveGraph: some View {
        ZStack {
            Canvas { context, size in
                let insetLeft: CGFloat = 30
                let insetRight: CGFloat = 10
                let insetTop: CGFloat = 10
                let insetBottom: CGFloat = 22
                let plotW = size.width - insetLeft - insetRight
                let plotH = size.height - insetTop - insetBottom
                let plotRect = CGRect(x: insetLeft, y: insetTop, width: plotW, height: plotH)

                // Background
                context.fill(Path(CGRect(origin: .zero, size: size)),
                             with: .color(Color(nsColor: .textBackgroundColor).opacity(0.5)))

                // Grid
                let gridColor = Color.secondary.opacity(0.08)
                for i in 0...10 {
                    let frac = CGFloat(i) / 10.0
                    let gx = insetLeft + frac * plotW
                    let gy = insetTop + frac * plotH
                    context.stroke(
                        Path { p in p.move(to: CGPoint(x: gx, y: insetTop)); p.addLine(to: CGPoint(x: gx, y: insetTop + plotH)) },
                        with: .color(gridColor)
                    )
                    context.stroke(
                        Path { p in p.move(to: CGPoint(x: insetLeft, y: gy)); p.addLine(to: CGPoint(x: insetLeft + plotW, y: gy)) },
                        with: .color(gridColor)
                    )
                }

                // Axis labels
                for i in stride(from: 0, through: 100, by: 20) {
                    let frac = CGFloat(i) / 100.0
                    let x = insetLeft + frac * plotW
                    let y = insetTop + plotH - frac * plotH
                    context.draw(
                        Text("\(i)")
                            .font(.system(size: 7, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.6)),
                        at: CGPoint(x: x, y: insetTop + plotH + 10),
                        anchor: .center
                    )
                    context.draw(
                        Text("\(i)")
                            .font(.system(size: 7, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.6)),
                        at: CGPoint(x: insetLeft - 4, y: y),
                        anchor: .trailing
                    )
                }

                // Diagonal reference
                context.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: insetLeft, y: insetTop + plotH))
                        p.addLine(to: CGPoint(x: insetLeft + plotW, y: insetTop))
                    },
                    with: .color(Color.secondary.opacity(0.15)),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                )

                // Draw original curves (dashed, lighter) if toggled
                if viewModel.showOriginalCurves, let sourceQuad = viewModel.linearizeSourceQuad {
                    for channel in sourceQuad.channels {
                        guard enabledChannels.contains(channel.name), channel.isActive else { continue }
                        drawInkChannel(context: context, channel: channel, plotRect: plotRect,
                                       color: channelColor(channel.name).opacity(0.35),
                                       lineWidth: 1.0, dashed: true)
                    }
                }

                // Draw active channels from linearized quad (or source if no result)
                let displayQuad = viewModel.linearizedQuad ?? viewModel.linearizeSourceQuad
                guard let quad = displayQuad else { return }

                for channel in quad.channels {
                    guard enabledChannels.contains(channel.name), channel.isActive else { continue }
                    drawInkChannel(context: context, channel: channel, plotRect: plotRect,
                                   color: channelColor(channel.name),
                                   lineWidth: 1.5, dashed: false)
                }
            }

            // Empty state
            if viewModel.linearizeSourceQuad == nil && viewModel.linearizedQuad == nil {
                VStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("Load a .quad file")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Channel Toggle Bar

    private var channelToggleBar: some View {
        let allNames = ["K", "C", "M", "Y", "LC", "LM", "LK", "LLK"]
        return HStack(spacing: 4) {
            ForEach(allNames, id: \.self) { name in
                Button {
                    if enabledChannels.contains(name) {
                        enabledChannels.remove(name)
                    } else {
                        enabledChannels.insert(name)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(channelColor(name))
                            .frame(width: 6, height: 6)
                        Text(name)
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(enabledChannels.contains(name)
                                  ? channelColor(name).opacity(0.12)
                                  : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(enabledChannels.contains(name)
                                          ? channelColor(name).opacity(0.3)
                                          : Color.secondary.opacity(0.12),
                                          lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(enabledChannels.contains(name) ? .primary : .tertiary)
            }
        }
    }

    // MARK: - Drawing Helpers

    /// Draw a Lab curve (L*, a*, or b*) on the measurement graph.
    private func drawLabCurve(
        context: GraphicsContext,
        steps: [LabStep],
        plotRect: CGRect,
        valueExtractor: (LabStep) -> Double,
        minVal: Double,
        maxVal: Double,
        color: Color,
        lineWidth: CGFloat
    ) {
        guard steps.count >= 2 else { return }
        let count = steps.count

        let points: [CGPoint] = steps.enumerated().map { index, step in
            let xFrac = CGFloat(index) / CGFloat(max(count - 1, 1))
            let val = valueExtractor(step)
            let yFrac = CGFloat((val - minVal) / (maxVal - minVal))
            return CGPoint(
                x: plotRect.minX + xFrac * plotRect.width,
                y: plotRect.maxY - yFrac * plotRect.height
            )
        }

        let path = catmullRomPath(points: points)
        context.stroke(path, with: .color(color), lineWidth: lineWidth)
    }

    /// Draw an ink channel curve using Catmull-Rom spline interpolation.
    private func drawInkChannel(
        context: GraphicsContext,
        channel: InkChannel,
        plotRect: CGRect,
        color: Color,
        lineWidth: CGFloat,
        dashed: Bool
    ) {
        let curve = channel.normalizedCurve
        guard !curve.isEmpty else { return }

        // Subsample every 4th point for smoother rendering
        let step = max(1, curve.count / 64)
        var sampled: [(input: Double, output: Double)] = []
        for i in stride(from: 0, to: curve.count, by: step) {
            sampled.append(curve[i])
        }
        if let last = curve.last, sampled.last?.input != last.input {
            sampled.append(last)
        }

        let points = sampled.map { pt in
            CGPoint(
                x: plotRect.minX + pt.input * plotRect.width,
                y: plotRect.maxY - pt.output * plotRect.height
            )
        }

        let path = catmullRomPath(points: points)
        let style = dashed
            ? StrokeStyle(lineWidth: lineWidth, dash: [4, 3])
            : StrokeStyle(lineWidth: lineWidth)
        context.stroke(path, with: .color(color), style: style)
    }

    /// Build a Catmull-Rom spline path through the given points.
    private func catmullRomPath(points: [CGPoint]) -> Path {
        var path = Path()
        guard points.count >= 2 else { return path }
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
        return path
    }

    // MARK: - Stat Helpers

    private func dMaxReadout(_ meas: SpyderPRINTMeasurement) -> String {
        guard let dMaxL = meas.dMaxL else { return "--" }
        // D-Max as optical density: log10(100 / L*)
        let density = dMaxL > 0 ? log10(100.0 / dMaxL) : 0
        return String(format: "%.3f (L*=%.1f)", density, dMaxL)
    }

    private func paperWhiteReadout(_ meas: SpyderPRINTMeasurement) -> String {
        guard let pw = meas.paperWhiteL else { return "--" }
        return String(format: "%.2f", pw)
    }

    private func densityRangeReadout(_ meas: SpyderPRINTMeasurement) -> String {
        guard let dr = meas.densityRange else { return "--" }
        return String(format: "%.1f", dr)
    }

    private func statReadout(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
    }

    // MARK: - Legend

    private func legendItem(color: Color, label: String, dashed: Bool = false) -> some View {
        HStack(spacing: 4) {
            if dashed {
                Rectangle()
                    .fill(color)
                    .frame(width: 12, height: 1.5)
                    .overlay(
                        Rectangle()
                            .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                            .foregroundStyle(color)
                    )
            } else {
                Rectangle()
                    .fill(color)
                    .frame(width: 12, height: 2)
            }
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Anomaly Detection

    /// Returns the set of step indices where L* reversals occur.
    private func anomalousStepIndices(_ meas: SpyderPRINTMeasurement) -> Set<Int> {
        var indices = Set<Int>()
        for i in 1..<meas.steps.count {
            let delta = meas.steps[i].labL - meas.steps[i - 1].labL
            if delta > 1.0 {
                indices.insert(i)
            }
        }
        return indices
    }

    // MARK: - Channel Color

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
