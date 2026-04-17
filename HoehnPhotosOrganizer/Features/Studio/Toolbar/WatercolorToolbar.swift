import SwiftUI

// MARK: - WatercolorToolbar

/// Horizontal toolbar controls for watercolor parameters.
struct WatercolorToolbar: View {
    let externalParams: WatercolorPipeline.Params
    @State private var params: WatercolorPipeline.Params
    let onCommit: (String, WatercolorPipeline.Params) -> Void

    init(params: WatercolorPipeline.Params, onCommit: @escaping (String, WatercolorPipeline.Params) -> Void) {
        self.externalParams = params
        self._params = State(initialValue: params)
        self.onCommit = onCommit
    }

    var body: some View {
        HStack(spacing: 12) {
            ToolbarStepperRow(
                label: "Colors",
                value: $params.numColors,
                range: 3...16
            ) { onCommit("Change Color Count", params) }

            ToolbarSliderRow(
                "Wash",
                value: $params.washIntensity,
                in: 0...1,
                step: 0.01,
                format: "%.2f"
            ) { onCommit("Change Wash Intensity", params) }

            ToolbarSliderRow(
                "Bleed",
                value: $params.bleedAmount,
                in: 2...15,
                step: 0.5,
                format: "%.1f"
            ) { onCommit("Change Bleed Amount", params) }

            ToolbarSliderRow(
                "Wetness",
                value: $params.paperWetness,
                in: 0...0.8,
                step: 0.01,
                format: "%.2f"
            ) { onCommit("Change Paper Wetness", params) }
        }
        .onChange(of: externalParams) { _, newValue in
            params = newValue
        }
    }
}
