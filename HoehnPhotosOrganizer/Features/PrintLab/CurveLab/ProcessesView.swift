import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - ProcessesView

/// Explore print processes — alt-process recipes, drop counts,
/// curve requirements, and simulated previews.
struct ProcessesView: View {

    @ObservedObject var viewModel: CurveLabViewModel

    // MARK: - Drop Target State
    @State private var previewImage: NSImage? = nil
    @State private var isDropTargeted: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            // Main content
            HStack(spacing: 0) {
                // Left: process list
                processList
                    .frame(width: 220)

                Divider()

                // Center: process detail
                processDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Process List

    private var processList: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("PROCESSES")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(PrintProcess.allCases) { process in
                        processRow(process)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func processRow(_ process: PrintProcess) -> some View {
        let isSelected = viewModel.selectedProcess == process
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                viewModel.selectedProcess = process
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: process.icon)
                    .font(.system(size: 12))
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? .white : .secondary)

                Text(process.rawValue)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? .white : .primary)

                Spacer()

                // Curve count badge
                let count = viewModel.quadFiles.filter({ $0.inferredProcess == process }).count
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(isSelected ? Color.white.opacity(0.7) : Color.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.white.opacity(0.2) : Color.primary.opacity(0.06))
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : Color.clear)
            )
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Process Detail

    private var processDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 14) {
                    Image(systemName: viewModel.selectedProcess.icon)
                        .font(.system(size: 28))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 44, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.accentColor.opacity(0.1))
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.selectedProcess.rawValue)
                            .font(.system(size: 18, weight: .semibold))
                        Text(processSubtitle(viewModel.selectedProcess))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Curve type
                processSection("Curve Type") {
                    HStack(spacing: 8) {
                        Image(systemName: viewModel.selectedProcess.usesPositiveCurve
                              ? "plus.circle.fill" : "minus.circle.fill")
                            .foregroundStyle(viewModel.selectedProcess.usesPositiveCurve ? .green : .orange)
                        Text(viewModel.selectedProcess.usesPositiveCurve
                             ? "Positive Curve — direct ink output"
                             : "Negative — printed through digital negative")
                            .font(.system(size: 12))
                    }
                }

                // Drop counts
                if viewModel.selectedProcess.typicalDropCounts != "N/A" {
                    processSection("Drop Counts / Sensitizer") {
                        Text(viewModel.selectedProcess.typicalDropCounts)
                            .font(.system(size: 12))
                    }
                }

                // Process-specific info
                processSection("Process Notes") {
                    Text(processDescription(viewModel.selectedProcess))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                // Available curves for this process
                let processQuads = viewModel.quadFiles.filter({ $0.inferredProcess == viewModel.selectedProcess })
                if !processQuads.isEmpty {
                    processSection("Available Curves (\(processQuads.count))") {
                        VStack(spacing: 6) {
                            ForEach(processQuads) { quad in
                                HStack(spacing: 8) {
                                    Image(systemName: "waveform.path")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 10)
                                    Text(quad.fileName)
                                        .font(.system(size: 12))
                                    Spacer()
                                    Text("\(quad.activeChannels.count) ch")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.primary.opacity(0.03))
                                )
                            }
                        }
                    }
                }

                // Preview — image drop target with process toning overlay
                processSection("Preview") {
                    VStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(processPreviewColor(viewModel.selectedProcess).opacity(0.15))
                                .frame(height: 200)

                            if let img = previewImage {
                                Image(nsImage: img)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 200)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(processColorOverlay)
                                            .blendMode(.multiply)
                                    )
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: "photo.badge.arrow.down")
                                        .font(.system(size: 32))
                                        .foregroundStyle(isDropTargeted
                                            ? processPreviewColor(viewModel.selectedProcess)
                                            : Color.secondary.opacity(0.4))
                                    Text("Drop a test target image to preview process toning")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 16)
                                }
                            }
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    isDropTargeted
                                        ? processPreviewColor(viewModel.selectedProcess)
                                        : processPreviewColor(viewModel.selectedProcess).opacity(0.3),
                                    style: StrokeStyle(lineWidth: isDropTargeted ? 2.5 : 2, dash: [6, 4])
                                )
                        )
                        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
                            handleImageDrop(providers: providers)
                        }
                        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)

                        HStack {
                            Text("Simulated toning preview — drop a grayscale test target image above.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Spacer()
                            if previewImage != nil {
                                Button("Clear") {
                                    previewImage = nil
                                }
                                .font(.caption2)
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Spacer(minLength: 40)
            }
            .padding(24)
        }
    }

    // MARK: - Helpers

    private func processSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func processSubtitle(_ process: PrintProcess) -> String {
        switch process {
        case .inkjetBW:       return "Direct inkjet black & white print"
        case .inkjetColor:    return "Direct inkjet color print"
        case .digitalNeg:     return "Inkjet-printed transparency for contact printing"
        case .platinumPd:     return "Iron-based noble metal print — archival, matte"
        case .cyanotype:      return "Iron-based blueprint — UV exposed, water developed"
        case .silverGelatin:  return "Traditional darkroom enlargement"
        case .saltPrint:      return "Silver nitrate on salted paper — earliest photo process"
        case .vanDykeBrown:   return "Iron-silver process — warm brown tones"
        case .gumBichromate:  return "Dichromate-hardened gum arabic with pigment"
        case .carbonTransfer: return "Gelatin tissue transfer — continuous tone, archival"
        case .directToPlate:  return "Photopolymer plate / gravure — UV exposed, etched or inked"
        case .chrysotype:     return "Gold-based variant of cyanotype — warm purple-brown tones"
        }
    }

    private func processDescription(_ process: PrintProcess) -> String {
        switch process {
        case .platinumPd:
            return "Platinum/palladium prints use ferric oxalate as a sensitizer with platinum and/or palladium salts. The ratio of Pt to Pd controls warmth — more palladium yields warmer browns, pure platinum gives neutral gray-black. Typical coating: 18–24 drops total sensitizer for 8×10. Developer: potassium oxalate or sodium citrate (Na2). Digital negatives should target Dmax 1.6–2.0 depending on paper."
        case .cyanotype:
            return "Two-part sensitizer: ferric ammonium citrate (FAC) + potassium ferricyanide, mixed 1:1. Coat in dim light, dry fully before exposure. UV exposure 4–12 minutes depending on light source. Develop in running water 5–10 min. Dilute hydrogen peroxide bath speeds oxidation to final blue. Curve should compensate for non-linear response — shadows compress easily."
        case .saltPrint:
            return "Paper is soaked in salt solution (NaCl, 12–20% concentration), dried, then coated with silver nitrate (12% solution, 20–24 drops per 8×10). Expose under UV through digital negative. Fix in sodium thiosulfate, wash 30 min. Toning with gold chloride adds permanence and shifts color from reddish-brown to purple-brown."
        case .vanDykeBrown:
            return "Three-part sensitizer: ferric ammonium citrate, tartaric acid, and silver nitrate. Coat, dry, expose under UV. The image self-masks in the shadows, limiting Dmax. Fix in sodium thiosulfate (dilute). Wash 30 min. Gold toning recommended for permanence."
        case .gumBichromate:
            return "Mix gum arabic + watercolor pigment + ammonium or potassium dichromate. Coat on sized paper, dry. Expose under UV — dichromate hardens gum proportional to light. Develop in water (differential washing). Multiple layers for full tonal range. Each layer needs a separate negative/curve registration."
        case .carbonTransfer:
            return "Sensitize pre-made gelatin tissue with dichromate, expose under UV, transfer to final support paper. Yields continuous-tone prints with excellent Dmax and archival permanence. Complex process but produces museum-quality results."
        case .silverGelatin:
            return "Traditional darkroom: expose silver gelatin paper under an enlarger with a negative. Not typically driven by QTR curves — uses analog exposure/development controls. Include here for reference and comparison."
        case .digitalNeg:
            return "Print a negative on transparency film (Pictorico Ultra Premium OHP recommended) using QTR curves calibrated for UV density. The curve compensates for the non-linear UV transmission of the ink/film combination. Target Dmax depends on the alt process: 1.4–1.6 for cyanotype, 1.6–2.0 for Pt/Pd."
        case .inkjetBW:
            return "Direct B&W inkjet using QTR to control individual ink channels. Curves linearize the printer's response for smooth tonal gradation. Multiple ink tones (warm, neutral, cool) can be blended using split-tone controls."
        case .inkjetColor:
            return "Standard ICC-profiled color inkjet output. Curves are typically handled by the ICC profile rather than QTR."
        case .directToPlate:
            return "Direct-to-plate (DTP) uses a digital negative to expose a photopolymer or photogravure plate. The plate is then etched or inked and run through a press. Curves must compensate for dot gain on the plate and the non-linear UV transmission of the negative. Common substrates: Toyota KM73/PrintTight plates, copper plates for gravure."
        case .chrysotype:
            return "A gold-based printing process using gold chloride as the light-sensitive metal instead of iron salts alone. Related to cyanotype but produces warm purple-brown tones instead of blue. Coat with gold chloride + ferric ammonium citrate, expose under UV, develop in water. More expensive than cyanotype but yields unique tonal qualities."
        }
    }

    // MARK: - Drop Handler

    @discardableResult
    private func handleImageDrop(providers: [NSItemProvider]) -> Bool {
        // Try to load a file URL first (most reliable for images dropped from Finder)
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier("public.file-url") }) {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                } else {
                    url = nil
                }
                if let url, let img = NSImage(contentsOf: url) {
                    DispatchQueue.main.async { previewImage = img }
                }
            }
            return true
        }
        // Fall back to loading an NSImage directly from an image provider
        if let provider = providers.first(where: { $0.canLoadObject(ofClass: NSImage.self) }) {
            _ = provider.loadObject(ofClass: NSImage.self) { img, _ in
                if let img = img as? NSImage {
                    DispatchQueue.main.async { previewImage = img }
                }
            }
            return true
        }
        return false
    }

    // MARK: - Toning Overlay

    /// Semi-transparent color overlay that simulates the characteristic toning of the selected process.
    private var processColorOverlay: Color {
        switch viewModel.selectedProcess {
        case .platinumPd:
            // Warm brown — palladium-rich neutral
            return Color(red: 0.7, green: 0.55, blue: 0.4).opacity(0.3)
        case .cyanotype:
            // Iron blue
            return Color(red: 0.2, green: 0.4, blue: 0.8).opacity(0.3)
        case .saltPrint:
            // Warm yellowish-brown — early silver processes
            return Color(red: 0.75, green: 0.6, blue: 0.4).opacity(0.3)
        case .vanDykeBrown:
            // Deep warm brown
            return Color(red: 0.55, green: 0.35, blue: 0.2).opacity(0.3)
        case .gumBichromate:
            // Warm olive — pigment-dependent, default to a mid-tone warm
            return Color(red: 0.6, green: 0.55, blue: 0.3).opacity(0.3)
        case .silverGelatin:
            // Neutral — slight cool shift typical of FB paper
            return Color(red: 0.88, green: 0.9, blue: 0.95).opacity(0.2)
        case .carbonTransfer:
            // Warm neutral — carbon tissue typically prints warm black
            return Color(red: 0.65, green: 0.55, blue: 0.45).opacity(0.25)
        case .chrysotype:
            // Gold tones — chrysotype prints with a warm gold hue
            return Color(red: 0.8, green: 0.65, blue: 0.3).opacity(0.3)
        case .directToPlate:
            // Neutral — photopolymer plates have no inherent toning
            return Color.clear
        case .digitalNeg, .inkjetBW, .inkjetColor:
            // No toning overlay for direct digital output
            return Color.clear
        }
    }

    private func processPreviewColor(_ process: PrintProcess) -> Color {
        switch process {
        case .cyanotype:      return .blue
        case .platinumPd:     return .gray
        case .saltPrint:      return .brown
        case .vanDykeBrown:   return .brown
        case .gumBichromate:  return .purple
        case .carbonTransfer: return .gray
        default:              return .secondary
        }
    }
}
