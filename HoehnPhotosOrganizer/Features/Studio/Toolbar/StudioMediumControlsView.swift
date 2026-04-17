import SwiftUI
import Combine

// MARK: - StudioMediumControlsView

/// Isolated view that only re-renders when params change — not on every ViewModel update.
/// This prevents slider lag caused by unrelated @Published changes (chat, versions, DB).
struct StudioMediumControlsView: View {
    let params: MediumParams
    let onUpdate: (MediumParams, String) -> Void

    var body: some View {
        switch params {
        case .oil(let p):
            OilToolbar(params: p) { name, newParams in
                onUpdate(.oil(newParams), name)
            }
        case .watercolor(let p):
            WatercolorToolbar(params: p) { name, newParams in
                onUpdate(.watercolor(newParams), name)
            }
        case .charcoal(let p):
            CharcoalToolbar(params: p) { name, newParams in
                onUpdate(.charcoal(newParams), name)
            }
        case .troisCrayon(let p):
            TroisCrayonToolbar(params: p) { name, newParams in
                onUpdate(.troisCrayon(newParams), name)
            }
        case .graphite(let p):
            GraphiteToolbar(params: p) { name, newParams in
                onUpdate(.graphite(newParams), name)
            }
        case .inkWash(let p):
            InkWashToolbar(params: p) { name, newParams in
                onUpdate(.inkWash(newParams), name)
            }
        case .pastel(let p):
            PastelToolbar(params: p) { name, newParams in
                onUpdate(.pastel(newParams), name)
            }
        case .penAndInk(let p):
            PenAndInkToolbar(params: p) { name, newParams in
                onUpdate(.penAndInk(newParams), name)
            }
        }
    }
}
