import SwiftUI

// MARK: - InkWashToolbar

/// Horizontal toolbar controls for ink wash parameters.
struct InkWashToolbar: View {
    let externalParams: InkWashPipeline.Params
    @State private var params: InkWashPipeline.Params
    let onCommit: (String, InkWashPipeline.Params) -> Void

    init(params: InkWashPipeline.Params, onCommit: @escaping (String, InkWashPipeline.Params) -> Void) {
        self.externalParams = params
        self._params = State(initialValue: params)
        self.onCommit = onCommit
    }

    var body: some View {
        HStack(spacing: 12) {
            ToolbarStepperRow(
                label: "Bands",
                value: $params.numBands,
                range: 4...8
            ) { onCommit("Change Band Count", params) }

            ToolbarSliderRow(
                "Blur",
                value: $params.blurAmount,
                in: 0...12,
                step: 0.5,
                format: "%.1f"
            ) { onCommit("Change Blur Amount", params) }

            ToolbarSliderRow(
                "Edge",
                value: $params.edgeStrength,
                in: 0.2...0.8,
                step: 0.01,
                format: "%.2f"
            ) { onCommit("Change Edge Strength", params) }

            ToolbarSliderRow(
                "Density",
                value: $params.inkDensity,
                in: 0...1,
                step: 0.01,
                format: "%.2f"
            ) { onCommit("Change Ink Density", params) }
        }
        .onChange(of: externalParams) { _, newValue in
            params = newValue
        }
    }
}
