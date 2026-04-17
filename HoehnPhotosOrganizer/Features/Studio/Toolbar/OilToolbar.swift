import SwiftUI

// MARK: - OilToolbar

/// Horizontal toolbar controls for oil painting parameters.
struct OilToolbar: View {
    let externalParams: OilPaintPipeline.Params
    @State private var params: OilPaintPipeline.Params
    let onCommit: (String, OilPaintPipeline.Params) -> Void

    init(params: OilPaintPipeline.Params, onCommit: @escaping (String, OilPaintPipeline.Params) -> Void) {
        self.externalParams = params
        self._params = State(initialValue: params)
        self.onCommit = onCommit
    }

    var body: some View {
        HStack(spacing: 12) {
            ToolbarStepperRow(
                label: "Colors",
                value: $params.numColors,
                range: 4...24
            ) { onCommit("Change Color Count", params) }
        }
        .onChange(of: externalParams) { _, newValue in
            params = newValue
        }
    }
}
