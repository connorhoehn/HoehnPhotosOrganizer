import SwiftUI

// MARK: - StatusBanner
//
// Reusable bottom-anchored status banner intended to replace the ad-hoc
// `statusMessage`-style state that has been accumulating across features
// (StudioViewModel, DevelopView, etc.).
//
// Drop-in usage:
//
//     @State private var status: StatusBanner.Message? = nil
//     ...
//     SomeView()
//         .statusBanner(message: $status)
//
//     // Fire from anywhere that has access to the binding / @Published value:
//     status = .init(text: "Version saved", style: .success)
//     status = .init(
//         text: "Export failed: \(error.localizedDescription)",
//         style: .error,
//         action: ("Retry", { retry() })
//     )
//
// Each assignment cancels any in-flight auto-dismiss timer and animates the
// new message in. Tapping the capsule (anywhere but the action button) also
// dismisses it.
enum StatusBanner {

    // MARK: Style

    /// Visual variant for the banner. Determines tint, icon, and default
    /// auto-dismiss timeout.
    enum Style {
        case info
        case success
        case warning
        case error

        var tint: Color {
            switch self {
            case .info:    return .blue
            case .success: return .green
            case .warning: return .orange
            case .error:   return .red
            }
        }

        var symbol: String {
            switch self {
            case .info:    return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error:   return "xmark.octagon.fill"
            }
        }

        /// Default seconds before auto-dismiss. Errors linger longer so the
        /// user has a chance to read them; info/success disappear quickly.
        var defaultDismissAfter: TimeInterval {
            switch self {
            case .error:   return 8
            case .warning: return 6
            case .info, .success: return 4
            }
        }
    }

    // MARK: Message

    /// A single banner payload. New `id`s force a re-render and reset the
    /// auto-dismiss timer (because the modifier keys `.task(id:)` on it).
    struct Message: Identifiable, Equatable {
        let id: UUID
        var text: String
        var style: Style
        var action: Action?
        /// Override the style's default dismiss timeout. nil = use style default.
        var dismissAfter: TimeInterval?

        init(
            id: UUID = UUID(),
            text: String,
            style: Style = .info,
            action: Action? = nil,
            dismissAfter: TimeInterval? = nil
        ) {
            self.id = id
            self.text = text
            self.style = style
            self.action = action
            self.dismissAfter = dismissAfter
        }

        /// Effective auto-dismiss timeout (override or style default).
        var effectiveDismissAfter: TimeInterval {
            dismissAfter ?? style.defaultDismissAfter
        }

        static func == (lhs: Message, rhs: Message) -> Bool {
            // Identity-based equality so successive identical-text messages
            // still re-trigger the .task(id:) reset.
            lhs.id == rhs.id
        }
    }

    // MARK: Action

    /// Optional trailing button on the banner. Stored as a struct rather than a
    /// tuple so it can sit cleanly inside `Message` (tuples can't conform to
    /// Equatable without per-field gymnastics).
    struct Action {
        let label: String
        let perform: () -> Void

        init(label: String, perform: @escaping () -> Void) {
            self.label = label
            self.perform = perform
        }
    }
}

// MARK: - Tuple-style convenience initializer
//
// The spec shows `action: ("Retry", { ... })` at call sites — accept a tuple
// for ergonomics and forward to the struct.
extension StatusBanner.Message {
    init(
        id: UUID = UUID(),
        text: String,
        style: StatusBanner.Style = .info,
        action: (label: String, perform: () -> Void)?,
        dismissAfter: TimeInterval? = nil
    ) {
        self.init(
            id: id,
            text: text,
            style: style,
            action: action.map { StatusBanner.Action(label: $0.label, perform: $0.perform) },
            dismissAfter: dismissAfter
        )
    }
}

// MARK: - ViewModifier

private struct StatusBannerModifier: ViewModifier {
    @Binding var message: StatusBanner.Message?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    StatusBannerView(message: message) {
                        dismiss()
                    }
                    .padding(.bottom, 24)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1_000)
                }
            }
            // Re-key on the message id so a new message resets the timer.
            // Cancellation of the previous task is automatic when the id flips.
            .task(id: message?.id) {
                guard let active = message else { return }
                let seconds = active.effectiveDismissAfter
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                } catch {
                    // Cancelled — newer message took over, nothing to do.
                    return
                }
                // Only clear if we're still the active message. Without this
                // check, a fast-fire replacement that lands while we were
                // sleeping could be clobbered if Task cancellation lost the race.
                if message?.id == active.id {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        message = nil
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: message?.id)
    }

    private func dismiss() {
        withAnimation(.easeInOut(duration: 0.25)) {
            message = nil
        }
    }
}

// MARK: - Inner View

private struct StatusBannerView: View {
    let message: StatusBanner.Message
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: message.style.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)

            Text(message.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if let action = message.action {
                Button(action.label) {
                    action.perform()
                    onDismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(Color.white.opacity(0.22))
                )
                // Make sure tapping the action does NOT bubble up to the
                // capsule's tap-to-dismiss gesture below.
                .contentShape(Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule(style: .continuous)
                .fill(message.style.tint)
                .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 3)
        )
        // Tap anywhere on the capsule (except the action button, which has its
        // own button hit-region) to dismiss.
        .contentShape(Capsule())
        .onTapGesture { onDismiss() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(message.text))
    }
}

// MARK: - View extension (drop-in API)

extension View {
    /// Attach a status banner overlay driven by a binding to an optional
    /// `StatusBanner.Message`. Setting the binding shows the banner and starts
    /// the auto-dismiss timer; new assignments cancel the previous timer.
    func statusBanner(message: Binding<StatusBanner.Message?>) -> some View {
        modifier(StatusBannerModifier(message: message))
    }
}
