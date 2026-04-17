import SwiftUI

/// A toolbar for bulk curation state assignment.
/// Shows action buttons for Keeper, Archive, Needs Review, and Reject with a selection count.
/// For destructive states (Archive, Reject), displays a confirmation dialog before applying.
struct BulkActionToolbar: View {
    let selectedCount: Int
    let onApply: (CurationState) -> Void
    var onWorkflow: (() -> Void)? = nil

    @State private var pendingState: CurationState? = nil  // drives confirmationDialog

    var body: some View {
        HStack(spacing: 12) {
            Text("\(selectedCount) selected")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Divider()

            // Keeper button — no confirmation
            actionButton(
                label: "Keeper",
                state: .keeper,
                requiresConfirmation: false
            )

            // Archive button — requires confirmation
            actionButton(
                label: "Archive",
                state: .archive,
                requiresConfirmation: true
            )

            // Needs Review button — no confirmation
            actionButton(
                label: "Needs Review",
                state: .needsReview,
                requiresConfirmation: false
            )

            // Reject button — requires confirmation
            actionButton(
                label: "Reject",
                state: .rejected,
                requiresConfirmation: true
            )

            Spacer()

            if let onWorkflow {
                Divider()
                Button(action: onWorkflow) {
                    Label("Workflow", systemImage: "arrow.triangle.2.circlepath.circle")
                        .frame(height: 28)
                        .paddingHorizontal(8)
                }
                .buttonStyle(.bordered)
                .help("Send selected photos to Workflows")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.controlBackgroundColor))
        .confirmationDialog(
            "Apply to \(selectedCount) photos?",
            isPresented: .constant(pendingState != nil),
            presenting: pendingState,
            actions: { state in
                Button("Apply", role: .destructive) {
                    onApply(state)
                    pendingState = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingState = nil
                }
            },
            message: { state in
                Text("This will mark \(selectedCount) photo\(selectedCount == 1 ? "" : "s") as \(state.title.lowercased()).")
            }
        )
    }

    private func actionButton(label: String, state: CurationState, requiresConfirmation: Bool) -> some View {
        Button(action: {
            if requiresConfirmation {
                pendingState = state
            } else {
                onApply(state)
            }
        }) {
            Label(label, systemImage: systemImage(for: state))
                .frame(height: 28)
                .paddingHorizontal(8)
        }
        .buttonStyle(.bordered)
        .help(label)
    }

    private func systemImage(for state: CurationState) -> String {
        switch state {
        case .keeper:
            "star.fill"
        case .archive:
            "archivebox"
        case .needsReview:
            "exclamationmark.circle"
        case .rejected:
            "xmark.circle.fill"
        case .deleted:
            "trash.fill"
        }
    }
}

// MARK: - View Modifiers

extension View {
    fileprivate func paddingHorizontal(_ value: CGFloat) -> some View {
        padding(.horizontal, value)
    }
}

#Preview {
    BulkActionToolbar(
        selectedCount: 5,
        onApply: { state in
            print("Applied \(state.title)")
        }
    )
    .frame(height: 50)
    .padding()
}
