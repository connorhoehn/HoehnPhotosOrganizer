import SwiftUI

// MARK: - CurveLabOnboardingView

/// Modal onboarding that explains the CurveLab multi-page layout with an annotated diagram.
struct CurveLabOnboardingView: View {

    @Environment(\.dismiss) private var dismiss
    @State private var currentStep = 0

    private let steps: [(title: String, description: String, icon: String, color: Color)] = [
        (
            "Page Navigation",
            "The top bar switches between Print Layout, Curves, Processes, and Printers. Each page has its own workspace, and the Chat assistant stays visible on the right across all pages.",
            "rectangle.split.3x1",
            .blue
        ),
        (
            "Gallery",
            "Browse your saved curves grouped by printer config. Open any curve to jump into the Creator for editing, or start a new one from scratch.",
            "square.grid.2x2",
            .green
        ),
        (
            "Creator",
            "Build and edit .quad curves. Load measurements from a scanned target or SpyderPRINT export, read patches, and adjust the curve graph with smoothing and gamma controls.",
            "plus.circle",
            .orange
        ),
        (
            "Linearize",
            "Flatten a curve using measurement data. Choose a linearization target (Lab L*, density, or ink), then refine with smoothing until the response is even across all tones.",
            "line.diagonal",
            .purple
        ),
        (
            "Blend & Remap",
            "Blend two curves with zone-based weights, or remap channel assignments. Export finished curves as QTR .txt files or install them directly into your printer's curve folder.",
            "arrow.triangle.merge",
            .teal
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Welcome to CurveLab")
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // Layout diagram
            layoutDiagram
                .padding(.horizontal, 24)
                .padding(.bottom, 16)

            Divider()

            // Step cards
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(step.color.opacity(currentStep == index ? 0.2 : 0.08))
                                .frame(width: 32, height: 32)
                            Image(systemName: step.icon)
                                .font(.system(size: 13))
                                .foregroundStyle(step.color)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(index + 1). \(step.title)")
                                .font(.system(size: 12, weight: .semibold))
                            Text(step.description)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .opacity(currentStep >= index ? 1 : 0.4)
                    .onTapGesture { withAnimation { currentStep = index } }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Spacer()

            // Footer
            HStack {
                Spacer()
                Button("Get Started") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(width: 540, height: 620)
        .onAppear {
            // Animate through steps
            for i in 1..<steps.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.4) {
                    withAnimation(.easeInOut(duration: 0.3)) { currentStep = i }
                }
            }
        }
    }

    // MARK: - Layout Diagram

    private var layoutDiagram: some View {
        VStack(spacing: 2) {
            // Top-level page nav
            HStack(spacing: 2) {
                diagramBlock("Print Layout", icon: "printer.fill", color: .blue)
                diagramBlock("Curves", icon: "waveform.path.ecg", color: .blue, highlight: true)
                diagramBlock("Processes", icon: "paintbrush.pointed", color: .blue)
                diagramBlock("Printers", icon: "printer.dotmatrix.fill", color: .blue)
            }
            .frame(height: 28)

            // Curves sub-page nav
            HStack(spacing: 2) {
                diagramBlock("Gallery", icon: "square.grid.2x2", color: .green)
                diagramBlock("Creator", icon: "plus.circle", color: .orange)
                diagramBlock("Linearize", icon: "line.diagonal", color: .purple)
                diagramBlock("Blend", icon: "arrow.triangle.merge", color: .teal)
                diagramBlock("Remap", icon: "arrow.triangle.swap", color: .teal)
            }
            .frame(height: 24)

            // Main content + chat
            HStack(spacing: 2) {
                diagramBlock("Active Sub-Page\n(content area)", icon: "rectangle.dashed", color: .secondary)
                    .frame(maxWidth: .infinity)

                diagramBlock("Chat\nAssistant", icon: "bubble.left", color: .pink)
                    .frame(width: 80)
            }
            .frame(height: 70)
        }
    }

    private func diagramBlock(_ label: String, icon: String, color: Color, highlight: Bool = false) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color.opacity(highlight ? 0.25 : 0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(color.opacity(highlight ? 0.6 : 0.3), lineWidth: highlight ? 1.5 : 1)
                )

            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 8, weight: highlight ? .bold : .medium))
                    .foregroundStyle(color)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
