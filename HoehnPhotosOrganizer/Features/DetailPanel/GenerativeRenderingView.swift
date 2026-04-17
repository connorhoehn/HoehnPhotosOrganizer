import SwiftUI
import CoreImage
import AppKit

// MARK: - GenerativeRenderingView

/// SwiftUI sheet for selecting a generative rendering style (line art or watercolor),
/// previewing the result, and saving the output to the pipeline outputs directory.
///
/// Workflow:
/// 1. User selects "Line Art" or "Watercolor" from the segment picker.
/// 2. User adjusts style options (high contrast / intensity).
/// 3. User taps "Generate" — LibraryViewModel calls the appropriate service.
/// 4. Preview image updates in the view.
/// 5. User taps "Save to Outputs" — saves the rendering and creates an AssetLineage entry.
struct GenerativeRenderingView: View {

    // MARK: - Input

    let photo: PhotoAsset
    @ObservedObject var viewModel: LibraryViewModel

    // MARK: - Environment

    @Environment(\.appDatabase) private var appDatabase: AppDatabase?
    @Environment(\.dismiss) private var dismiss

    // MARK: - Local state

    /// Selected rendering style: "lineArt" or "watercolor"
    @State private var renderingStyle: String = "lineArt"
    /// True while a rendering generation is in progress
    @State private var isGenerating: Bool = false
    /// Preview of the most recently generated rendering
    @State private var previewImage: NSImage?
    /// Human-readable error message, if the last generation failed
    @State private var errorMessage: String?
    /// True while the rendering is being saved to outputs
    @State private var isSaving: Bool = false
    /// Success message shown after a successful save
    @State private var savedPath: String?

    // Watercolor-specific
    @State private var intensity: Float = 0.5

    // Line art-specific
    @State private var highContrast: Bool = false

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // Style picker
                    stylePickerSection

                    // Style-specific options
                    styleOptionsSection

                    // Generate button
                    generateSection

                    // Preview
                    previewSection

                    // Save section (shown after a successful generate)
                    if previewImage != nil {
                        saveSection
                    }
                }
                .padding(20)
            }
            .navigationTitle("Generative Rendering for Print")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 560)
    }

    // MARK: - Subviews

    private var stylePickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rendering Style")
                .font(.headline)

            Picker("Style", selection: $renderingStyle) {
                Text("Line Art").tag("lineArt")
                Text("Watercolor").tag("watercolor")
            }
            .pickerStyle(.segmented)
            .onChange(of: renderingStyle) { _, _ in
                // Clear preview when style changes
                previewImage = nil
                errorMessage = nil
                savedPath = nil
            }
        }
    }

    @ViewBuilder
    private var styleOptionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if renderingStyle == "lineArt" {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Line Art Options")
                        .font(.headline)

                    Toggle("High Contrast (for etching)", isOn: $highContrast)
                        .onChange(of: highContrast) { _, _ in
                            previewImage = nil
                            savedPath = nil
                        }

                    Text(highContrast
                         ? "Uses CIEdges + CIColorInvert for bold, high-contrast edges suitable for etching plates."
                         : "Uses CILineOverlay for a softer pencil-sketch appearance.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Watercolor Options")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Watercolor Intensity")
                            Spacer()
                            Text(String(format: "%.0f%%", intensity * 100))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $intensity, in: 0.0...1.0, step: 0.05)
                            .onChange(of: intensity) { _, _ in
                                previewImage = nil
                                savedPath = nil
                            }
                    }

                    Text("Controls the blend between watercolor stylization and original image. 50% is recommended for painting reference.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var generateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button {
                Task { await generate() }
            } label: {
                HStack(spacing: 8) {
                    if isGenerating {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isGenerating ? "Generating…" : "Generate")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isGenerating || isSaving)
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preview")
                .font(.headline)

            if let preview = previewImage {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 280)
                    .cornerRadius(12)
                    .transition(.opacity)
            } else if isGenerating {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(height: 200)
                    ProgressView("Applying filters…")
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.secondary.opacity(0.08))
                        .frame(height: 200)
                    VStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                        Text("Tap Generate to preview")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var saveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let path = savedPath {
                Text("Saved: \((path as NSString).lastPathComponent)")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Button {
                Task { await saveToOutputs() }
            } label: {
                HStack(spacing: 8) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Image(systemName: "square.and.arrow.down")
                    Text(isSaving ? "Saving…" : "Save to Outputs")
                }
            }
            .buttonStyle(.bordered)
            .disabled(isSaving || isGenerating || savedPath != nil)
        }
    }

    // MARK: - Actions

    private func generate() async {
        guard let db = appDatabase else {
            errorMessage = "Database not available."
            return
        }
        isGenerating = true
        errorMessage = nil
        savedPath = nil

        do {
            let image = try await viewModel.generateRendering(
                photoId: photo.id,
                style: renderingStyle,
                intensity: renderingStyle == "watercolor" ? intensity : nil,
                highContrast: renderingStyle == "lineArt" ? highContrast : nil,
                db: db
            )
            previewImage = image
        } catch {
            errorMessage = error.localizedDescription
        }

        isGenerating = false
    }

    private func saveToOutputs() async {
        guard let db = appDatabase, let image = previewImage else { return }
        isSaving = true

        do {
            let path = try await viewModel.saveRenderingToOutputs(
                image,
                photoId: photo.id,
                style: renderingStyle,
                db: db
            )
            savedPath = path
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }

        isSaving = false
    }
}
