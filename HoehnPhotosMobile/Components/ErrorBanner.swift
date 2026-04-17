import SwiftUI

/// Reusable error banner with optional retry action.
/// Shows a red-tinted HStack with exclamation icon, error text, and optional "Retry" button.
struct ErrorBanner: View {
    let message: String
    var retryAction: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(3)
            Spacer()
            if let retry = retryAction {
                Button("Retry", action: retry)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.2), in: Capsule())
                    .accessibilityLabel("Retry")
            }
        }
        .padding(16)
        .background(Color.red, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
        .accessibilityAddTraits(.isStaticText)
    }
}
