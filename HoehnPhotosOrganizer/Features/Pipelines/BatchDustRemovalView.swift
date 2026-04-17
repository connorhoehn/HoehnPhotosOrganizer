import SwiftUI
import os.log

private let log = Logger(subsystem: "HoehnPhotosOrganizer", category: "BatchDustRemoval")

// MARK: - BatchDustRemovalView

/// Batch processing view for running the dust/hair removal pipeline across
/// selected film scan photos. Shows real-time progress with per-image status
/// and summary statistics.
struct BatchDustRemovalView: View {
    let photoIds: [String]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDatabase) private var appDatabase: AppDatabase?

    // MARK: - State

    @State private var config = DustRemovalConfig()
    @State private var isRunning = false
    @State private var isDone = false
    @State private var progress: DustRemovalProgress?
    @State private var imageResults: [DustRemovalImageResult] = []
    @State private var showingSettings = false

    // MARK: - Computed

    private var totalArtifacts: Int {
        imageResults.reduce(0) { $0 + $1.artifactsDetected }
    }
    private var totalDust: Int {
        imageResults.reduce(0) { $0 + $1.dustCount }
    }
    private var totalHair: Int {
        imageResults.reduce(0) { $0 + $1.hairCount }
    }
    private var cleanedCount: Int {
        imageResults.filter { $0.outputPath != nil }.count
    }
    private var skippedCount: Int {
        imageResults.filter { $0.artifactsDetected == 0 && $0.error == nil }.count
    }
    private var failedCount: Int {
        imageResults.filter { $0.error != nil }.count
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header with availability status
                if !BatchDustRemovalPipeline.isAvailable {
                    modelWarningBanner
                }

                if !isRunning && !isDone {
                    configurationSection
                } else {
                    progressSection
                }
            }
            .navigationTitle("Film Dust Removal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(isRunning && !isDone)
                }
                if !isRunning && !isDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Start") { startProcessing() }
                            .disabled(!BatchDustRemovalPipeline.isAvailable || photoIds.isEmpty)
                    }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    // MARK: - Model Warning

    private var modelWarningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(BatchDustRemovalPipeline.availabilityReport)
                .font(.callout)
            Spacer()
        }
        .padding()
        .background(.orange.opacity(0.1))
    }

    // MARK: - Configuration

    private var configurationSection: some View {
        Form {
            Section("Input") {
                LabeledContent("Photos selected", value: "\(photoIds.count)")
            }

            Section("Detection") {
                HStack {
                    Text("Confidence threshold")
                    Spacer()
                    Slider(value: Binding(
                        get: { Double(config.confidenceThreshold) },
                        set: { config.confidenceThreshold = Float($0) }
                    ), in: 0.1...0.9, step: 0.05)
                    .frame(width: 150)
                    Text(String(format: "%.0f%%", config.confidenceThreshold * 100))
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }

                HStack {
                    Text("Mask dilation")
                    Spacer()
                    Stepper(
                        "\(config.dilationRadius) px",
                        value: $config.dilationRadius,
                        in: 2...32,
                        step: 2
                    )
                }
            }

            Section("Inpainting") {
                Picker("Model", selection: $config.inpaintingStrategy) {
                    Text("Auto (LaMa for dust, MAT for hair)")
                        .tag(InpaintingStrategy.auto)
                    Text("LaMa (fast, backgrounds)")
                        .tag(InpaintingStrategy.lama)
                    Text("MAT (faces, skin)")
                        .tag(InpaintingStrategy.mat)
                }

                HStack {
                    Text("Output JPEG quality")
                    Spacer()
                    Slider(value: $config.outputQuality, in: 0.7...1.0, step: 0.01)
                        .frame(width: 150)
                    Text(String(format: "%.0f%%", config.outputQuality * 100))
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }

            Section("Debug") {
                Toggle("Save detection overlays", isOn: $config.saveDebugOverlays)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(spacing: 16) {
            if let progress = progress {
                // Overall progress bar
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(progress.phase == .done || isDone
                             ? "Processing complete"
                             : "Processing: \(progress.currentPhotoName)")
                            .font(.headline)
                        Spacer()
                        Text("\(progress.completed)/\(progress.total)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                        .tint(progress.failed > 0 ? .orange : .blue)

                    HStack(spacing: 16) {
                        Label("\(progress.completed - progress.skipped) cleaned", systemImage: "sparkles")
                            .foregroundStyle(.green)
                        Label("\(progress.skipped) clean", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                        if progress.failed > 0 {
                            Label("\(progress.failed) failed", systemImage: "xmark.circle")
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.caption)
                }
                .padding()

                // Phase indicator
                if !isDone {
                    phaseIndicator(progress.phase)
                        .padding(.horizontal)
                }
            }

            // Summary stats (shown when complete)
            if isDone {
                summaryStatsView
                    .padding()
            }

            // Results list
            List(imageResults.indices, id: \.self) { i in
                imageResultRow(imageResults[i])
            }
        }
    }

    private func phaseIndicator(_ phase: DustRemovalProgress.Phase) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(phaseLabel(phase))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func phaseLabel(_ phase: DustRemovalProgress.Phase) -> String {
        switch phase {
        case .rendering:  return "Rendering DNG..."
        case .detecting:  return "Detecting dust & hair..."
        case .inpainting: return "Inpainting artifacts..."
        case .saving:     return "Saving cleaned image..."
        case .done:       return "Done"
        case .error:      return "Error"
        }
    }

    private var summaryStatsView: some View {
        HStack(spacing: 24) {
            VStack {
                Text("\(totalArtifacts)")
                    .font(.title2.bold())
                Text("Artifacts found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider().frame(height: 40)
            VStack {
                Text("\(totalDust)")
                    .font(.title2.bold())
                    .foregroundStyle(.orange)
                Text("Dust specks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider().frame(height: 40)
            VStack {
                Text("\(totalHair)")
                    .font(.title2.bold())
                    .foregroundStyle(.red)
                Text("Hair strands")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider().frame(height: 40)
            VStack {
                Text("\(cleanedCount)")
                    .font(.title2.bold())
                    .foregroundStyle(.green)
                Text("Cleaned")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private func imageResultRow(_ result: DustRemovalImageResult) -> some View {
        HStack {
            // Status icon
            Image(systemName: resultIcon(result))
                .foregroundStyle(resultColor(result))

            VStack(alignment: .leading, spacing: 2) {
                Text(result.photoName)
                    .font(.body)
                if result.artifactsDetected > 0 {
                    Text("\(result.dustCount) dust, \(result.hairCount) hair \u{2022} \(String(format: "%.1fs", result.inferenceTime))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let error = result.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("No artifacts detected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func resultIcon(_ result: DustRemovalImageResult) -> String {
        if result.error != nil { return "xmark.circle.fill" }
        if result.artifactsDetected == 0 { return "checkmark.circle" }
        return "sparkles"
    }

    private func resultColor(_ result: DustRemovalImageResult) -> Color {
        if result.error != nil { return .red }
        if result.artifactsDetected == 0 { return .secondary }
        return .green
    }

    // MARK: - Actions

    private func startProcessing() {
        isRunning = true

        guard let db = appDatabase else {
            log.error("BatchDustRemovalView: appDatabase not available in environment")
            isDone = true
            return
        }

        let outputDir = BatchDustRemovalPipeline.outputDirectory()
        let pipeline = BatchDustRemovalPipeline(config: config)

        Task {
            let photoRepo = PhotoRepository(db: db)
            let assets: [PhotoAsset]
            do {
                assets = try await photoRepo.fetchByIds(photoIds)
            } catch {
                log.error("Failed to fetch photo assets: \(error.localizedDescription)")
                isDone = true
                return
            }

            let fm = FileManager.default
            var photos: [(id: String, name: String, sourceURL: URL, proxyURL: URL?)] = []

            for asset in assets {
                let sourceURL = URL(fileURLWithPath: asset.filePath)
                guard fm.fileExists(atPath: sourceURL.path) else {
                    log.warning("Skipping photo \(asset.id) — source file missing: \(asset.filePath)")
                    continue
                }

                let proxyURL: URL? = asset.proxyPath.flatMap { path in
                    let url = URL(fileURLWithPath: path)
                    guard fm.fileExists(atPath: url.path) else {
                        log.warning("Proxy missing for \(asset.id), will use source: \(path)")
                        return nil
                    }
                    return url
                }

                photos.append((id: asset.id, name: asset.canonicalName, sourceURL: sourceURL, proxyURL: proxyURL))
            }

            guard !photos.isEmpty else {
                log.warning("No valid photos to process after filtering missing files")
                isDone = true
                return
            }

            let stream = pipeline.processPhotos(
                photos: photos,
                outputDirectory: outputDir,
                db: db
            )

            for await event in stream {
                progress = event
            }

            imageResults = await pipeline.imageResults
            isDone = true
        }
    }
}

// MARK: - Preview

#Preview {
    BatchDustRemovalView(photoIds: ["photo-1", "photo-2", "photo-3"])
}
