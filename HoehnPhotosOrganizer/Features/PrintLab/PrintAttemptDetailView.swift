import SwiftUI

struct PrintAttemptDetailView: View {
    @Environment(\.dismiss) var dismiss

    let attempt: PrintAttempt
    let sourceImage: NSImage?
    let outcomeImage: NSImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Image(systemName: printTypeIcon(attempt.printType))
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(attempt.printType.displayName)
                                    .font(.headline)
                                Text(formattedDate(attempt.createdAt))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            outcomeStatusBadge(attempt.outcome)
                        }
                    }
                    .padding()
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(8)

                    // Common fields
                    VStack(alignment: .leading, spacing: 12) {
                        PrintDetailSectionHeader(title: "Print Details")

                        PrintDetailRow(label: "Paper", value: attempt.paper)
                        PrintDetailRow(label: "Outcome", value: attempt.outcome.displayName)

                        if !attempt.outcomeNotes.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Outcome Notes")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(attempt.outcomeNotes)
                                    .font(.body)
                            }
                        }

                        if let curveFileName = attempt.curveFileName {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.fill")
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Curve File")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(curveFileName)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    .padding()

                    // Process-specific fields
                    if !attempt.processSpecificFields.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            PrintDetailSectionHeader(title: "Process-Specific Settings")

                            ForEach(Array(attempt.processSpecificFields.sorted { $0.key < $1.key }), id: \.key) { key, value in
                                PrintDetailRow(label: key, value: valueDescription(value))
                            }
                        }
                        .padding()
                    }

                    // Image comparison
                    PrintOutcomeComparisonView(sourceImage: sourceImage, outcomeImage: outcomeImage)

                    // Actions
                    VStack(spacing: 8) {
                        Button(action: { exportToXMP() }) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("Export to XMP")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        }

                        Button(action: { editAttempt() }) {
                            HStack {
                                Image(systemName: "pencil")
                                Text("Edit Attempt")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.gray.opacity(0.2))
                            .foregroundColor(.primary)
                            .cornerRadius(8)
                        }
                    }
                    .padding()
                }
                .padding()
            }
            .navigationTitle("Print Attempt")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func exportToXMP() {
        // Wave 5 placeholder: integrate XMPSidecarService
        // In full implementation: request file location, call XMPSidecarService.writePrintMetadata
    }

    private func editAttempt() {
        // Wave 5 placeholder: open edit form
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

    private func outcomeStatusBadge(_ outcome: PrintOutcome) -> some View {
        HStack(spacing: 4) {
            Image(systemName: outcomeIcon(outcome))
                .font(.caption)
            Text(outcome.displayName)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
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

    private func valueDescription(_ value: AnyCodable) -> String {
        switch value.value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let b as Bool: return b ? "Yes" : "No"
        default: return "—"
        }
    }
}

// MARK: - Subviews

struct PrintDetailSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundColor(.primary)
    }
}

struct PrintDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)

            Text(value)
                .font(.caption)
                .fontWeight(.medium)

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    let attempt = PrintAttempt(
        id: "test-001",
        photoId: "photo-001",
        printType: .platinumPalladium,
        paper: "Platinum Paper 100g",
        outcome: .pass,
        outcomeNotes: "Excellent density and tone separation",
        curveFileId: "curve-123",
        curveFileName: "Density_v2.acv",
        printPhotoId: nil,
        createdAt: Date(),
        updatedAt: Date(),
        processSpecificFields: [
            "platinumPercent": AnyCodable(95),
            "palladiumPercent": AnyCodable(5),
            "ferricOxalateDrops": AnyCodable(15)
        ]
    )

    return PrintAttemptDetailView(
        attempt: attempt,
        sourceImage: nil,
        outcomeImage: nil
    )
}
