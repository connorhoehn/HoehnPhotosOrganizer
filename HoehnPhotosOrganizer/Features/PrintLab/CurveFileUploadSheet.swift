import SwiftUI
import UniformTypeIdentifiers

struct CurveFileUploadSheet: View {
    @Environment(\.dismiss) var dismiss

    @State private var isFilePickerPresented = false
    @State private var selectedFileURL: URL?
    @State private var isUploading = false
    @State private var uploadProgress: Double = 0
    @State private var errorMessage: String?

    var photoId: String
    var attemptId: String
    var onUploadComplete: (CurveFileReference) -> Void = { _ in }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Curve File Upload", systemImage: "doc.fill")
                        .font(.headline)

                    Text("Select a curve file (.acv, .csv, .lut, or .cube) to store with this print attempt. The file will be uploaded to cloud storage and linked to your print recipe.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()

                if let selectedFileURL = selectedFileURL {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "doc.fill")
                            VStack(alignment: .leading) {
                                Text(selectedFileURL.lastPathComponent)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text(formattedFileSize(selectedFileURL))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if isUploading {
                                ProgressView(value: uploadProgress)
                                    .frame(width: 40)
                            }
                        }
                        .padding()
                        .background(Color(.controlBackgroundColor))
                        .cornerRadius(8)
                    }
                    .padding()
                } else {
                    Button(action: { isFilePickerPresented = true }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Choose Curve File...")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                    .disabled(isUploading)
                    .padding()
                }

                if let errorMessage = errorMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.red)
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                    .padding()
                }

                Spacer()
            }
            .navigationTitle("Upload Curve File")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isUploading)
                }
                if selectedFileURL != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        if isUploading {
                            ProgressView()
                        } else {
                            Button("Upload") {
                                Task {
                                    await performUpload()
                                }
                            }
                        }
                    }
                }
            }
            .fileImporter(
                isPresented: $isFilePickerPresented,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false,
                onCompletion: { result in
                    handleFileSelection(result)
                }
            )
        }
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                selectedFileURL = url
                errorMessage = nil
            }
        case .failure(let error):
            errorMessage = "Failed to select file: \(error.localizedDescription)"
        }
    }

    private func performUpload() async {
        guard let fileURL = selectedFileURL else { return }

        isUploading = true
        defer { isUploading = false }

        do {
            // Instantiate service (injection point for Phase 4 S3 client)
            // For now, this is a placeholder - in real code, would get from environment or dependency injection
            errorMessage = "S3 service not yet configured - this will be set up in Phase 4"
            return
        } catch let error as CurveFileError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "Upload failed: \(error.localizedDescription)"
        }
    }

    private func formattedFileSize(_ url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else {
            return "Unknown size"
        }

        let formatter = ByteCountFormatter()
        return formatter.string(fromByteCount: Int64(size))
    }
}

#Preview {
    CurveFileUploadSheet(photoId: "photo-001", attemptId: "attempt-001")
}
