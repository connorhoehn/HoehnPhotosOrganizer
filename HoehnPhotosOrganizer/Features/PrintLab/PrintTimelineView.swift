import SwiftUI
import GRDB

struct PrintTimelineView: View {
    @StateObject private var viewModel: PrintTimelineViewModel
    @State private var selectedAttempt: PrintAttempt?
    @State private var showExportSheet = false

    var photoId: String
    var sourcePhotoImage: NSImage?

    init(photoId: String, db: any DatabaseWriter, sourcePhotoImage: NSImage? = nil) {
        self._viewModel = StateObject(wrappedValue: PrintTimelineViewModel(db))
        self.photoId = photoId
        self.sourcePhotoImage = sourcePhotoImage
    }

    var body: some View {
        NavigationStack {
            VStack {
                if viewModel.timelineEntries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "printer")
                            .font(.system(size: 44))
                            .foregroundColor(.secondary)
                        Text("No Print Attempts")
                            .font(.headline)
                        Text("Log your first print attempt to get started.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.controlBackgroundColor))
                } else {
                    List {
                        ForEach(viewModel.timelineEntries) { attempt in
                            PrintTimelineRowView(
                                attempt: attempt,
                                onSelect: { selectedAttempt = attempt },
                                onExport: { selectedAttempt = attempt; showExportSheet = true }
                            )
                        }
                    }
                    .listStyle(.plain)
                }

                if let error = viewModel.errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                        Spacer()
                        Button("Dismiss") { viewModel.errorMessage = nil }
                            .font(.caption)
                    }
                    .padding()
                    .background(Color.red.opacity(0.1))
                }
            }
            .navigationTitle("Print Timeline")
            .task {
                await viewModel.loadTimeline(for: photoId)
            }
            .sheet(isPresented: $showExportSheet) {
                if let attempt = selectedAttempt {
                    PrintRecipeExportView(
                        attempt: attempt,
                        sourceImage: sourcePhotoImage
                    )
                }
            }
        }
    }
}

struct PrintTimelineRowView: View {
    let attempt: PrintAttempt
    var onSelect: () -> Void
    var onExport: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: printTypeIcon(attempt.printType))
                        .font(.headline)
                    Text(attempt.printType.displayName)
                        .fontWeight(.medium)
                    Spacer()
                    outcomeStatusView(attempt.outcome)
                }

                Text("Paper: \(attempt.paper)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(formattedDate(attempt.createdAt))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: onExport) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 14))
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private func printTypeIcon(_ type: PrintType) -> String {
        switch type {
        case .inkjetColor, .inkjetBW: "printer"
        case .silverGelatinDarkroom: "lamp.desk"
        case .platinumPalladium: "sparkles"
        case .cyanotype: "drop.fill"
        case .digitalNegative: "photo"
        }
    }

    private func outcomeStatusView(_ outcome: PrintOutcome) -> some View {
        HStack(spacing: 4) {
            Image(systemName: outcomeIcon(outcome))
                .font(.caption)
            Text(outcome.displayName)
                .font(.caption)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(outcomeColor(outcome).opacity(0.2))
        .foregroundColor(outcomeColor(outcome))
        .cornerRadius(4)
    }

    private func outcomeIcon(_ outcome: PrintOutcome) -> String {
        switch outcome {
        case .pass: "checkmark.circle.fill"
        case .fail: "x.circle.fill"
        case .needsAdjustment: "exclamationmark.circle.fill"
        case .testing: "questionmark.circle.fill"
        }
    }

    private func outcomeColor(_ outcome: PrintOutcome) -> Color {
        switch outcome {
        case .pass: .green
        case .fail: .red
        case .needsAdjustment: .orange
        case .testing: .blue
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

#Preview {
    PrintTimelineView(photoId: "photo-001", db: try! AppDatabase.makeInMemory().dbPool)
}
