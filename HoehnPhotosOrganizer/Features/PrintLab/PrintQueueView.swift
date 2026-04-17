import Combine
import SwiftUI

// MARK: - ViewModel

@MainActor
final class PrintQueueViewModel: ObservableObject {
    @Published var printers: [CUPSPrinterInfo] = []
    @Published var activeJobs: [CUPSJobInfo] = []
    @Published var completedJobs: [CUPSJobInfo] = []
    @Published var logs: String = ""
    @Published var isLoading = false
    @Published var selectedPrinterId: String?
    @Published var selectedTab: Tab = .overview

    private var pollTimer: Timer?
    private var pollTickCount: Int = 0

    /// Ink levels refresh every this-many poll ticks (10 * 3s = 30s).
    private let inkRefreshInterval: Int = 10

    /// All printers excluding scanners.
    var visiblePrinters: [CUPSPrinterInfo] {
        printers.filter { !$0.isScanner }
    }

    /// QTR printers — primary working printers.
    var qtrPrinters: [CUPSPrinterInfo] {
        visiblePrinters.filter { $0.isQTR }
    }

    /// Stock/default drivers (non-QTR printers).
    var defaultPrinters: [CUPSPrinterInfo] {
        visiblePrinters.filter { !$0.isQTR }
    }

    var selectedPrinter: CUPSPrinterInfo? {
        printers.first { $0.id == selectedPrinterId }
    }

    func activeJobsForPrinter(_ id: String) -> [CUPSJobInfo] {
        activeJobs.filter { $0.printerName == id }
    }

    enum Tab: String, CaseIterable, Identifiable {
        case overview   = "Overview"
        case jobs       = "Jobs"
        case logs       = "Logs"
        var id: String { rawValue }
    }

    func load() {
        isLoading = true
        Task {
            let service = CUPSService.shared
            let p = await service.fetchPrinters()
            let active = await service.fetchActiveJobs()
            let completed = await service.fetchCompletedJobs()
            printers = p
            activeJobs = active
            completedJobs = completed
            if selectedPrinterId == nil {
                // Prefer a QTR printer, fall back to first visible
                selectedPrinterId = p.first(where: { $0.isQTR && !$0.isScanner })?.id
                    ?? p.first(where: { !$0.isScanner })?.id
            }
            isLoading = false
        }
    }

    func startPolling() {
        pollTimer?.invalidate()
        pollTickCount = 0
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.pollTickCount += 1
                let refreshInk = self.pollTickCount % self.inkRefreshInterval == 0
                let service = CUPSService.shared
                // Lightweight refresh: active jobs + printer state only (no PPD re-parse)
                // Ink levels piggyback every ~30s to stay reasonably current
                self.activeJobs = await service.fetchActiveJobs()
                self.printers = await service.refreshPrinterStates(
                    printers: self.printers, refreshInk: refreshInk
                )
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func loadLogs() {
        Task {
            logs = await CUPSService.shared.fetchRecentLogs()
        }
    }

    func refreshJobs() {
        Task {
            completedJobs = await CUPSService.shared.fetchCompletedJobs()
        }
    }
}

// MARK: - PrintQueueView

struct PrintQueueView: View {
    @StateObject private var vm = PrintQueueViewModel()

    var body: some View {
        HSplitView {
            printerList
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 300)

            if let printer = vm.selectedPrinter {
                printerDetail(printer)
            } else {
                emptyState
            }
        }
        .onAppear {
            vm.load()
            vm.startPolling()
        }
        .onDisappear {
            vm.stopPolling()
        }
    }

    // MARK: - Printer List (Left)

    private var printerList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Printers")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { vm.load() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Refresh all printer data")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if vm.isLoading && vm.printers.isEmpty {
                Spacer()
                ProgressView()
                Spacer()
            } else if vm.printers.isEmpty {
                Spacer()
                Text("No printers found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(selection: $vm.selectedPrinterId) {
                    if !vm.qtrPrinters.isEmpty {
                        Section("QTR Printers") {
                            ForEach(vm.qtrPrinters) { printer in
                                printerRow(printer)
                                    .tag(printer.id)
                            }
                        }
                    }

                    if !vm.defaultPrinters.isEmpty {
                        Section("Defaults") {
                            ForEach(vm.defaultPrinters) { printer in
                                printerRow(printer)
                                    .tag(printer.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func printerRow(_ printer: CUPSPrinterInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: printer.isQTR ? "printer.dotmatrix.fill" : "printer.fill")
                .font(.system(size: 14))
                .foregroundStyle(stateColor(printer.state))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(printer.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    if printer.isDefault {
                        Text("Default")
                            .font(.system(size: 8, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                Text(printer.state.rawValue.capitalized)
                    .font(.system(size: 9))
                    .foregroundStyle(stateColor(printer.state))
            }

            Spacer()

            if printer.queuedJobCount > 0 {
                Text("\(printer.queuedJobCount)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.orange, in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Printer Detail (Right)

    private func printerDetail(_ printer: CUPSPrinterInfo) -> some View {
        VStack(spacing: 0) {
            printerHeader(printer)
            Divider()

            // Tab bar
            HStack(spacing: 2) {
                ForEach(PrintQueueViewModel.Tab.allCases) { tab in
                    Button {
                        vm.selectedTab = tab
                        if tab == .logs { vm.loadLogs() }
                        if tab == .jobs { vm.refreshJobs() }
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: vm.selectedTab == tab ? .semibold : .regular))
                            .foregroundStyle(vm.selectedTab == tab ? .primary : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(vm.selectedTab == tab ? Color.primary.opacity(0.08) : .clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Divider()

            switch vm.selectedTab {
            case .overview: overviewTab(printer)
            case .jobs:     jobsTab(printer)
            case .logs:     logsTab
            }
        }
    }

    // MARK: - Header

    private func printerHeader(_ printer: CUPSPrinterInfo) -> some View {
        let printerActiveJobs = vm.activeJobsForPrinter(printer.id)
        return HStack(spacing: 12) {
            Image(systemName: printer.isQTR ? "printer.dotmatrix.fill" : "printer.fill")
                .font(.system(size: 24))
                .foregroundStyle(stateColor(printer.state))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(printer.name)
                        .font(.system(size: 14, weight: .semibold))
                    if printer.isQTR {
                        Text("QTR")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.2))
                            .foregroundStyle(.purple)
                            .clipShape(Capsule())
                    }
                    statusBadge(printer.state)
                }
                Text(printer.makeModel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(printer.deviceURI)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer()

            if !printerActiveJobs.isEmpty {
                Text("\(printerActiveJobs.count) active")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Overview Tab

    private func overviewTab(_ printer: CUPSPrinterInfo) -> some View {
        let printerActiveJobs = vm.activeJobsForPrinter(printer.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !printerActiveJobs.isEmpty {
                    sectionHeader("Active Jobs")
                    ForEach(printerActiveJobs) { job in
                        activeJobCard(job)
                    }
                }

                if !printer.inkLevels.isEmpty {
                    sectionHeader("Ink Levels")
                    inkLevelsView(printer.inkLevels)
                }

                if !printer.ppdOptions.isEmpty {
                    sectionHeader("Configuration")
                    configDashboard(printer.ppdOptions)
                }

                if !printer.availableCurves.isEmpty {
                    sectionHeader("Available Curves (\(printer.availableCurves.count))")
                    curvesPreview(printer.availableCurves)
                }

                if let ppdPath = printer.ppdPath {
                    sectionHeader("PPD File")
                    Text(ppdPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(16)
        }
    }

    // MARK: - Active Job Card

    private func activeJobCard(_ job: CUPSJobInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    if let curve = job.curveName {
                        HStack(spacing: 4) {
                            Image(systemName: "waveform.path.ecg")
                                .font(.system(size: 9))
                            Text(curve)
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(.purple)
                    }
                }
                Spacer()
                Text(job.state.rawValue.capitalized)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(jobStateColor(job.state))
            }

            if job.progressPercent > 0 || job.state == .processing {
                ProgressView(value: Double(job.progressPercent), total: 100)
                    .tint(.accentColor)
                HStack {
                    Text("\(job.progressPercent)%")
                        .font(.system(size: 9, design: .rounded))
                    if job.totalPages > 0 {
                        Text("Page \(job.pagesCompleted)/\(job.totalPages)")
                            .font(.system(size: 9))
                    }
                    Spacer()
                    if !job.stateMessage.isEmpty {
                        Text(job.stateMessage)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: 8) {
                if let model = job.colorModel { detailChip("Mode", model) }
                if let res = job.resolution { detailChip("DPI", res) }
                if let limit = job.inkLimit { detailChip("Limit", "\(limit)%") }
                if let dither = job.ditherAlgorithm { detailChip("Dither", dither) }
                if let feed = job.feedMode { detailChip("Feed", feed) }
                if let black = job.blackInk { detailChip("Black", black) }
                if !job.mediaSize.isEmpty { detailChip("Media", job.mediaSize) }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    // MARK: - Ink Levels

    private func inkLevelsView(_ levels: [CUPSPrinterInfo.InkLevel]) -> some View {
        VStack(spacing: 6) {
            ForEach(levels) { ink in
                HStack(spacing: 8) {
                    Text(ink.name)
                        .font(.system(size: 10))
                        .frame(width: 120, alignment: .trailing)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(nsColor: .quaternarySystemFill))
                            if ink.level >= 0 {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(inkColor(ink.color))
                                    .frame(width: max(0, geo.size.width * CGFloat(ink.level) / 100.0))
                            }
                        }
                    }
                    .frame(height: 10)

                    Text(ink.level >= 0 ? "\(ink.level)%" : "N/A")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - Configuration Dashboard

    private static let friendlyOptionNames: [String: (label: String, icon: String)] = [
        "PageSize":    ("Page Size",   "doc"),
        "MediaType":   ("Media",       "doc.richtext"),
        "Resolution":  ("Resolution",  "square.resize"),
        "ColorModel":  ("Color Mode",  "paintpalette"),
        "ripCurve1":   ("Curve 1",     "waveform.path.ecg"),
        "ripCurve2":   ("Curve 2",     "waveform.path.ecg"),
        "ripCurve3":   ("Curve 3",     "waveform.path.ecg"),
        "ripBlack":    ("Black Ink",   "drop.fill"),
        "ripFeed":     ("Paper Feed",  "arrow.up.doc"),
        "ripSpeed":    ("Feed Speed",  "gauge.with.needle"),
        "stpDither":   ("Dither",      "square.grid.3x3"),
    ]

    private func configDashboard(_ options: [CUPSPrinterInfo.PPDOption]) -> some View {
        let columns = [
            GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 8)
        ]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(options) { opt in
                configCard(opt)
            }
        }
    }

    private func configCard(_ opt: CUPSPrinterInfo.PPDOption) -> some View {
        let friendly = Self.friendlyOptionNames[opt.keyword]
        let label = friendly?.label ?? opt.text
        let icon = friendly?.icon ?? "gearshape"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(friendlyChoiceLabel(opt))
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            if opt.choices.count > 1 {
                Text("\(opt.choices.count) options")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    /// Show the friendly label for the default choice if one exists, otherwise the raw value.
    private func friendlyChoiceLabel(_ opt: CUPSPrinterInfo.PPDOption) -> String {
        if let match = opt.choices.first(where: { $0.0 == opt.defaultChoice }) {
            return match.1
        }
        return opt.defaultChoice
    }

    // MARK: - Curves Preview

    private let curvePreviewLimit = 3

    @State private var showAllCurves = false

    private func curvesPreview(_ curves: [String]) -> some View {
        let visible = showAllCurves ? curves : Array(curves.prefix(curvePreviewLimit))
        let remaining = curves.count - curvePreviewLimit
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visible.enumerated()), id: \.offset) { index, curve in
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 9))
                        .foregroundStyle(.purple)
                    Text(curve)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(index.isMultiple(of: 2) ? Color.clear : Color(nsColor: .quaternarySystemFill).opacity(0.5))
            }
            if !showAllCurves && remaining > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showAllCurves = true }
                } label: {
                    Text("+\(remaining) more")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            } else if showAllCurves && curves.count > curvePreviewLimit {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showAllCurves = false }
                } label: {
                    Text("Show less")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    // MARK: - Jobs Tab

    private func jobsTab(_ printer: CUPSPrinterInfo) -> some View {
        let printerJobs = vm.completedJobs.filter { $0.printerName == printer.id }
        return Group {
            if printerJobs.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No completed jobs")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        jobTableHeader

                        ForEach(printerJobs) { job in
                            jobRow(job)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
    }

    private var jobTableHeader: some View {
        HStack(spacing: 0) {
            Text("ID").frame(width: 44, alignment: .leading)
            Text("Title").frame(minWidth: 100, alignment: .leading)
            Text("Curve").frame(minWidth: 100, alignment: .leading)
            Text("Mode").frame(width: 60, alignment: .leading)
            Text("DPI").frame(width: 50, alignment: .leading)
            Text("Status").frame(width: 70, alignment: .leading)
            Text("Date").frame(width: 130, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func jobRow(_ job: CUPSJobInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("#\(job.id)")
                    .frame(width: 44, alignment: .leading)

                Text(job.title)
                    .lineLimit(1)
                    .frame(minWidth: 100, alignment: .leading)

                Text(job.curveName ?? "-")
                    .lineLimit(1)
                    .foregroundStyle(job.curveName != nil ? Color.purple : Color.secondary.opacity(0.5))
                    .frame(minWidth: 100, alignment: .leading)
                    .help(job.curveName ?? "")

                Text(job.colorModel ?? "-")
                    .frame(width: 60, alignment: .leading)

                Text(job.resolution ?? "-")
                    .frame(width: 50, alignment: .leading)

                Text(job.state.rawValue.capitalized)
                    .foregroundStyle(jobStateColor(job.state))
                    .frame(width: 70, alignment: .leading)

                Text(job.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .frame(width: 130, alignment: .trailing)
            }
            .font(.system(size: 10))

            // QTR detail chips for jobs that have extended attributes
            if job.inkLimit != nil || job.ditherAlgorithm != nil || job.feedMode != nil || job.blackInk != nil {
                HStack(spacing: 6) {
                    Spacer().frame(width: 44) // align under title
                    if let limit = job.inkLimit { detailChip("Limit", "\(limit)%") }
                    if let dither = job.ditherAlgorithm { detailChip("Dither", dither) }
                    if let feed = job.feedMode { detailChip("Feed", feed) }
                    if let black = job.blackInk { detailChip("Black", black) }
                    Spacer()
                }
                .padding(.top, 3)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
    }

    // MARK: - Logs Tab

    private var logsTab: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { vm.loadLogs() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            if vm.logs.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "doc.text")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No logs available")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("CUPS logs at /var/log/cups/ may require elevated permissions")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(vm.logs)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "printer.dotmatrix.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Select a printer")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func detailChip(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .foregroundStyle(.tertiary)
            Text(value)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 9))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color(nsColor: .quaternarySystemFill), in: Capsule())
    }

    private func statusBadge(_ state: CUPSPrinterInfo.PrinterState) -> some View {
        Text(state.rawValue.capitalized)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(stateColor(state).opacity(0.15))
            .foregroundStyle(stateColor(state))
            .clipShape(Capsule())
    }

    private func stateColor(_ state: CUPSPrinterInfo.PrinterState) -> Color {
        switch state {
        case .idle:       return .green
        case .processing: return .orange
        case .stopped:    return .red
        case .unknown:    return .gray
        }
    }

    private func jobStateColor(_ state: CUPSJobInfo.JobState) -> Color {
        switch state {
        case .completed:  return .green
        case .processing: return .orange
        case .canceled:   return .gray
        case .aborted:    return .red
        case .pending:    return .blue
        case .held:       return .yellow
        case .stopped:    return .red
        case .unknown:    return .gray
        }
    }

    private func inkColor(_ hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6,
              let val = UInt64(cleaned, radix: 16) else { return .gray }
        return Color(
            red: Double((val >> 16) & 0xFF) / 255.0,
            green: Double((val >> 8) & 0xFF) / 255.0,
            blue: Double(val & 0xFF) / 255.0
        )
    }
}
