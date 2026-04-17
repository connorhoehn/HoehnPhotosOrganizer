import SwiftUI

// MARK: - GraphiteToolbar

/// Horizontal toolbar controls for graphite pencil parameters.
struct GraphiteToolbar: View {
    let externalParams: GraphitePipeline.Params
    @State private var params: GraphitePipeline.Params
    let onCommit: (String, GraphitePipeline.Params) -> Void

    init(params: GraphitePipeline.Params, onCommit: @escaping (String, GraphitePipeline.Params) -> Void) {
        self.externalParams = params
        self._params = State(initialValue: params)
        self.onCommit = onCommit
    }

    var body: some View {
        HStack(spacing: 12) {
            ToolbarSliderRow(
                "Blur",
                value: $params.blurRadius,
                in: 0.1...3.0,
                step: 0.05,
                format: "%.2f"
            ) { onCommit("Change Blur Radius", params) }

            ThresholdPopoverButton(
                label: "Thresh",
                thresholds: $params.thresholds,
                valueRange: 0...255
            ) { onCommit("Change Thresholds", params) }

            ToolbarSliderRow(
                "Contrast",
                value: $params.contrast,
                in: 50...200,
                step: 1
            ) { onCommit("Change Contrast", params) }

            ToolbarSliderRow(
                "Paper",
                value: $params.paperTexture,
                in: 0...0.6,
                step: 0.01,
                format: "%.2f"
            ) { onCommit("Change Paper Texture", params) }

            ToolbarSliderRow(
                "Noise",
                value: $params.noiseStrength,
                in: 1...15,
                step: 0.5,
                format: "%.1f"
            ) { onCommit("Change Noise Strength", params) }
        }
        .onChange(of: externalParams) { _, newValue in
            params = newValue
        }
    }
}
