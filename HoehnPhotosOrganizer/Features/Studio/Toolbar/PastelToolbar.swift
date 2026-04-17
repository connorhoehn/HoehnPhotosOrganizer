import SwiftUI

// MARK: - PastelToolbar

/// Horizontal toolbar controls for pastel parameters.
struct PastelToolbar: View {
    let externalParams: PastelPipeline.Params
    @State private var params: PastelPipeline.Params
    let onCommit: (String, PastelPipeline.Params) -> Void

    init(params: PastelPipeline.Params, onCommit: @escaping (String, PastelPipeline.Params) -> Void) {
        self.externalParams = params
        self._params = State(initialValue: params)
        self.onCommit = onCommit
    }

    var body: some View {
        HStack(spacing: 12) {
            ToolbarStepperRow(
                label: "Colors",
                value: $params.numColors,
                range: 6...20
            ) { onCommit("Change Color Count", params) }

            ToolbarSliderRow(
                "Softness",
                value: $params.softness,
                in: 0...8,
                step: 0.5,
                format: "%.1f"
            ) { onCommit("Change Softness", params) }

            ToolbarSliderRow(
                "Saturation",
                value: $params.saturation,
                in: 0.5...2.0,
                step: 0.05,
                format: "%.2f"
            ) { onCommit("Change Saturation", params) }

            ToolbarSliderRow(
                "Grain",
                value: $params.textureGrain,
                in: 0...1,
                step: 0.01,
                format: "%.2f"
            ) { onCommit("Change Texture Grain", params) }
        }
        .onChange(of: externalParams) { _, newValue in
            params = newValue
        }
    }
}
