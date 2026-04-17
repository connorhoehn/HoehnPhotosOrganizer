import SwiftUI
import Combine

// MARK: - CurveGalleryView

/// Browse real .quad files from /Library/Printers/QTR/ and SpyderPRINT measurement exports.
/// Shows multi-channel curve visualizations, anomaly detection, and smoothing controls.
struct CurveGalleryView: View {

    @ObservedObject var viewModel: CurveLabViewModel

    @State private var searchText = ""
    @State private var aiSearchText = ""
    @State private var showMeasurements = false
    @State private var filterInkSet: String?
    @State private var filterProcess: String?
    @State private var collapsedGroups: Set<String> = []
    @State private var viewMode: GalleryViewMode = .icon

    private enum GalleryViewMode: String {
        case icon = "Icon"
        case list = "List"
    }

    private var filteredQuads: [QTRQuadFile] {
        var result = viewModel.quadFiles
        if !searchText.isEmpty {
            result = result.filter { $0.fileName.localizedCaseInsensitiveContains(searchText) }
        }
        if let inkFilter = filterInkSet {
            result = result.filter { $0.inferredInkSet.rawValue == inkFilter }
        }
        if let procFilter = filterProcess {
            result = result.filter { $0.inferredProcess.rawValue == procFilter }
        }
        return result
    }

    /// Recently used curves that match current filters, shown at top.
    private var recentlyUsedQuads: [QTRQuadFile] {
        let recentNames = Set(viewModel.usageTracker.recentlyUsed(limit: 8))
        return filteredQuads.filter { recentNames.contains($0.fileName) }
            .sorted { a, b in
                let aDate = viewModel.usageTracker.stats[a.fileName]?.lastViewed ?? .distantPast
                let bDate = viewModel.usageTracker.stats[b.fileName]?.lastViewed ?? .distantPast
                return aDate > bDate
            }
    }

    /// Curves grouped by inferred process, excluding recently-used duplicates from sections.
    private var groupedByProcess: [(process: PrintProcess, curves: [QTRQuadFile])] {
        let recentIDs = Set(recentlyUsedQuads.map(\.id))
        let remaining = filteredQuads.filter { !recentIDs.contains($0.id) }
        let grouped = Dictionary(grouping: remaining) { $0.inferredProcess }
        return PrintProcess.allCases.compactMap { proc in
            guard let curves = grouped[proc], !curves.isEmpty else { return nil }
            return (process: proc, curves: curves)
        }
    }

    private var filteredMeasurements: [SpyderPRINTMeasurement] {
        guard !searchText.isEmpty else { return viewModel.measurements }
        return viewModel.measurements.filter {
            $0.fileName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: filter sidebar
            gallerySidebar
                .frame(width: 200)

            Divider()

            // Main content
            VStack(spacing: 0) {
                galleryToolbar
                Divider()

                if let err = viewModel.loadFilesError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.caption)
                        Spacer()
                        Button("Retry") {
                            viewModel.loadFilesFromDisk()
                        }
                        .font(.caption)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.1))
                }

                if viewModel.isLoadingFiles {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading curves from disk...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 0) {
                        // Grid
                        if showMeasurements {
                            measurementGrid
                        } else {
                            quadFileGrid
                        }

                        // Detail panel
                        if !showMeasurements, viewModel.selectedQuadFileID != nil {
                            Divider()
                            quadDetailPanel
                                .frame(width: 300)
                        }
                        if showMeasurements, viewModel.selectedMeasurementID != nil {
                            Divider()
                            measurementDetailPanel
                                .frame(width: 300)
                        }
                    }
                }
            }

        }
        .onAppear {
            viewModel.loadFilesFromDisk()
        }
    }

    // MARK: - Toolbar

    private var galleryToolbar: some View {
        HStack(spacing: 12) {
            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Search curves...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
            )
            .frame(maxWidth: 220)

            // Toggle: Quad files vs Measurements
            Picker("", selection: $showMeasurements) {
                Text(".quad Files (\(viewModel.quadFiles.count))").tag(false)
                Text("Measurements (\(viewModel.measurements.count))").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 300)

            // View mode toggle
            HStack(spacing: 0) {
                Button {
                    viewMode = .icon
                } label: {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 11))
                        .foregroundStyle(viewMode == .icon ? .primary : .tertiary)
                        .frame(width: 26, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(viewMode == .icon ? Color.primary.opacity(0.08) : .clear)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    viewMode = .list
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 11))
                        .foregroundStyle(viewMode == .list ? .primary : .tertiary)
                        .frame(width: 26, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(viewMode == .list ? Color.primary.opacity(0.08) : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.04))
            )

            Spacer()

            // Counts
            if !showMeasurements {
                Text("\(filteredQuads.count) curves")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("\(filteredMeasurements.count) measurements")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Quad File Grid

    private let gridColumns = [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 12)]

    private var quadFileGrid: some View {
        Group {
            if filteredQuads.isEmpty && !viewModel.isLoadingFiles {
                VStack(spacing: 16) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("No Curves Found")
                        .font(.title3.weight(.semibold))
                    Text("QTR .quad files from /Library/Printers/QTR/ will appear here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Refresh") {
                        viewModel.loadFilesFromDisk()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        // Recently Used — always expanded
                        if !recentlyUsedQuads.isEmpty {
                            curveSection(
                                title: "Recently Used",
                                icon: "clock.arrow.circlepath",
                                curves: recentlyUsedQuads,
                                collapsible: false,
                                collapsed: false
                            )
                        }

                        // Grouped by process — collapsible
                        ForEach(groupedByProcess, id: \.process) { group in
                            let key = group.process.rawValue
                            let isCollapsed = collapsedGroups.contains(key)
                            curveSection(
                                title: key,
                                icon: group.process.icon,
                                curves: group.curves,
                                collapsible: true,
                                collapsed: isCollapsed
                            ) {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    if isCollapsed {
                                        collapsedGroups.remove(key)
                                    } else {
                                        collapsedGroups.insert(key)
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                    .onAppear {
                        // Show first 2 process groups expanded, collapse the rest
                        if collapsedGroups.isEmpty && groupedByProcess.count > 2 {
                            collapsedGroups = Set(groupedByProcess.dropFirst(2).map(\.process.rawValue))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func curveSection(
        title: String,
        icon: String,
        curves: [QTRQuadFile],
        collapsible: Bool = false,
        collapsed: Bool = false,
        onToggle: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header — tappable when collapsible
            HStack(spacing: 6) {
                if collapsible {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("(\(curves.count))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary.opacity(0.5))
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { onToggle?() }

            if !collapsed {
                if viewMode == .icon {
                    LazyVGrid(columns: gridColumns, spacing: 12) {
                        ForEach(curves) { quad in
                            quadCard(quad)
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        viewModel.selectedQuadFileID =
                                            viewModel.selectedQuadFileID == quad.id ? nil : quad.id
                                    }
                                }
                        }
                    }
                } else {
                    VStack(spacing: 1) {
                        ForEach(curves) { quad in
                            quadListRow(quad)
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        viewModel.selectedQuadFileID =
                                            viewModel.selectedQuadFileID == quad.id ? nil : quad.id
                                    }
                                }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func quadCard(_ quad: QTRQuadFile) -> some View {
        let isSelected = viewModel.selectedQuadFileID == quad.id
        let active = quad.activeChannels
        let stats = viewModel.usageTracker.stats[quad.fileName]
        return VStack(alignment: .leading, spacing: 0) {
            // Multi-channel curve preview
            ZStack(alignment: .topTrailing) {
                multiChannelGraph(channels: active)
                    .frame(height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                // Process badge (pin icon when manually overridden)
                HStack(spacing: 3) {
                    if viewModel.processOverrideStore.hasOverride(for: quad.fileName) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 7))
                    }
                    Text(quad.inferredProcess.rawValue)
                        .font(.system(size: 8, weight: .medium))
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.6))
                )
                .foregroundStyle(Color(nsColor: .controlBackgroundColor))
                .padding(6)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(quad.fileName.replacingOccurrences(of: ".quad", with: ""))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)

                // Channel chips
                HStack(spacing: 3) {
                    ForEach(active) { ch in
                        Text(ch.name)
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(channelColor(ch.name).opacity(0.15))
                            )
                            .foregroundStyle(channelColor(ch.name))
                    }
                    Spacer()
                }

                // Metadata row
                HStack(spacing: 6) {
                    Text("\(active.count) ch")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)

                    Text(String(format: "%.0f%%", quad.maxInkLimit))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)

                    if !quad.linearizationHistory.isEmpty {
                        Text("\(quad.linearizationHistory.count) lin.")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }

                    if let s = stats, s.totalInteractions > 0 {
                        Spacer()
                        HStack(spacing: 2) {
                            Image(systemName: "eye")
                                .font(.system(size: 8))
                            Text("\(s.viewCount)")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Button {
                        viewModel.openQuadForEditing(quad)
                    } label: {
                        Text("Edit")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            .padding(8)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.2),
                              lineWidth: isSelected ? 2 : 1)
        )
        .contextMenu {
            Menu("Set Process") {
                ForEach(PrintProcess.allCases) { process in
                    Button {
                        viewModel.processOverrideStore.setOverride(process, for: quad.fileName)
                        // Trigger re-grouping by nudging the published array
                        viewModel.objectWillChange.send()
                    } label: {
                        HStack {
                            Image(systemName: process.icon)
                            Text(process.rawValue)
                            if quad.inferredProcess == process {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                Divider()

                if viewModel.processOverrideStore.hasOverride(for: quad.fileName) {
                    Button("Reset to Auto") {
                        viewModel.processOverrideStore.removeOverride(for: quad.fileName)
                        viewModel.objectWillChange.send()
                    }
                }
            }
        }
    }

    private func quadListRow(_ quad: QTRQuadFile) -> some View {
        let isSelected = viewModel.selectedQuadFileID == quad.id
        let active = quad.activeChannels
        return HStack(spacing: 8) {
            // Mini curve preview
            multiChannelGraph(channels: active)
                .frame(width: 48, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            // Name
            Text(quad.fileName.replacingOccurrences(of: ".quad", with: ""))
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)

            Spacer()

            // Channel badges (compact)
            HStack(spacing: 2) {
                ForEach(active.prefix(4)) { ch in
                    Text(ch.name)
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundStyle(channelColor(ch.name))
                }
                if active.count > 4 {
                    Text("+\(active.count - 4)")
                        .font(.system(size: 7))
                        .foregroundStyle(.tertiary)
                }
            }

            // Ink limit
            Text(String(format: "%.0f%%", quad.maxInkLimit))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 30, alignment: .trailing)

            // Edit button
            Button {
                viewModel.openQuadForEditing(quad)
            } label: {
                Text("Edit")
                    .font(.system(size: 9, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
        .contextMenu {
            Menu("Set Process") {
                ForEach(PrintProcess.allCases) { process in
                    Button {
                        viewModel.processOverrideStore.setOverride(process, for: quad.fileName)
                        viewModel.objectWillChange.send()
                    } label: {
                        HStack {
                            Image(systemName: process.icon)
                            Text(process.rawValue)
                            if quad.inferredProcess == process {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                Divider()

                if viewModel.processOverrideStore.hasOverride(for: quad.fileName) {
                    Button("Reset to Auto") {
                        viewModel.processOverrideStore.removeOverride(for: quad.fileName)
                        viewModel.objectWillChange.send()
                    }
                }
            }
        }
    }

    // MARK: - Multi-Channel Curve Graph

    private func multiChannelGraph(channels: [InkChannel]) -> some View {
        Canvas { context, size in
            // Background
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

            // Diagonal reference
            context.stroke(
                Path { p in p.move(to: CGPoint(x: 0, y: size.height)); p.addLine(to: CGPoint(x: size.width, y: 0)) },
                with: .color(Color.secondary.opacity(0.15)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )

            // Draw each active channel (subsampled for thumbnail performance)
            for channel in channels {
                let curve = channel.normalizedCurve
                guard !curve.isEmpty else { continue }
                // Subsample every 4th point for card thumbnails
                let step = max(1, curve.count / 64)
                var path = Path()
                var first = true
                for i in stride(from: 0, to: curve.count, by: step) {
                    let point = curve[i]
                    let pt = CGPoint(
                        x: point.input * size.width,
                        y: size.height - point.output * size.height
                    )
                    if first { path.move(to: pt); first = false } else { path.addLine(to: pt) }
                }
                if let last = curve.last {
                    path.addLine(to: CGPoint(x: last.input * size.width, y: size.height - last.output * size.height))
                }
                let color = channelColor(channel.name)
                context.stroke(path, with: .color(color), lineWidth: 1.5)
            }
        }
    }

    // MARK: - Measurement Grid

    private var measurementGrid: some View {
        Group {
            if filteredMeasurements.isEmpty && !viewModel.isLoadingFiles {
                VStack(spacing: 16) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("No Measurements Found")
                        .font(.title3.weight(.semibold))
                    Text("SpyderPRINT measurement exports will appear here.\nPoint to a folder containing exported .txt measurement files.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 10) {
                        Button("Choose SpyderPRINT Folder...") {
                            chooseSpyderPRINTFolder()
                        }
                        .buttonStyle(.bordered)
                        Button("Refresh") {
                            viewModel.loadFilesFromDisk()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 220, maximum: 280), spacing: 12)
                    ], spacing: 12) {
                        ForEach(filteredMeasurements) { meas in
                            measurementCard(meas)
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        viewModel.selectedMeasurementID =
                                            viewModel.selectedMeasurementID == meas.id ? nil : meas.id
                                    }
                                }
                        }
                    }
                    .padding(16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func measurementCard(_ meas: SpyderPRINTMeasurement) -> some View {
        let isSelected = viewModel.selectedMeasurementID == meas.id
        let anomalyCount = meas.anomalies.count
        return VStack(alignment: .leading, spacing: 0) {
            // L* curve graph
            labCurveGraph(steps: meas.steps, anomalies: meas.anomalies)
                .frame(height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(meas.fileName.replacingOccurrences(of: ".txt", with: ""))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("\(meas.stepCount) steps")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    if let range = meas.densityRange {
                        Text(String(format: "L* range: %.1f", range))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if anomalyCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                            Text("\(anomalyCount)")
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundStyle(.orange)
                    }
                }
            }
            .padding(8)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor :
                                anomalyCount > 0 ? Color.orange.opacity(0.4) :
                                Color.secondary.opacity(0.2),
                              lineWidth: isSelected ? 2 : 1)
        )
    }

    // MARK: - L* Curve Graph (measurements)

    private func labCurveGraph(steps: [LabStep], anomalies: [AnomalyReport]) -> some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color(nsColor: .textBackgroundColor).opacity(0.5))
            )

            guard !steps.isEmpty else { return }
            let maxL = steps.map(\.labL).max() ?? 100
            let minL = steps.map(\.labL).min() ?? 0
            let rangeL = max(maxL - minL, 1)

            // Grid
            let gridColor = Color.secondary.opacity(0.08)
            for i in 1..<5 {
                let y = CGFloat(i) / 5.0 * size.height
                context.stroke(
                    Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)) },
                    with: .color(gridColor)
                )
            }

            // L* curve
            var path = Path()
            for (i, step) in steps.enumerated() {
                let x = CGFloat(i) / CGFloat(steps.count - 1) * size.width
                let y = size.height - CGFloat((step.labL - minL) / rangeL) * size.height
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(.cyan), lineWidth: 1.5)

            // Mark anomalies
            let anomalyIndices = Set(anomalies.filter({ $0.type == .reversal }).map(\.stepIndex))
            for idx in anomalyIndices {
                guard idx < steps.count else { continue }
                let x = CGFloat(idx) / CGFloat(steps.count - 1) * size.width
                let y = size.height - CGFloat((steps[idx].labL - minL) / rangeL) * size.height
                context.fill(
                    Path(ellipseIn: CGRect(x: x - 3, y: y - 3, width: 6, height: 6)),
                    with: .color(.orange)
                )
            }
        }
    }

    // MARK: - Quad Detail Panel

    private var quadDetailPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let quad = viewModel.selectedQuadFile {
                    // Header
                    Text(quad.fileName)
                        .font(.system(size: 14, weight: .semibold))

                    // Full-size channel graph
                    multiChannelGraph(channels: quad.activeChannels)
                        .frame(height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                        )

                    // Channel summary
                    sectionLabel("ACTIVE CHANNELS")
                    ForEach(quad.activeChannels) { ch in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(channelColor(ch.name))
                                .frame(width: 8, height: 8)
                            Text(ch.name)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                            Spacer()
                            Text(String(format: "max %.1f%%", ch.maxInkPercent))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Linearization history
                    if !quad.linearizationHistory.isEmpty {
                        Divider()
                        sectionLabel("LINEARIZATION HISTORY")
                        ForEach(Array(quad.linearizationHistory.enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading, spacing: 2) {
                                if !entry.measurementFile.isEmpty {
                                    HStack(spacing: 4) {
                                        Image(systemName: "chart.bar")
                                            .font(.system(size: 9))
                                            .foregroundStyle(.secondary)
                                        Text(entry.measurementFile)
                                            .font(.system(size: 10))
                                    }
                                }
                                HStack(spacing: 4) {
                                    Image(systemName: "doc")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                    Text(entry.inputQuadFile)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    // Comments
                    if !quad.comments.isEmpty {
                        Divider()
                        sectionLabel("HEADER COMMENTS")
                        Text(quad.comments.joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Spacer()
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Measurement Detail Panel

    private var measurementDetailPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let meas = viewModel.selectedMeasurement {
                    Text(meas.fileName)
                        .font(.system(size: 14, weight: .semibold))

                    // Full L* graph
                    labCurveGraph(steps: meas.steps, anomalies: meas.anomalies)
                        .frame(height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                        )

                    // Stats
                    sectionLabel("MEASUREMENT STATS")
                    statRow("Steps:", "\(meas.stepCount)")
                    if let white = meas.paperWhiteL {
                        statRow("Paper White L*:", String(format: "%.2f", white))
                    }
                    if let dmax = meas.dMaxL {
                        statRow("Dmax L*:", String(format: "%.2f", dmax))
                    }
                    if let range = meas.densityRange {
                        statRow("Density Range:", String(format: "%.2f", range))
                    }

                    // Anomalies
                    let anomalies = meas.anomalies
                    if !anomalies.isEmpty {
                        Divider()
                        sectionLabel("ANOMALIES (\(anomalies.count))")
                        ForEach(anomalies) { a in
                            HStack(spacing: 6) {
                                Image(systemName: a.type == .reversal
                                      ? "exclamationmark.triangle.fill"
                                      : "minus.circle")
                                    .font(.system(size: 10))
                                    .foregroundStyle(a.type == .reversal ? .orange : .yellow)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Step \(a.step.stepNumber): \(a.type.rawValue)")
                                        .font(.system(size: 10, weight: .medium))
                                    Text(String(format: "L* %.2f → %.2f (delta %.2f)",
                                                a.previousStep.labL, a.step.labL, a.deltaL))
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    // Smoothing controls
                    Divider()
                    sectionLabel("SMOOTHING")
                    HStack {
                        Text("Window:")
                            .font(.system(size: 11))
                        Picker("", selection: $viewModel.smoothingWindow) {
                            Text("3").tag(3)
                            Text("5").tag(5)
                            Text("7").tag(7)
                            Text("9").tag(9)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }

                    // Step data table
                    Divider()
                    sectionLabel("STEP DATA")
                    VStack(spacing: 0) {
                        // Header
                        HStack {
                            Text("#")
                                .frame(width: 30, alignment: .trailing)
                            Text("L*")
                                .frame(width: 50, alignment: .trailing)
                            Text("a*")
                                .frame(width: 50, alignment: .trailing)
                            Text("b*")
                                .frame(width: 50, alignment: .trailing)
                        }
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)

                        Divider()

                        ForEach(meas.steps) { step in
                            HStack {
                                Text("\(step.stepNumber)")
                                    .frame(width: 30, alignment: .trailing)
                                Text(String(format: "%.2f", step.labL))
                                    .frame(width: 50, alignment: .trailing)
                                Text(String(format: "%.2f", step.labA))
                                    .frame(width: 50, alignment: .trailing)
                                Text(String(format: "%.2f", step.labB))
                                    .frame(width: 50, alignment: .trailing)
                            }
                            .font(.system(size: 9, design: .monospaced))
                            .padding(.vertical, 1)
                            .background(
                                meas.anomalies.contains(where: { $0.stepIndex == step.stepNumber })
                                    ? Color.orange.opacity(0.1)
                                    : Color.clear
                            )
                        }
                    }

                    Spacer()
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - SpyderPRINT Folder Picker

    private func chooseSpyderPRINTFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select SpyderPRINT exports folder"
        panel.message = "Choose the folder containing your SpyderPRINT .txt measurement exports."
        panel.begin { response in
            if response == .OK, let url = panel.url {
                UserDefaults.standard.set(url.path, forKey: "spyderPRINTDirectory")
                Task { await viewModel.loadFilesFromDisk() }
            }
        }
    }

    // MARK: - Filter Sidebar

    private var gallerySidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // AI Search
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI SEARCH")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10))
                            .foregroundStyle(.purple)
                        TextField("Describe what you need...", text: $aiSearchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.purple.opacity(0.06))
                    )
                }

                Divider()

                // Printer Config
                VStack(alignment: .leading, spacing: 4) {
                    Text("PRINTER CONFIG")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Picker("", selection: $viewModel.selectedProfile) {
                        ForEach(viewModel.availableProfiles) { profile in
                            Text(profile.displayName).tag(Optional(profile))
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .onChange(of: viewModel.selectedProfile) { _ in
                        viewModel.loadFilesFromDisk()
                    }

                    if let profile = viewModel.selectedProfile {
                        Text("\(profile.printerFamily) · \(profile.inkSetLabel)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }

                Divider()

                // Ink Set
                VStack(alignment: .leading, spacing: 4) {
                    Text("INK SET")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)

                    ForEach(InkSet.allCases) { ink in
                        // Cross-filter: count respects process filter
                        let base = filterProcess != nil
                            ? viewModel.quadFiles.filter { $0.inferredProcess.rawValue == filterProcess }
                            : viewModel.quadFiles
                        let count = base.filter { $0.inferredInkSet == ink }.count
                        Button {
                            filterInkSet = filterInkSet == ink.rawValue ? nil : ink.rawValue
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: ink.icon)
                                    .font(.system(size: 9))
                                Text(ink.rawValue)
                                    .font(.system(size: 10))
                                Spacer()
                                Text("\(count)")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                if filterInkSet == ink.rawValue {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.vertical, 2)
                            .foregroundStyle(filterInkSet == ink.rawValue ? .primary : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()

                // Process
                VStack(alignment: .leading, spacing: 4) {
                    Text("PROCESS")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)

                    ForEach(PrintProcess.allCases) { process in
                        // Cross-filter: count respects ink set filter
                        let base = filterInkSet != nil
                            ? viewModel.quadFiles.filter { $0.inferredInkSet.rawValue == filterInkSet }
                            : viewModel.quadFiles
                        let count = base.filter { $0.inferredProcess == process }.count
                        Button {
                            filterProcess = filterProcess == process.rawValue ? nil : process.rawValue
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: process.icon)
                                    .font(.system(size: 9))
                                Text(process.rawValue)
                                    .font(.system(size: 10))
                                Spacer()
                                Text("\(count)")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                if filterProcess == process.rawValue {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9))
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.vertical, 2)
                            .foregroundStyle(filterProcess == process.rawValue ? .primary : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Clear filters
                if filterInkSet != nil || filterProcess != nil {
                    Button {
                        filterInkSet = nil
                        filterProcess = nil
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 9))
                            Text("Clear Filters")
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }

                Divider()

                // Quick stats
                VStack(alignment: .leading, spacing: 4) {
                    Text("LIBRARY")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text("\(viewModel.quadFiles.count) curves")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("\(viewModel.measurements.count) measurements")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("\(viewModel.availableProfiles.count) printer configs")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Spacer()
            }
            .padding(10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
        }
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
