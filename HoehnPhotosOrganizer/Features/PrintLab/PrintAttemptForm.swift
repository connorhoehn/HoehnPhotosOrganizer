import SwiftUI

struct PrintAttemptForm: View {
    @Environment(\.dismiss) var dismiss

    @State private var printType = PrintType.platinumPalladium
    @State private var paper = ""
    @State private var outcome = PrintOutcome.pass
    @State private var outcomeNotes = ""
    @State private var processFields: [String: AnyCodable] = [:]

    var onSave: (PrintAttempt) -> Void = { _ in }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PrintTypeSelector(selectedType: $printType)

                    Divider()

                    // Common fields
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Print Details")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 8) {
                            Label("Paper Name", systemImage: "doc.text")
                            TextField("e.g., Platinum Paper 100g/m²", text: $paper)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Label("Outcome", systemImage: "checkmark.circle")
                            Picker("Outcome", selection: $outcome) {
                                ForEach(PrintOutcome.allCases) { outc in
                                    Text(outc.displayName).tag(outc)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Label("Outcome Notes", systemImage: "note.text")
                            TextEditor(text: $outcomeNotes)
                                .frame(height: 100)
                                .border(Color.gray.opacity(0.3))
                        }
                    }
                    .padding()

                    Divider()

                    ProcessSpecificFieldsView(printType: $printType, processFields: $processFields)
                }
                .padding()
            }
            .navigationTitle("Log Print Attempt")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        savePrintAttempt()
                    }
                    .disabled(paper.isEmpty)
                }
            }
        }
    }

    private func savePrintAttempt() {
        let attempt = PrintAttempt(
            id: UUID().uuidString,
            photoId: "",  // Will be set by caller
            printType: printType,
            paper: paper,
            outcome: outcome,
            outcomeNotes: outcomeNotes,
            curveFileId: nil,  // Set in Wave 3
            curveFileName: nil,
            printPhotoId: nil,  // Set in Wave 6
            createdAt: Date(),
            updatedAt: Date(),
            processSpecificFields: processFields
        )

        onSave(attempt)
        dismiss()
    }
}

#Preview {
    PrintAttemptForm()
}
