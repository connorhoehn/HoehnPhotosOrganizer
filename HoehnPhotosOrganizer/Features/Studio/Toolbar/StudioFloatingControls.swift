import SwiftUI

// MARK: - StudioFloatingControls

/// Floating glass-panel overlay with medium-specific parameter controls.
/// Sits on top of the canvas area, horizontally scrollable.
struct StudioFloatingControls: View {
    @ObservedObject var viewModel: StudioViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            controls
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var controls: some View {
        switch viewModel.mediumParams {
        case .oil(let p):
            OilToolbar(params: p) { name, newParams in
                viewModel.updateParams(.oil(newParams), commandName: name)
            }
        case .watercolor(let p):
            WatercolorToolbar(params: p) { name, newParams in
                viewModel.updateParams(.watercolor(newParams), commandName: name)
            }
        case .charcoal(let p):
            CharcoalToolbar(params: p) { name, newParams in
                viewModel.updateParams(.charcoal(newParams), commandName: name)
            }
        case .troisCrayon(let p):
            TroisCrayonToolbar(params: p) { name, newParams in
                viewModel.updateParams(.troisCrayon(newParams), commandName: name)
            }
        case .graphite(let p):
            GraphiteToolbar(params: p) { name, newParams in
                viewModel.updateParams(.graphite(newParams), commandName: name)
            }
        case .inkWash(let p):
            InkWashToolbar(params: p) { name, newParams in
                viewModel.updateParams(.inkWash(newParams), commandName: name)
            }
        case .pastel(let p):
            PastelToolbar(params: p) { name, newParams in
                viewModel.updateParams(.pastel(newParams), commandName: name)
            }
        case .penAndInk(let p):
            PenAndInkToolbar(params: p) { name, newParams in
                viewModel.updateParams(.penAndInk(newParams), commandName: name)
            }
        }
    }
}
