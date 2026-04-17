import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

struct PrintRecipeExportView: View {
    @Environment(\.dismiss) var dismiss

    let attempt: PrintAttempt
    let sourceImage: NSImage?

    @State private var pdfDocument: PDFDocument?
    @State private var isGenerating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // PDF Preview
                if let pdfDocument = pdfDocument {
                    VStack(spacing: 8) {
                        Text("Recipe Preview")
                            .font(.headline)

                        // Show first page thumbnail
                        if let firstPage = pdfDocument.page(at: 0) {
                            PDFPageView(page: firstPage)
                                .frame(height: 300)
                                .border(Color.gray.opacity(0.3))
                        }
                    }
                    .padding()
                } else if isGenerating {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Generating recipe PDF...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage = errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.red)
                        Text(errorMessage)
                            .font(.caption)
                    }
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                    .padding()
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Export Recipe")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if pdfDocument != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: saveToFile) {
                            HStack {
                                Image(systemName: "arrow.down.doc")
                                Text("Save PDF")
                            }
                        }
                    }
                }
            }
            .task {
                await generatePDF()
            }
        }
    }

    private func generatePDF() async {
        isGenerating = true
        defer { isGenerating = false }

        let exporter = PrintRecipeExporter()
        if let pdf = exporter.generateRecipePDF(
            attempt: attempt,
            sourceImage: sourceImage,
            printPhoto: nil
        ) {
            self.pdfDocument = pdf
        } else {
            self.errorMessage = "Failed to generate PDF"
        }
    }

    private func saveToFile() {
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = recipeFileName()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.canCreateDirectories = true

        savePanel.begin { response in
            if response == .OK, let url = savePanel.url, let pdfData = pdfDocument?.dataRepresentation() {
                do {
                    try pdfData.write(to: url)
                    dismiss()
                } catch {
                    errorMessage = "Failed to save: \(error.localizedDescription)"
                }
            }
        }
    }

    private func recipeFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmm"
        let dateStr = formatter.string(from: attempt.createdAt)
        return "Recipe_\(attempt.printType.rawValue)_\(dateStr).pdf"
    }
}

// PDF page thumbnail view
struct PDFPageView: NSViewRepresentable {
    let page: PDFPage

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument()
        view.document?.insert(page, at: 0)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        // No updates needed
    }
}

#Preview {
    let attempt = PrintAttempt(
        id: "test-001",
        photoId: "photo-001",
        printType: .platinumPalladium,
        paper: "Test Paper",
        outcome: .pass,
        outcomeNotes: "Good density",
        curveFileId: nil,
        curveFileName: nil,
        printPhotoId: nil,
        createdAt: Date(),
        updatedAt: Date(),
        processSpecificFields: [:]
    )
    return PrintRecipeExportView(attempt: attempt, sourceImage: nil)
}
