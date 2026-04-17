import SwiftUI

// MARK: - CharcoalToolbar

/// Horizontal toolbar controls for charcoal drawing parameters.
struct CharcoalToolbar: View {
    let externalParams: CharcoalPipeline.Params
    @State private var params: CharcoalPipeline.Params
    let onCommit: (String, CharcoalPipeline.Params) -> Void

    init(params: CharcoalPipeline.Params, onCommit: @escaping (String, CharcoalPipeline.Params) -> Void) {
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

            ToolbarSliderRow(
                "Contrast",
                value: $params.contrast,
                in: 50...200,
                step: 1
            ) { onCommit("Change Contrast", params) }

            ToolbarSliderRow(
                "Paper",
                value: $params.paperRoughness,
                in: 0...1,
                step: 0.01,
                format: "%.2f"
            ) { onCommit("Change Paper Roughness", params) }

            ToolbarSliderRow(
                "Smudge",
                value: $params.smudgeAmount,
                in: 0.5...5.0,
                step: 0.25,
                format: "%.2f"
            ) { onCommit("Change Smudge Amount", params) }
        }
        .onChange(of: externalParams) { _, newValue in
            params = newValue
        }
    }
}
