import SwiftUI

// MARK: - StudioMediumsView

/// Browse and configure medium presets.
struct StudioMediumsView: View {

    @ObservedObject var viewModel: StudioViewModel

    var body: some View {
        HStack(spacing: 0) {
            // Medium gallery
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 16)], spacing: 16) {
                    ForEach(ArtMedium.allCases) { medium in
                        mediumCard(medium)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    viewModel.selectMedium(medium)
                                }
                            }
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Detail panel
            selectedMediumDetail
                .frame(width: 300)
        }
    }

    private func mediumCard(_ medium: ArtMedium) -> some View {
        let isSelected = viewModel.selectedMedium == medium
        return VStack(alignment: .leading, spacing: 0) {
            // Preview area with paper color
            ZStack {
                medium.paperColor
                VStack(spacing: 8) {
                    Image(systemName: medium.icon)
                        .font(.system(size: 32))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    Text(medium.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .frame(height: 120)

            VStack(alignment: .leading, spacing: 4) {
                Text(medium.description)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(10)
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
    }

    private var selectedMediumDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: viewModel.selectedMedium.icon)
                        .font(.system(size: 24))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
                    VStack(alignment: .leading) {
                        Text(viewModel.selectedMedium.rawValue)
                            .font(.system(size: 16, weight: .semibold))
                        Text("Art Medium")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                // Description
                Text(viewModel.selectedMedium.description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Divider()

                // Default parameters
                VStack(alignment: .leading, spacing: 6) {
                    Text("DEFAULT PARAMETERS")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)

                    let p = viewModel.selectedMedium.defaultParams
                    paramRow("Brush Size", value: p.brushSize, max: 20)
                    paramRow("Detail", value: p.detail, max: 1)
                    paramRow("Texture", value: p.texture, max: 1)
                    paramRow("Saturation", value: p.colorSaturation, max: 1)
                    paramRow("Contrast", value: p.contrast, max: 1)
                }

                Divider()

                // Paper
                VStack(alignment: .leading, spacing: 6) {
                    Text("PAPER/SURFACE")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(viewModel.selectedMedium.paperColor)
                            .frame(width: 30, height: 30)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
                        Text(paperName(viewModel.selectedMedium))
                            .font(.system(size: 11))
                    }
                }

                Divider()

                Button {
                    viewModel.currentPage = .canvas
                } label: {
                    HStack {
                        Image(systemName: "paintbrush.pointed.fill")
                        Text("Use This Medium")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func paramRow(_ label: String, value: Double, max: Double) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .frame(width: 70, alignment: .trailing)
                .foregroundStyle(.secondary)
            ProgressView(value: value, total: max)
                .tint(.accentColor)
            Text(String(format: max > 1 ? "%.0f" : "%.1f", value))
                .font(.system(size: 9, design: .monospaced))
                .frame(width: 28)
        }
    }

    private func paperName(_ medium: ArtMedium) -> String {
        switch medium {
        case .troisCrayon: return "Toned Ingres paper"
        case .charcoal:    return "Rough newsprint / Canson"
        case .watercolor:  return "Cold-pressed cotton"
        case .oil:         return "Linen canvas"
        case .inkWash:     return "Rice paper (Xuan)"
        case .pastel:      return "Sanded pastel paper"
        case .graphite:    return "Smooth Bristol"
        case .penAndInk:   return "Hot-pressed illustration board"
        }
    }
}
