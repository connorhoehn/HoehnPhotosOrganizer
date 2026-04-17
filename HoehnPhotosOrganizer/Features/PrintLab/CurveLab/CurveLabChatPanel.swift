import SwiftUI

// MARK: - CurveLabChatPanel

/// Right-side chat panel for Curve Lab pages.
/// Supports conversational commands like "split tone medium to warm",
/// "show me what a cyanotype looks like", "set curve 1 to warm", etc.
struct CurveLabChatPanel: View {

    @ObservedObject var viewModel: CurveLabViewModel
    @Binding var isCollapsed: Bool
    @FocusState private var inputFocused: Bool
    @State private var isHovering: Bool = false
    @State private var panelWidth: CGFloat = 280
    @State private var isDraggingHandle: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            if !isCollapsed {
                // Drag handle
                dragHandle
            }
            Group {
                if isCollapsed {
                    collapsedBar
                } else {
                    expandedPanel
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isCollapsed)
    }

    // MARK: - Drag Handle

    private var dragHandle: some View {
        Rectangle()
            .fill(isDraggingHandle ? Color.accentColor.opacity(0.3) : Color.clear)
            .frame(width: 5)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        isDraggingHandle = true
                        let newWidth = panelWidth - value.translation.width
                        panelWidth = max(220, min(500, newWidth))
                    }
                    .onEnded { _ in
                        isDraggingHandle = false
                    }
            )
    }

    // MARK: - Collapsed Bar

    private var collapsedBar: some View {
        Button {
            isCollapsed = false
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 8))
                    .foregroundStyle(isHovering ? .primary : .tertiary)
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 12))
                    .foregroundStyle(isHovering ? Color.accentColor : Color.secondary)
                Text("Assistant")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isHovering ? .primary : .tertiary)
                    .rotationEffect(.degrees(-90))
                    .fixedSize()
            }
            .frame(width: 36)
            .frame(maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor).opacity(isHovering ? 1.0 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    // MARK: - Expanded Panel

    private var expandedPanel: some View {
        VStack(spacing: 0) {
            // Header — click title to collapse
            HStack {
                Button {
                    isCollapsed = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 12))
                        Text("Assistant")
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8))
                            .foregroundColor(isHovering ? .secondary : .clear)
                    }
                }
                .buttonStyle(.plain)
                .help("Collapse assistant")
                Spacer()
                if !viewModel.chatMessages.isEmpty {
                    Button {
                        viewModel.chatMessages.removeAll()
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear chat")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .onHover { hovering in
                isHovering = hovering
            }

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if viewModel.chatMessages.isEmpty {
                            chatEmptyState
                        }

                        ForEach(viewModel.chatMessages) { msg in
                            chatBubble(msg).id(msg.id)
                        }

                        if viewModel.chatLoading {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("Thinking...")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .id("loading")
                        }
                    }
                    .padding(12)
                }
                .onChange(of: viewModel.chatMessages.count) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation {
                            if let lastId = viewModel.chatMessages.last?.id {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            Divider()

            // Input
            VStack(spacing: 8) {
                TextEditor(text: $viewModel.chatInput)
                    .font(.system(size: 13))
                    .focused($inputFocused)
                    .frame(minHeight: 44, maxHeight: 80)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .overlay(alignment: .topLeading) {
                        if viewModel.chatInput.isEmpty {
                            Text(placeholderText)
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 12)
                                .padding(.top, 12)
                                .allowsHitTesting(false)
                        }
                    }
                    .onKeyPress(.return) {
                        if NSEvent.modifierFlags.contains(.shift) {
                            return .ignored
                        } else {
                            sendMessage()
                            return .handled
                        }
                    }

                HStack {
                    Text("Enter to send")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                    Spacer()
                    Button { sendMessage() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up")
                            Text("Send")
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(viewModel.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(10)
        }
        .frame(width: panelWidth)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Empty State

    private var chatEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)

            Text("Curve Lab Assistant")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                suggestionRow("\"split tone medium to warm\"")
                suggestionRow("\"show cyanotype preview\"")
                suggestionRow("\"set curve 1 to Hahn Plat Warm\"")
                suggestionRow("\"compare warm vs cool on highlights\"")
                suggestionRow("\"what drop count for pt/pd?\"")
                suggestionRow("\"build positive curve for salt print\"")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func suggestionRow(_ text: String) -> some View {
        Button {
            viewModel.chatInput = text.replacingOccurrences(of: "\"", with: "")
            sendMessage()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Chat Bubble

    private func chatBubble(_ msg: CurveLabChatMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if msg.role == .assistant || msg.role == .system {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 24, height: 24)
                    .overlay(
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                    )
            }

            VStack(alignment: msg.role == .user ? .trailing : .leading, spacing: 4) {
                Text(msg.text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(msg.role == .user
                                  ? Color.accentColor.opacity(0.15)
                                  : Color.primary.opacity(0.06))
                    )

                Text(msg.timestamp, style: .time)
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
            }
            .frame(maxWidth: .infinity, alignment: msg.role == .user ? .trailing : .leading)

            if msg.role == .user {
                Circle()
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 24, height: 24)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    )
            }
        }
    }

    // MARK: - Helpers

    private var placeholderText: String {
        switch viewModel.currentPage {
        case .curveBuilder:
            switch viewModel.curvesSubPage {
            case .gallery:    return "Search curves, ask about processes..."
            case .creator:    return "Describe curve adjustments..."
            case .linearize:  return "Ask about linearization workflow..."
            case .blend:      return "Describe blend strategy..."
            case .remap:      return "Ask about channel remapping..."
            }
        case .processes:
            return "Ask about processes, drop counts..."
        case .printLayout:
            return "Ask about print layout, paper sizes..."
        case .printers:
            return "Ask about printers, ink, job status..."
        }
    }

    private func sendMessage() {
        let text = viewModel.chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        viewModel.chatInput = ""

        viewModel.chatMessages.append(
            CurveLabChatMessage(role: .user, text: text)
        )

        viewModel.chatLoading = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            viewModel.chatLoading = false
            let response = generateContextualResponse(
                for: text,
                process: viewModel.selectedProcess
            )
            viewModel.chatMessages.append(
                CurveLabChatMessage(role: .assistant, text: response)
            )
        }
    }

    private func generateContextualResponse(for message: String, process: PrintProcess?) -> String {
        let msg = message.lowercased()

        // Linearization / step wedge workflow
        if msg.contains("lineariz") || msg.contains("step wedge") || msg.contains("patch") {
            return "For linearization: scan your step wedge at 21 patches (0–100% in 5% steps). Read each patch's L* value, then generate a curve that maps input ink to output density linearly. Your target is L*=100 at 0% ink and L*=0 at 100% ink."
        }

        // Platinum / palladium
        if msg.contains("platinum") || msg.contains("palladium") || msg.contains("pt/pd") {
            return "Platinum/palladium prints typically need a long-scale curve (DR ~1.8). Start with a gentle S-curve: pull shadows up slightly and hold highlights back. The paper base fog will affect your shadow L* readings — subtract it from all measurements.\n\nTypical sensitizer mix (8×10): ferric oxalate 18 drops, Pt solution 12 drops, Pd solution 6 drops. More Pd = warmer tone. Na2 developer gives neutral-warm; potassium oxalate gives cooler."
        }

        // Cyanotype
        if msg.contains("cyanotype") || msg.contains("cyan") {
            return "Cyanotype has a distinctive blue tone and DR of about 1.5. Two-part sensitizer: ferric ammonium citrate + potassium ferricyanide, mixed 1:1 (16–20 drops each per 8×10).\n\nThe curve should be relatively straight in midtones. Develop in running water 5–10 min; a dilute H₂O₂ bath speeds oxidation to final Prussian blue. UV exposure 4–12 min — cyanotype is sensitive to UV index variation."
        }

        // Salt print
        if msg.contains("salt") {
            return "Salt printing: soak paper in NaCl solution (12–20%), dry fully, then coat with 12% silver nitrate (20–24 drops per 8×10). Digital negative should target Dmax ~1.4–1.6.\n\nExpose under UV until highlights just start to bronze. Fix in sodium thiosulfate, wash 30 min. Gold chloride toning shifts color from reddish-brown toward purple-brown and adds permanence."
        }

        // Van Dyke Brown
        if msg.contains("van dyke") || msg.contains("vandyke") {
            return "Van Dyke Brown: three-part sensitizer — ferric ammonium citrate, tartaric acid, silver nitrate (20–22 drops total per 8×10). Coat, dry, expose under UV. The image self-masks in the shadows, which limits Dmax. Fix in dilute sodium thiosulfate, wash 30 min. Gold toning strongly recommended for permanence."
        }

        // Gum bichromate
        if msg.contains("gum") || msg.contains("bichromate") || msg.contains("dichromate") {
            return "Gum bichromate: mix gum arabic + watercolor pigment + ammonium or potassium dichromate. Coat on sized paper, dry, expose under UV — dichromate hardens gum proportional to light. Develop by differential washing in water.\n\nFor full tonal range, build 3–4 layers, each with its own registration. Each layer uses a lighter pigment dilution."
        }

        // QTR export
        if msg.contains("export") || msg.contains("qtr") || msg.contains("quadtone") || msg.contains("qtrip") {
            return "To export for QTRip: use the Export .txt button which generates a 256-value linearization file. Place it in ~/Library/Printers/QTR/quadtone/[YourPrinter]/ and rebuild the QuadTone RIP profiles.\n\nFor digital negatives, the curve file goes in the neg/ subfolder. QTR auto-inverts the curve for neg output — your .quad file stays positive."
        }

        // Split tone
        if msg.contains("split") || (msg.contains("tone") && !msg.contains("ink tone")) {
            return "Split toning in QTR: use separate curves per ink channel. Warm shadows: add a touch of yellow/orange inks in the shadow region of the shadow curve. Cool highlights: add cyan inks in the highlight region of the highlight curve.\n\nThe split-tone sliders here set highlight/midtone/shadow blend percentages between Curve 1 (warm) and Curve 2 (cool). A classic print look: 60–70% warm in highlights, 60–70% cool in shadows."
        }

        // Warm / cool comparison
        if msg.contains("warm") || msg.contains("cool") {
            return "I can help set up a warm/cool ink comparison. Curve 1 = warm ink (e.g., Hahn Warm Black), Curve 2 = cool ink (e.g., Photo Black). Use the split-tone sliders to blend: push highlights warm and shadows cool for a classic toned look, or reverse it for a cool-shadows / warm-highlights split."
        }

        // Drop counts
        if msg.contains("drop count") || msg.contains("drops") || msg.contains("sensitizer") {
            let processContext = process.map { " for \($0.rawValue)" } ?? ""
            if let process {
                return "Typical coating\(processContext): \(process.typicalDropCounts).\n\nAdjust up or down based on paper porosity — more porous papers absorb more sensitizer and need higher drop counts to maintain Dmax."
            }
            return "Drop counts vary by process — select a process from the left panel and I can give you specific guidance."
        }

        // Curve building general
        if msg.contains("curve") || msg.contains("build") {
            return "Curve building workflow:\n1. Print a 21-step linear target at 0% ink to 100% ink.\n2. Dry, then measure with SpyderPRINT or i1Pro — this gives L* values per step.\n3. Import the measurement into the Curve Gallery → Measurements tab.\n4. The anomaly detector highlights reversals (non-monotonic steps) that need smoothing.\n5. Apply smoothing window, then export as a .quad starting curve.\n6. Iterate: print with the new curve, measure again, and check linearity."
        }

        // Specific process context fallback
        if let process, process != .inkjetBW && process != .inkjetColor {
            return "For \(process.rawValue): \(processSpecificTip(process))\n\nAsk me about linearization, drop counts, curve shape, or export format."
        }

        // Generic fallback
        return "I can help with curve building, print process guidance, linearization, split toning, and QTR export. What specifically are you working on?"
    }

    private func processSpecificTip(_ process: PrintProcess) -> String {
        switch process {
        case .platinumPd:
            return "Start with a long-scale positive curve targeting DR ~1.8. The highlights compress easily — use a slight hold-back in the top 10% of the curve."
        case .cyanotype:
            return "Relatively straight curve in midtones. Build your positive on the Curve Builder, then QTR will invert it for the digital negative output."
        case .saltPrint:
            return "Target Dmax ~1.4–1.6 on your digital negative. Salt prints print-out in sunlight — no development, just fixing. Highlights bronze first."
        case .vanDykeBrown:
            return "Limited Dmax due to self-masking. Use a slightly compressed shadow curve; don't push full density or you'll get surface bronzing."
        case .gumBichromate:
            return "Each layer gets its own curve. First layer: full-range. Subsequent layers: progressively limit the shadow density to avoid clogging."
        case .carbonTransfer:
            return "Long-scale process, DR ~2.0+. The curve should be nearly linear — the process itself handles contrast. Main variables are dichromate concentration and water temperature."
        case .silverGelatin:
            return "Analog process — not typically QTR-driven. Use reference here to compare tonal scale with your digital prints."
        case .digitalNeg:
            return "Build the positive curve to match your target alt-process Dmax. QTR inverts for the neg. UV density target: 1.4–1.6 (cyanotype) or 1.6–2.0 (Pt/Pd)."
        case .directToPlate:
            return "Direct to plate (photopolymer/gravure): exposure-based process. Curve controls ink density on the negative which maps to etch depth or exposure hardness. KM73 PrintTight and Green Mountain (Dantax) are common plates."
        case .chrysotype:
            return "Chrysotype: gold-based variant of cyanotype producing warm purple-brown tones. Similar workflow to cyanotype but with gold chloride sensitizer. DR ~1.4–1.6."
        default:
            return "Select a more specific alt-process for detailed guidance."
        }
    }
}
