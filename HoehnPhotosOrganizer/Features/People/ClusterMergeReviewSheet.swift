import SwiftUI

// MARK: - ClusterMergeReviewSheet

/// Review sheet that presents Claude's cluster merge suggestions side-by-side.
/// User confirms or rejects each suggestion. No auto-merge ever happens.
struct ClusterMergeReviewSheet: View {
    let suggestions: [ClusterMergeService.MergeSuggestion]
    let onConfirm: (ClusterMergeService.MergeSuggestion) -> Void
    let onReject: (ClusterMergeService.MergeSuggestion) -> Void
    let onDismiss: () -> Void

    @State private var decisions: [String: Bool] = [:]  // id -> true=confirmed, false=rejected

    private var pendingCount: Int {
        suggestions.count - decisions.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Merge Suggestions")
                        .font(.system(size: 17, weight: .bold))
                    Text("Claude found \(suggestions.count) potential match\(suggestions.count == 1 ? "" : "es"). Review each pair below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if pendingCount == 0 {
                    Button("Done") { onDismiss() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                } else {
                    Button("Dismiss") { onDismiss() }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                }
            }
            .padding(20)

            Divider()

            if suggestions.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 40))
                        .foregroundStyle(.green)
                    Text("No merge suggestions")
                        .font(.title3.weight(.semibold))
                    Text("Claude did not find any high-confidence matches between clusters.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(40)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(suggestions) { suggestion in
                            MergeSuggestionCard(
                                suggestion: suggestion,
                                decision: decisions[suggestion.id],
                                onConfirm: {
                                    decisions[suggestion.id] = true
                                    onConfirm(suggestion)
                                },
                                onReject: {
                                    decisions[suggestion.id] = false
                                    onReject(suggestion)
                                }
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 600, idealWidth: 700, minHeight: 400, idealHeight: 500)
    }
}

// MARK: - MergeSuggestionCard

private struct MergeSuggestionCard: View {
    let suggestion: ClusterMergeService.MergeSuggestion
    let decision: Bool?  // nil = pending, true = confirmed, false = rejected
    let onConfirm: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Side-by-side sprites
            HStack(spacing: 20) {
                spritePanel(label: suggestion.sourceLabel, jpegData: suggestion.sourceSprite)

                // Arrow / merge indicator
                VStack(spacing: 4) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Same person?")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 80)

                spritePanel(label: suggestion.targetLabel, jpegData: suggestion.targetSprite)
            }

            // Reasoning
            if !suggestion.reasoning.isEmpty {
                Text(suggestion.reasoning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }

            // Action buttons or decision badge
            if let decided = decision {
                HStack(spacing: 8) {
                    Image(systemName: decided ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(decided ? .green : .red)
                    Text(decided ? "Merged" : "Rejected")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(decided ? .green : .red)
                }
                .padding(.vertical, 4)
            } else {
                HStack(spacing: 12) {
                    Button {
                        onReject()
                    } label: {
                        Label("Not the same", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.regular)

                    Button {
                        onConfirm()
                    } label: {
                        Label("Merge", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(cardBorder, lineWidth: 1)
        )
    }

    private var cardBackground: Color {
        if let decided = decision {
            return decided ? Color.green.opacity(0.05) : Color.red.opacity(0.05)
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var cardBorder: Color {
        if let decided = decision {
            return decided ? Color.green.opacity(0.3) : Color.red.opacity(0.3)
        }
        return Color(nsColor: .separatorColor)
    }

    private func spritePanel(label: String, jpegData: Data) -> some View {
        VStack(spacing: 6) {
            if let nsImage = NSImage(data: jpegData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 200, maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .quaternarySystemFill))
                    .frame(width: 120, height: 120)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    )
            }
            Text(displayLabel(label))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    /// Strip internal details for display (e.g., "Cluster A (Person 3)" -> "Cluster A")
    private func displayLabel(_ label: String) -> String {
        if label.hasPrefix("Known: ") {
            return String(label.dropFirst("Known: ".count))
        }
        if label.hasPrefix("Cluster "), let parenIdx = label.firstIndex(of: "(") {
            return String(label[label.startIndex..<parenIdx]).trimmingCharacters(in: .whitespaces)
        }
        return label
    }
}
