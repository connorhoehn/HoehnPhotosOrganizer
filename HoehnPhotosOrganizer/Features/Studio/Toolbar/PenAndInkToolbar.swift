import SwiftUI

// MARK: - PenAndInkToolbar

/// Horizontal toolbar controls for pen & ink parameters.
struct PenAndInkToolbar: View {
    let externalParams: PenAndInkPipeline.Params
    @State private var params: PenAndInkPipeline.Params
    let onCommit: (String, PenAndInkPipeline.Params) -> Void

    init(params: PenAndInkPipeline.Params, onCommit: @escaping (String, PenAndInkPipeline.Params) -> Void) {
        self.externalParams = params
        self._params = State(initialValue: params)
        self.onCommit = onCommit
    }

    var body: some View {
        HStack(spacing: 12) {
            ToolbarSliderRow(
                "Sensitivity",
                value: $params.edgeSensitivity,
                in: 0...1,
                step: 0.01,
                format: "%.2f"
            ) { onCommit("Change Edge Sensitivity", params) }

            ToolbarSliderRow(
                "Weight",
                value: $params.lineWeight,
                in: 0...3,
                step: 0.1,
                format: "%.1f"
            ) { onCommit("Change Line Weight", params) }

            ToolbarSliderRow(
                "Contrast",
                value: $params.contrast,
                in: 0.5...2.0,
                step: 0.05,
                format: "%.2f"
            ) { onCommit("Change Contrast", params) }
        }
        .onChange(of: externalParams) { _, newValue in
            params = newValue
        }
    }
}
