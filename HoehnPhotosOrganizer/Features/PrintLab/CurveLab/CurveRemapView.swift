import SwiftUI
import UniformTypeIdentifiers

// MARK: - CurveRemapView

/// Channel remapping tool: load a .quad file and reassign which source channel's data
/// goes into each target channel slot. Useful for ink-set swaps, channel rotation, and
/// quick K/LK or C/LC swaps without manually editing raw curve data.
struct CurveRemapView: View {

    @ObservedObject var viewModel: CurveLabViewModel

    @State private var showSourcePicker = false
    @State private var enabledChannels: Set<String> = Set(QTRFileParser.standardChannelNames)

    private let standardChannels = QTRFileParser.standardChannelNames

    var body: some View {
        HStack(spacing: 0) {
            leftPanel
                .frame(width: 260)

            Divider()

            centerPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: viewModel.remapChannelMap) { _ in
            viewModel.computeRemap()
        }
        .onChange(of: viewModel.remapSourceQuad) { newSource in
            if newSource != nil {
                viewModel.resetChannelMap()
            }
        }
    }

    // MARK: - Left Panel

    private var leftPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sourceSection
                Divider()
                channelMappingSection
                Divider()
                presetsSection
                Spacer()
            }
            .padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Source Section

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("SOURCE CURVE")

            if let quad = viewModel.remapSourceQuad {
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
                            viewModel.remapSourceQuad = nil
                            viewModel.remapChannelMap = [:]
                            viewModel.remappedQuad = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }

                    miniCurveGraph(channels: quad.activeChannels)
                        .frame(height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                        )

                    channelBadges(quad.activeChannels)
                }
            } else {
                Button {
                    if viewModel.quadFiles.isEmpty {
                        viewModel.loadFilesFromDisk()
                    }
                    showSourcePicker = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 12))
                        Text("Load Source Curve")
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
                .popover(isPresented: $showSourcePicker, arrowEdge: .trailing) {
                    curvePickerPopover(
                        onPick: { viewModel.remapSourceQuad = $0 },
                        dismiss: { showSourcePicker = false }
                    )
                }
            }
        }
    }

    // MARK: - Channel Mapping Section

    private var channelMappingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionLabel("CHANNEL MAPPING")
                Spacer()
                Button("Reset to Default") {
                    viewModel.resetChannelMap()
                }
                .font(.system(size: 10))
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(viewModel.remapSourceQuad == nil)
            }

            if viewModel.remapSourceQuad != nil {
                VStack(spacing: 4) {
                    HStack(spacing: 0) {
                        Text("Target")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 60, alignment: .leading)
                        Spacer()
                        Text("Source Data")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 120, alignment: .trailing)
                    }
                    .padding(.bottom, 2)

                    ForEach(standardChannels, id: \.self) { channelName in
                        channelMappingRow(channelName)
                    }
                }
            } else {
                Text("Load a source curve to configure mapping")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
    }

    private func channelMappingRow(_ targetName: String) -> some View {
        let sourceNames = viewModel.remapSourceQuad?.channelNames ?? standardChannels
        let currentMapping = viewModel.remapChannelMap[targetName] ?? targetName

        return HStack(spacing: 8) {
            HStack(spacing: 4) {
                Circle()
                    .fill(channelColor(targetName))
                    .frame(width: 7, height: 7)
                Text(targetName)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .frame(width: 50, alignment: .leading)

            Image(systemName: "arrow.left")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            Spacer()

            Picker("", selection: Binding(
                get: { currentMapping },
                set: { newValue in
                    viewModel.remapChannelMap[targetName] = newValue
                }
            )) {
                ForEach(sourceNames, id: \.self) { name in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(channelColor(name))
                            .frame(width: 6, height: 6)
                        Text(name)
                    }
                    .tag(name)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 90)
            .controlSize(.small)
        }
        .padding(.vertical, 1)
    }

    // MARK: - Presets Section

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("QUICK PRESETS")

            VStack(spacing: 4) {
                presetButton("Swap K \u{2194} LK") {
                    swapChannels("K", "LK")
                }

                presetButton("Mirror Light Inks") {
                    swapChannels("LC", "C")
                    swapChannels("LM", "M")
                }

                presetButton("Rotate Channels") {
                    rotateChannels()
                }
            }
        }
    }

    private func presetButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                Spacer()
                Image(systemName: "arrow.triangle.swap")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.remapSourceQuad == nil)
    }

    private func swapChannels(_ a: String, _ b: String) {
        let valA = viewModel.remapChannelMap[a] ?? a
        let valB = viewModel.remapChannelMap[b] ?? b
        viewModel.remapChannelMap[a] = valB
        viewModel.remapChannelMap[b] = valA
    }

    private func rotateChannels() {
        let names = standardChannels
        var newMap: [String: String] = [:]
        for (i, name) in names.enumerated() {
            let sourceIndex = (i + 1) % names.count
            let currentSource = viewModel.remapChannelMap[names[sourceIndex]] ?? names[sourceIndex]
            newMap[name] = currentSource
        }
        viewModel.remapChannelMap = newMap
    }

    // MARK: - Center Panel

    private var centerPanel: some View {
        VStack(spacing: 0) {
            centerToolbar
            Divider()

            if viewModel.remapSourceQuad != nil {
                VStack(spacing: 16) {
                    HStack(spacing: 16) {
                        VStack(spacing: 6) {
                            HStack {
                                Text("Before")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            curveGraph(quad: viewModel.remapSourceQuad)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                                )
                        }

                        VStack(spacing: 6) {
                            HStack {
                                Text("After")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            curveGraph(quad: viewModel.remappedQuad)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                                )
                        }
                    }
                    .frame(maxHeight: .infinity)

                    channelToggleBar

                    bottomBar
                }
                .padding(20)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("Load a source curve to begin remapping")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var centerToolbar: some View {
        HStack(spacing: 12) {
            if let source = viewModel.remapSourceQuad {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(source.fileName.replacingOccurrences(of: ".quad", with: ""))
                    .font(.system(size: 11, weight: .medium))

                Image(systemName: "arrow.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                if let remapped = viewModel.remappedQuad {
                    Text(remapped.fileName.replacingOccurrences(of: ".quad", with: ""))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                }
            }

            Spacer()

            if viewModel.remappedQuad != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 12))
                Text("Remap ready")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if viewModel.remapSourceQuad != nil {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                Text("Configure channel mapping")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Channel Toggle Bar

    private var channelToggleBar: some View {
        HStack(spacing: 8) {
            ForEach(standardChannels, id: \.self) { name in
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
                enabledChannels = Set(standardChannels)
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

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if let remapped = viewModel.remappedQuad {
                Text(remapped.fileName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                saveRemappedCurve()
            } label: {
                Label("Save As...", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.remappedQuad == nil)

            Button {
                viewModel.saveRemappedQuad()
            } label: {
                Label("Apply & Save", systemImage: "checkmark.circle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(viewModel.remappedQuad == nil)
        }
    }

    // MARK: - Save As

    private func saveRemappedCurve() {
        guard let remapped = viewModel.remappedQuad else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "quad")].compactMap { $0 }
        panel.nameFieldStringValue = remapped.fileName
        panel.message = "Save the remapped .quad curve"
        panel.prompt = "Save"

        if let profile = viewModel.selectedProfile {
            let printerDir = profile.quadDirectoryPath
            if FileManager.default.fileExists(atPath: printerDir) {
                panel.directoryURL = URL(fileURLWithPath: printerDir)
            }
        }

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let content = QTRFileParser.serializeQuadFile(remapped)
            try? content.write(to: url, atomically: true, encoding: .utf8)

            if let profile = viewModel.selectedProfile,
               url.deletingLastPathComponent().path == profile.quadDirectoryPath {
                Task { @MainActor in
                    viewModel.loadFilesFromDisk()
                }
            }
        }
    }

    // MARK: - Curve Graph

    private func curveGraph(quad: QTRQuadFile?) -> some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color(nsColor: .textBackgroundColor).opacity(0.5))
            )

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

            context.stroke(
                Path { p in p.move(to: CGPoint(x: 0, y: size.height)); p.addLine(to: CGPoint(x: size.width, y: 0)) },
                with: .color(Color.secondary.opacity(0.15)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )

            guard let quad = quad else { return }
            for channel in quad.channels {
                guard enabledChannels.contains(channel.name), channel.isActive else { continue }
                let curve = channel.normalizedCurve
                guard !curve.isEmpty else { continue }

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

    // MARK: - Mini Curve Graph

    private func miniCurveGraph(channels: [InkChannel]) -> some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color(nsColor: .textBackgroundColor).opacity(0.5))
            )

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

            context.stroke(
                Path { p in p.move(to: CGPoint(x: 0, y: size.height)); p.addLine(to: CGPoint(x: size.width, y: 0)) },
                with: .color(Color.secondary.opacity(0.15)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )

            for channel in channels {
                let curve = channel.normalizedCurve
                guard !curve.isEmpty else { continue }

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
                    if let profile = viewModel.selectedProfile {
                        Text(profile.quadDirectoryPath)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
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
