import SwiftUI

// MARK: - CurveCreatorWizard

/// Step-by-step wizard for creating a new curve.
/// Collects: Printer Config → Ink Set → Process, then opens the editor.
struct CurveCreatorWizard: View {

    @ObservedObject var viewModel: CurveLabViewModel
    @State private var step = 0
    @State private var selectedPrinterFamily: String?
    @State private var selectedProfile: CurveProfileFolder?
    @State private var selectedInkSet: InkSet = .piezography
    @State private var selectedProcess: PrintProcess = .platinumPd
    @State private var curveName: String = ""
    @State private var isEditingName = false
    @State private var printerSearch: String = ""

    private let totalSteps = 5

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                // Header
                VStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.accentColor)
                    Text("New Curve")
                        .font(.system(size: 18, weight: .bold))
                    Text(stepSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                // Progress
                HStack(spacing: 4) {
                    ForEach(0..<totalSteps, id: \.self) { i in
                        Capsule()
                            .fill(i <= step ? Color.accentColor : Color.primary.opacity(0.1))
                            .frame(height: 3)
                    }
                }
                .padding(.horizontal, 40)

                // Step content
                Group {
                    switch step {
                    case 0: printerModelStep
                    case 1: printerConfigStep
                    case 2: inkSetStep
                    case 3: processStep
                    case 4: nameStep
                    default: EmptyView()
                    }
                }
                .frame(minHeight: 200)

                // Navigation
                HStack {
                    if step > 0 {
                        Button("Back") {
                            withAnimation { step -= 1 }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }

                    Spacer()

                    if step < totalSteps - 1 {
                        Button("Next") {
                            withAnimation { step += 1 }
                            // Auto-generate name when reaching the name step
                            if step == totalSteps - 1 && curveName.isEmpty {
                                curveName = generateCurveName()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(!canAdvance)
                    } else {
                        Button("Create Curve") {
                            viewModel.startNewEditSession(
                                profile: selectedProfile,
                                inkSet: selectedInkSet,
                                process: selectedProcess
                            )
                            if !curveName.isEmpty {
                                viewModel.editSession?.sourceFileName = curveName + ".quad"
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 460)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.2), radius: 20)
            )

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
        .onAppear {
            selectedProfile = viewModel.selectedProfile
            selectedInkSet = viewModel.selectedInkSet
            selectedProcess = viewModel.selectedProcess
        }
    }

    private var stepSubtitle: String {
        switch step {
        case 0: return "Select your printer model"
        case 1: return "Choose the printer configuration (PPD + curve set)"
        case 2: return "Choose the ink set installed in the printer"
        case 3: return "What print process will this curve serve?"
        case 4: return "Give your curve a name"
        default: return ""
        }
    }

    private var canAdvance: Bool {
        switch step {
        case 0: return selectedPrinterFamily != nil
        case 1: return selectedProfile != nil
        default: return true
        }
    }

    // MARK: - Steps

    /// Unique printer families, sorted by total curve count (most used first)
    private var printerFamilies: [(family: String, totalCurves: Int, configCount: Int)] {
        var grouped: [String: (curves: Int, configs: Int)] = [:]
        for profile in viewModel.availableProfiles {
            let family = profile.printerFamily
            let existing = grouped[family] ?? (0, 0)
            grouped[family] = (existing.curves + profile.curveCount, existing.configs + 1)
        }
        var result = grouped.map { (family: $0.key, totalCurves: $0.value.curves, configCount: $0.value.configs) }
        result.sort { $0.totalCurves > $1.totalCurves }
        if !printerSearch.isEmpty {
            result = result.filter { $0.family.localizedCaseInsensitiveContains(printerSearch) }
        }
        return result
    }

    /// Configs for the selected printer family, sorted by curve count
    private var configsForSelectedFamily: [CurveProfileFolder] {
        guard let family = selectedPrinterFamily else { return [] }
        return viewModel.availableProfiles
            .filter { $0.printerFamily == family }
            .sorted { $0.curveCount > $1.curveCount }
    }

    // Step 0: Pick printer model
    private var printerModelStep: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("Search printers...", text: $printerSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !printerSearch.isEmpty {
                    Button { printerSearch = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(printerFamilies, id: \.family) { entry in
                        Button {
                            selectedPrinterFamily = entry.family
                            // Auto-select first config if only one
                            let configs = viewModel.availableProfiles.filter { $0.printerFamily == entry.family }
                            if configs.count == 1 { selectedProfile = configs.first }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.family)
                                        .font(.system(size: 12, weight: .medium))
                                    HStack(spacing: 6) {
                                        Text("\(entry.configCount) config\(entry.configCount == 1 ? "" : "s")")
                                        Text("·")
                                        Text("\(entry.totalCurves) curves")
                                    }
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if selectedPrinterFamily == entry.family {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selectedPrinterFamily == entry.family ? Color.accentColor.opacity(0.1) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
    }

    // Step 1: Pick printer config (filtered to selected model)
    private var printerConfigStep: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(configsForSelectedFamily) { profile in
                    Button {
                        selectedProfile = profile
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.displayName)
                                    .font(.system(size: 12, weight: .medium))
                                HStack(spacing: 6) {
                                    Text(profile.inkSetLabel)
                                    Text("·")
                                    Text("\(profile.channelCount) channels")
                                    Text("·")
                                    Text("\(profile.curveCount) curves")
                                }
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            if selectedProfile?.id == profile.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selectedProfile?.id == profile.id ? Color.accentColor.opacity(0.1) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 240)
    }

    private var inkSetStep: some View {
        VStack(spacing: 2) {
            ForEach(InkSet.allCases) { ink in
                Button {
                    selectedInkSet = ink
                } label: {
                    HStack {
                        Image(systemName: ink.icon)
                            .frame(width: 20)
                        Text(ink.rawValue)
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("\(ink.channelCount) channels")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        if selectedInkSet == ink {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selectedInkSet == ink ? Color.accentColor.opacity(0.1) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var processStep: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(PrintProcess.allCases) { process in
                    Button {
                        selectedProcess = process
                    } label: {
                        HStack {
                            Image(systemName: process.icon)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(process.rawValue)
                                    .font(.system(size: 12, weight: .medium))
                                if !process.typicalDropCounts.hasPrefix("N/A") {
                                    Text(process.typicalDropCounts)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            if !process.usesPositiveCurve {
                                Text("Neg")
                                    .font(.system(size: 9, weight: .medium))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.orange.opacity(0.15), in: Capsule())
                                    .foregroundStyle(.orange)
                            }
                            if selectedProcess == process {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selectedProcess == process ? Color.accentColor.opacity(0.1) : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 240)
    }

    private var nameStep: some View {
        VStack(spacing: 16) {
            // Name display / edit
            if isEditingName {
                HStack(spacing: 8) {
                    TextField("Curve name", text: $curveName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                    Button {
                        isEditingName = false
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.green)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 8) {
                    Text(curveName.isEmpty ? "Untitled" : curveName)
                        .font(.system(size: 16, weight: .semibold))
                    Button {
                        isEditingName = true
                    } label: {
                        Image(systemName: "pencil.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Edit curve name")
                }
            }

            if let profile = selectedProfile {
                HStack(spacing: 8) {
                    Label(profile.printerFamily, systemImage: "printer")
                    Label(selectedInkSet.rawValue, systemImage: selectedInkSet.icon)
                    Label(selectedProcess.rawValue, systemImage: selectedProcess.icon)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            Text("The curve will be saved to: \(selectedProfile?.displayName ?? "—")/\(curveName.isEmpty ? "Untitled" : curveName).quad")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Auto-generate a curve name from the selected printer, ink set, and process.
    private func generateCurveName() -> String {
        let printer = selectedProfile?.displayName
            .replacingOccurrences(of: " ", with: "-") ?? "Printer"
        let process: String
        switch selectedProcess {
        case .platinumPd:    process = "PtPd"
        case .cyanotype:     process = "Cyano"
        case .silverGelatin: process = "Silver"
        case .saltPrint:     process = "Salt"
        case .vanDykeBrown:  process = "VDB"
        case .gumBichromate: process = "Gum"
        case .carbonTransfer: process = "Carbon"
        case .digitalNeg:    process = "DN"
        case .inkjetBW:      process = "BW"
        case .inkjetColor:   process = "Color"
        case .directToPlate: process = "DTP"
        case .chrysotype:    process = "Chryso"
        }
        let dateStr = {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd"
            return f.string(from: Date())
        }()
        return "\(printer)-\(process)-\(dateStr)"
    }
}
