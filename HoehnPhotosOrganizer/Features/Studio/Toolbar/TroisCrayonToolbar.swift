import SwiftUI

// MARK: - CrayonPalette

/// Preset color palettes for trois crayon rendering.
enum CrayonPalette: String, CaseIterable, Identifiable {
    case sanguine = "Sanguine"
    case ultramarine = "Ultramarine"
    case vanDyke = "Van Dyke"

    var id: String { rawValue }

    var sanguineColor: TroisCrayonPipeline.RGBColor {
        switch self {
        case .sanguine:    return TroisCrayonPipeline.RGBColor(r: 165, g: 65, b: 38)
        case .ultramarine: return TroisCrayonPipeline.RGBColor(r: 45, g: 65, b: 130)
        case .vanDyke:     return TroisCrayonPipeline.RGBColor(r: 85, g: 55, b: 35)
        }
    }

    var paperColor: TroisCrayonPipeline.RGBColor {
        switch self {
        case .sanguine:    return TroisCrayonPipeline.RGBColor(r: 194, g: 179, b: 158)
        case .ultramarine: return TroisCrayonPipeline.RGBColor(r: 220, g: 215, b: 200)
        case .vanDyke:     return TroisCrayonPipeline.RGBColor(r: 200, g: 185, b: 165)
        }
    }

    /// Determine which palette best matches the current colors, if any.
    static func matching(sanguine: TroisCrayonPipeline.RGBColor, paper: TroisCrayonPipeline.RGBColor) -> CrayonPalette {
        for palette in allCases {
            if palette.sanguineColor == sanguine && palette.paperColor == paper {
                return palette
            }
        }
        return .sanguine
    }
}

// MARK: - TroisCrayonToolbar

/// Horizontal toolbar controls for trois crayon parameters.
struct TroisCrayonToolbar: View {
    let externalParams: TroisCrayonPipeline.Params
    @State private var params: TroisCrayonPipeline.Params
    @State private var selectedPalette: CrayonPalette
    let onCommit: (String, TroisCrayonPipeline.Params) -> Void

    init(params: TroisCrayonPipeline.Params, onCommit: @escaping (String, TroisCrayonPipeline.Params) -> Void) {
        self.externalParams = params
        self._params = State(initialValue: params)
        self._selectedPalette = State(initialValue: CrayonPalette.matching(sanguine: params.sanguineColor, paper: params.paperColor))
        self.onCommit = onCommit
    }

    var body: some View {
        HStack(spacing: 12) {
            ToolbarSliderRow(
                "Blur",
                value: $params.blurRadius,
                in: 1...40,
                step: 1
            ) { onCommit("Change Blur Radius", params) }

            // Palette dropdown
            HStack(spacing: 4) {
                Text("Palette")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Picker("", selection: $selectedPalette) {
                    ForEach(CrayonPalette.allCases) { palette in
                        Text(palette.rawValue).tag(palette)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 100)
            }

            ToolbarSliderRow(
                "Contrast",
                value: $params.contrast,
                in: 50...200,
                step: 1
            ) { onCommit("Change Contrast", params) }
        }
        .onChange(of: externalParams) { _, newValue in
            params = newValue
            selectedPalette = CrayonPalette.matching(sanguine: newValue.sanguineColor, paper: newValue.paperColor)
        }
        .onChange(of: selectedPalette) { _, newPalette in
            params.sanguineColor = newPalette.sanguineColor
            params.paperColor = newPalette.paperColor
            onCommit("Change Palette", params)
        }
    }
}
