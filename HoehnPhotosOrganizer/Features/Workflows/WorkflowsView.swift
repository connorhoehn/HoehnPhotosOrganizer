import SwiftUI
import CoreImage
import GRDB

// MARK: - WorkflowTemplate

enum WorkflowTemplate: String, CaseIterable, Identifiable {
    // Image transforms
    case rotateLeft      = "rotate_left"
    case rotateRight     = "rotate_right"
    case flipHorizontal  = "flip_horizontal"
    case flipVertical    = "flip_vertical"
    case grayscale       = "grayscale"
    case autoOrient      = "auto_orient"
    // AI
    case detectFaces     = "detect_faces"
    // Film
    case splitFilmStrip  = "split_film_strip"
    // Metadata (Claude Haiku — no image sent)
    case location        = "location"
    case gear            = "gear"
    case date            = "date"
    case filmStock       = "film_stock"
    case lighting        = "lighting"
    case editorial       = "editorial"

    var id: String { rawValue }

    /// True for metadata workflows — require text input and call Claude.
    var isMetadata: Bool {
        switch self {
        case .location, .gear, .date, .filmStock, .lighting, .editorial: true
        default: false
        }
    }

    /// True for workflows that open an interactive sheet rather than running inline.
    var isInteractive: Bool { self == .splitFilmStrip }

    var metadataKind: MetadataWorkflowKind? {
        switch self {
        case .location:  .location
        case .gear:      .gear
        case .date:      .date
        case .filmStock: .filmStock
        case .lighting:  .lighting
        case .editorial: .editorial
        default: nil
        }
    }

    /// True for AI workflows that run their own processing loop (not CIImage transforms).
    var isAI: Bool { self == .detectFaces }

    var displayName: String {
        switch self {
        case .rotateLeft:      "Rotate Left 90°"
        case .rotateRight:     "Rotate Right 90°"
        case .flipHorizontal:  "Flip Horizontal"
        case .flipVertical:    "Flip Vertical"
        case .grayscale:       "Grayscale"
        case .autoOrient:      "Auto-Orient"
        case .detectFaces:     "Detect Faces"
        case .splitFilmStrip:  "Split Film Strip"
        case .location:        "Location"
        case .gear:            "Gear"
        case .date:            "Date"
        case .filmStock:       "Film Stock"
        case .lighting:        "Lighting"
        case .editorial:       "Editorial Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .rotateLeft:     "rotate.left"
        case .rotateRight:    "rotate.right"
        case .flipHorizontal: "arrow.left.and.right"
        case .flipVertical:   "arrow.up.and.down"
        case .grayscale:      "circle.lefthalf.filled"
        case .autoOrient:     "sparkles"
        case .detectFaces:    "person.crop.rectangle"
        case .splitFilmStrip: "film.stack"
        case .location:       "location.fill"
        case .gear:           "camera.fill"
        case .date:           "calendar"
        case .filmStock:      "film.fill"
        case .lighting:       "sun.max.fill"
        case .editorial:      "text.bubble.fill"
        }
    }

    var actionDescription: String {
        switch self {
        case .rotateLeft:     "Rotate 90° counter-clockwise"
        case .rotateRight:    "Rotate 90° clockwise"
        case .flipHorizontal: "Mirror horizontally"
        case .flipVertical:   "Mirror vertically"
        case .grayscale:      "Convert to grayscale"
        case .autoOrient:     "Detect and correct orientation with ML"
        case .detectFaces:    "Index faces for the People gallery"
        case .splitFilmStrip: "Extract frames into individual library photos"
        case .location:       "Tag location via Haiku — no image sent"
        case .gear:           "Log camera, lens, film, settings"
        case .date:           "Set date, time, season"
        case .filmStock:      "Tag film stock and process"
        case .lighting:       "Log lighting conditions"
        case .editorial:      "Comprehensive shoot notes"
        }
    }

    var inputPlaceholder: String {
        switch self {
        case .location:  "e.g. Louvre, Paris · Montmartre · rue de Rivoli"
        case .gear:      "e.g. Leica M7, Summilux 1.4 · Kodak TMX 400 · sunny afternoon Paris"
        case .date:      "e.g. February 11 2024 · around noon · rainy winter day"
        case .filmStock: "e.g. Kodak Portra 400 · Ilford HP5 · Fuji Velvia 50"
        case .lighting:  "e.g. golden hour backlight · indoor tungsten · overcast soft box"
        case .editorial: "Describe the shoot — location, gear, mood, people, anything"
        default: ""
        }
    }
}

// MARK: - WorkflowPhotoResult

struct WorkflowPhotoResult: Identifiable {
    let id: String          // photoId
    let photoName: String
    let success: Bool
    let error: String?
}

// MARK: - WorkflowsView

struct WorkflowsView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.appDatabase) private var appDatabase: AppDatabase?

    @State private var selectedTemplate: WorkflowTemplate?
    @State private var status: WorkflowStatus = .idle
    @State private var results: [WorkflowPhotoResult] = []
    @State private var processedCount: Int = 0
    @State private var statusError: String = ""
    // Metadata workflow state
    @State private var metadataInput: String = ""
    @State private var metadataResult: UserMetadata? = nil
    @State private var metadataProgressPhase: MetadataProgressPhase = .sending

    enum MetadataProgressPhase: String {
        case sending   = "Sending to Claude Haiku…"
        case waiting   = "Waiting for response…"
        case parsing   = "Parsing metadata…"
    }
    @State private var presetName: String = ""
    @State private var showingSavePreset: Bool = false
    @StateObject private var presetStore = WorkflowPresetStore()
    @State private var filmExtractURL: URL? = nil   // triggers Split Film Strip sheet
    @State private var filmFileUnavailable: String? = nil  // set to filename when source file is missing
    @State private var showDustRemoval = false
    @State private var currentTask: Task<Void, Never>? = nil

    enum WorkflowStatus: Equatable {
        case idle, running, metadataReview, complete, failed
    }

    private var workingPhotos: [PhotoAsset] {
        viewModel.workflowPhotoIDs.compactMap { id in
            viewModel.photos.first(where: { $0.id == id })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.workflowPhotoIDs.isEmpty {
                emptyState
            } else {
                photoStrip
                Divider()
                commandArea
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: Binding(
            get: { filmExtractURL != nil },
            set: { if !$0 { filmExtractURL = nil } }
        )) {
            if let url = filmExtractURL {
                LibraryFilmExtractorSheet(sourceURL: url) {
                    filmExtractURL = nil
                }
            }
        }
        .sheet(isPresented: $showDustRemoval) {
            BatchDustRemovalView(photoIds: viewModel.workflowPhotoIDs)
        }
        .alert(
            "Original File Not Available",
            isPresented: Binding(
                get: { filmFileUnavailable != nil },
                set: { if !$0 { filmFileUnavailable = nil } }
            ),
            presenting: filmFileUnavailable
        ) { _ in
            Button("OK") { filmFileUnavailable = nil }
        } message: { filename in
            Text("\"\(filename)\" cannot be opened. Connect the drive that contains this file, then try again.")
        }
    }

    // MARK: - Photo Strip

    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(workingPhotos) { photo in
                    WorkflowPhotoTile(
                        photo: photo,
                        result: results.first(where: { $0.id == photo.id }),
                        isRunning: status == .running
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(height: 116)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: - Command Area

    @ViewBuilder
    private var commandArea: some View {
        switch status {
        case .idle:           idleContent
        case .running:        runningContent
        case .metadataReview: metadataReviewContent
        case .complete:       completeContent
        case .failed:         errorContent
        }
    }

    private var idleContent: some View {
        let transforms = WorkflowTemplate.allCases.filter { !$0.isMetadata && !$0.isInteractive && !$0.isAI }
        let ai         = WorkflowTemplate.allCases.filter { $0.isAI }
        let film       = WorkflowTemplate.allCases.filter { $0.isInteractive }
        let metadata   = WorkflowTemplate.allCases.filter { $0.isMetadata }
        let isMetadataSelected = selectedTemplate?.isMetadata == true
        let isInteractiveSelected = selectedTemplate?.isInteractive == true
        let canRun = selectedTemplate != nil
            && (!isMetadataSelected || !metadataInput.trimmingCharacters(in: .whitespaces).isEmpty)
            && (!isInteractiveSelected || workingPhotos.count == 1)

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What do you want to do?")
                    .font(.title3.weight(.semibold))
                Text("\(viewModel.workflowPhotoIDs.count) photo\(viewModel.workflowPhotoIDs.count == 1 ? "" : "s") selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Image transforms
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Image Transforms")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 24)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
                            ForEach(transforms) { template in
                                WorkflowTemplateButton(template: template, isSelected: selectedTemplate == template) {
                                    selectedTemplate = template
                                    metadataInput = ""
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                    }

                    // AI workflows
                    VStack(alignment: .leading, spacing: 8) {
                        Text("AI")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 24)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
                            ForEach(ai) { template in
                                WorkflowTemplateButton(template: template, isSelected: selectedTemplate == template) {
                                    selectedTemplate = template
                                    metadataInput = ""
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                    }

                    // Film workflows
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Film")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 24)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
                            ForEach(film) { template in
                                WorkflowTemplateButton(
                                    template: template,
                                    isSelected: selectedTemplate == template,
                                    badge: workingPhotos.count != 1 ? "1 photo only" : nil
                                ) {
                                    selectedTemplate = template
                                    metadataInput = ""
                                }
                            }

                            // Standalone dust removal action
                            Button {
                                showDustRemoval = true
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "sparkle.magnifyingglass")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.orange)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Dust Removal")
                                            .font(.system(size: 13, weight: .medium))
                                        Text("Detect & remove film dust and hair")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.primary.opacity(0.04))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 24)
                    }

                    // Metadata workflows
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Metadata — powered by Claude Haiku, no image sent")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 24)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
                            ForEach(metadata) { template in
                                WorkflowTemplateButton(template: template, isSelected: selectedTemplate == template) {
                                    selectedTemplate = template
                                    metadataInput = ""
                                }
                            }
                        }
                        .padding(.horizontal, 24)

                        // Saved presets for selected metadata type
                        if let template = selectedTemplate, template.isMetadata,
                           let kind = template.metadataKind {
                            let kindPresets = presetStore.presets(for: kind)
                            if !kindPresets.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Saved Presets")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 8) {
                                            ForEach(kindPresets) { preset in
                                                Button {
                                                    metadataInput = preset.inputText
                                                } label: {
                                                    Text(preset.name)
                                                        .font(.caption.weight(.medium))
                                                        .padding(.horizontal, 10)
                                                        .padding(.vertical, 5)
                                                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                                        .foregroundStyle(Color.accentColor)
                                                }
                                                .buttonStyle(.plain)
                                                .contextMenu {
                                                    Button(role: .destructive) {
                                                        presetStore.delete(id: preset.id)
                                                    } label: { Label("Delete Preset", systemImage: "trash") }
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 24)
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Divider()
                HStack(spacing: 10) {
                    if isMetadataSelected {
                        TextField(selectedTemplate?.inputPlaceholder ?? "Describe what you want to do…", text: $metadataInput)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { if canRun { runWorkflow() } }
                    } else {
                        TextField("Select a workflow above…", text: .constant(""))
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)
                            .opacity(0.45)
                    }
                    Button {
                        runWorkflow()
                    } label: {
                        Label("Run", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRun)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var runningContent: some View {
        VStack(spacing: 14) {
            Spacer()
            if selectedTemplate?.isMetadata == true {
                // Metadata workflow: single API call with phased progress
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.4)
                    Text(metadataProgressPhase.rawValue)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .animation(.easeInOut, value: metadataProgressPhase)

                    // Show the input being sent
                    if !metadataInput.isEmpty {
                        Text("\"\(metadataInput)\"")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .padding(.horizontal, 40)
                    }
                }
            } else {
                ProgressView()
                    .scaleEffect(1.4)
                Text("Processing \(processedCount) of \(viewModel.workflowPhotoIDs.count)…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                cancelCurrentWorkflow()
            } label: {
                Label("Stop Workflow", systemImage: "stop.circle.fill")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Stop the running workflow (Esc)")
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func cancelCurrentWorkflow() {
        currentTask?.cancel()
        currentTask = nil
        status = .idle
        processedCount = 0
        results = []
        metadataProgressPhase = .sending
    }

    private var completeContent: some View {
        let succeeded = results.filter { $0.success }.count
        let failed    = results.filter { !$0.success }.count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Done — \(succeeded) updated\(failed > 0 ? ", \(failed) failed" : "")")
                        .font(.headline)
                    if let t = selectedTemplate {
                        Text(t.actionDescription + " applied to proxy images")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("New Workflow") {
                    results = []
                    selectedTemplate = nil
                    processedCount = 0
                    metadataInput = ""
                    metadataResult = nil
                    showingSavePreset = false
                    status = .idle
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Back to Library") {
                    viewModel.selectedSection = .library
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color.green.opacity(0.06))

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(results) { result in
                        HStack(spacing: 10) {
                            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result.success ? .green : .red)
                                .font(.system(size: 14))
                            Text(result.photoName)
                                .font(.system(size: 13))
                                .lineLimit(1)
                            Spacer()
                            if let err = result.error {
                                Text(err)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                        Divider().padding(.leading, 48)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Metadata Review

    @ViewBuilder
    private var metadataReviewContent: some View {
        if let result = metadataResult {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: selectedTemplate?.systemImage ?? "sparkles")
                        .foregroundStyle(Color.accentColor)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Claude extracted this metadata")
                            .font(.headline)
                        Text("Review before applying to \(workingPhotos.count) photo\(workingPhotos.count == 1 ? "" : "s")")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit Input") {
                        status = .idle
                        metadataResult = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(Color.accentColor.opacity(0.06))

                Divider()

                // Field preview
                ScrollView {
                    VStack(spacing: 0) {
                        let rows = result.displayRows
                        if rows.isEmpty {
                            Text("No metadata fields were extracted from your input.")
                                .foregroundStyle(.secondary)
                                .padding(24)
                        } else {
                            ForEach(rows, id: \.label) { row in
                                HStack(spacing: 16) {
                                    Text(row.label)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 90, alignment: .trailing)
                                    Text(row.value)
                                        .font(.system(size: 13))
                                    Spacer()
                                }
                                .padding(.horizontal, 24)
                                .padding(.vertical, 10)
                                Divider().padding(.leading, 130)
                            }
                        }
                    }
                }

                Divider()

                // Actions
                VStack(spacing: 10) {
                    if showingSavePreset {
                        HStack(spacing: 8) {
                            TextField("Preset name…", text: $presetName)
                                .textFieldStyle(.roundedBorder)
                            Button("Save") {
                                guard !presetName.trimmingCharacters(in: .whitespaces).isEmpty,
                                      let kind = selectedTemplate?.metadataKind else { return }
                                let preset = WorkflowPreset(
                                    id: UUID().uuidString,
                                    name: presetName.trimmingCharacters(in: .whitespaces),
                                    workflowType: kind.rawValue,
                                    inputText: metadataInput,
                                    metadata: result,
                                    createdAt: Date()
                                )
                                presetStore.save(preset)
                                presetName = ""
                                showingSavePreset = false
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                            Button("Cancel") {
                                presetName = ""
                                showingSavePreset = false
                            }
                            .buttonStyle(.plain)
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 20)
                    }
                    HStack(spacing: 10) {
                        if !showingSavePreset && selectedTemplate?.isMetadata == true {
                            Button {
                                showingSavePreset = true
                            } label: {
                                Label("Save as Preset", systemImage: "square.and.arrow.down")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        Spacer()
                        Button("Back") {
                            status = .idle
                            metadataResult = nil
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button("Apply to \(workingPhotos.count) photo\(workingPhotos.count == 1 ? "" : "s")") {
                            applyMetadata(result)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func applyMetadata(_ meta: UserMetadata) {
        let photosSnapshot = workingPhotos
        let photoRepo = viewModel.photoRepo
        let templateName = selectedTemplate?.displayName ?? "Metadata"

        print("[MetadataWorkflow] applyMetadata called — \(photosSnapshot.count) photos, template: \(templateName)")

        status = .running
        processedCount = 0
        results = []

        Task {
            var updates: [String: String] = [:]
            var jobResults: [WorkflowPhotoResult] = []

            for photo in photosSnapshot {
                let existing = UserMetadata.decode(from: photo.userMetadataJson) ?? UserMetadata()
                let merged = existing.merging(meta)
                if let json = merged.jsonString() {
                    updates[photo.id] = json
                    jobResults.append(.init(id: photo.id, photoName: photo.canonicalName, success: true, error: nil))
                } else {
                    jobResults.append(.init(id: photo.id, photoName: photo.canonicalName, success: false, error: "Encode failed"))
                }
            }

            print("[MetadataWorkflow] writing \(updates.count) updates to DB...")
            do {
                try await photoRepo.bulkUpdateUserMetadata(updates)
                print("[MetadataWorkflow] ✓ DB write complete")
            } catch {
                print("[MetadataWorkflow] ✗ DB write failed: \(error)")
                await MainActor.run {
                    statusError = error.localizedDescription
                    status = .failed
                }
                return
            }

            // Log activity
            if let db = appDatabase {
                let succeeded = jobResults.filter { $0.success }.count
                let entry = ActivityDB(
                    id: UUID().uuidString,
                    kind: ActivityKind.workflowGenerated.rawValue,
                    title: "Workflow: \(templateName)",
                    detail: "Metadata applied to \(succeeded) of \(photosSnapshot.count) photo\(photosSnapshot.count == 1 ? "" : "s")",
                    photoId: photosSnapshot.count == 1 ? photosSnapshot[0].id : nil,
                    timestamp: ISO8601DateFormatter().string(from: Date())
                )
                try? await db.dbPool.write { database in try entry.insert(database) }
            }

            await MainActor.run {
                results = jobResults
                status = .complete
            }
        }
    }

    private var errorContent: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title)
            Text(statusError.isEmpty ? "Something went wrong." : statusError)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                status = .idle
                statusError = ""
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No photos selected")
                .font(.title3.weight(.semibold))
            Text("Select photos in the library, then tap Workflow in the action bar.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Execute

    private func runWorkflow() {
        guard let template = selectedTemplate, !workingPhotos.isEmpty else { return }

        // Interactive workflows → open a sheet
        if template == .splitFilmStrip, let photo = workingPhotos.first {
            let url = URL(fileURLWithPath: photo.filePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                filmFileUnavailable = photo.canonicalName
                return
            }
            filmExtractURL = url
            return
        }

        // Metadata workflows → call Haiku, show review before applying
        if template.isMetadata, let kind = template.metadataKind {
            let input = metadataInput.trimmingCharacters(in: .whitespaces)
            guard !input.isEmpty else { return }
            metadataProgressPhase = .sending
            status = .running
            currentTask = Task {
                do {
                    let service = MetadataWorkflowService()
                    // Advance to "waiting" after a brief moment so user sees the phase change
                    try await Task.sleep(for: .milliseconds(300))
                    await MainActor.run { metadataProgressPhase = .waiting }
                    let meta = try await service.run(kind: kind, input: input)
                    await MainActor.run { metadataProgressPhase = .parsing }
                    try await Task.sleep(for: .milliseconds(200))
                    await MainActor.run {
                        metadataResult = meta
                        status = .metadataReview
                    }
                } catch is CancellationError {
                    // Cancelled by user — idle state is already set by cancelCurrentWorkflow()
                } catch {
                    await MainActor.run {
                        statusError = error.localizedDescription
                        status = .failed
                    }
                }
            }
            return
        }

        status = .running
        processedCount = 0
        results = []

        let photosSnapshot = workingPhotos
        let db = appDatabase
        let ciContext = CIContext()
        let templateName = template.displayName
        let templateDesc = template.actionDescription

        // Face detection workflow — runs its own pipeline
        if template == .detectFaces {
            currentTask = Task {
                guard let db else { return }
                let faceRepo = FaceEmbeddingRepository(db: db)
                let photoRepo = PhotoRepository(db: db)
                var jobResults: [WorkflowPhotoResult] = []

                for photo in photosSnapshot {
                    let baseName = (photo.canonicalName as NSString).deletingPathExtension
                    let proxyURL = ProxyGenerationActor.proxiesDirectory()
                        .appendingPathComponent(baseName + ".jpg")

                    guard FileManager.default.fileExists(atPath: proxyURL.path) else {
                        jobResults.append(.init(id: photo.id, photoName: photo.canonicalName, success: false, error: "Proxy not found"))
                        await MainActor.run { processedCount += 1 }
                        continue
                    }

                    // Delete existing embeddings for this photo to avoid duplicates
                    try? await faceRepo.deleteByPhotoId(photo.id)

                    let crops = await Task.detached(priority: .userInitiated) {
                        FaceChipGrid.detectAndCropWithBounds(from: proxyURL)
                    }.value

                    let now = ISO8601DateFormatter().string(from: Date())
                    var faceCount = 0
                    for (index, pair) in crops.enumerated() {
                        let (cropImage, bbox) = pair
                        guard let cgImage = cropImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
                              let featureData = FaceEmbeddingService.generateFeaturePrint(for: cgImage) else { continue }
                        let record = FaceEmbedding(
                            id: UUID().uuidString,
                            photoId: photo.id,
                            faceIndex: index,
                            bboxX: bbox.minX, bboxY: bbox.minY, bboxWidth: bbox.width, bboxHeight: bbox.height,
                            featureData: featureData,
                            createdAt: now,
                            personId: nil,
                            labeledBy: nil,
                            needsReview: false
                        )
                        try? await faceRepo.upsert(record)
                        faceCount += 1
                    }

                    // Stamp faceIndexedAt regardless of face count
                    try? await photoRepo.markFaceIndexed(id: photo.id)

                    jobResults.append(.init(
                        id: photo.id,
                        photoName: photo.canonicalName,
                        success: true,
                        error: faceCount == 0 ? "No faces found" : nil
                    ))
                    await MainActor.run { processedCount += 1 }
                }

                // Log activity
                let withFaces = jobResults.filter { $0.error == nil }.count
                let entry = ActivityDB(
                    id: UUID().uuidString,
                    kind: ActivityKind.workflowGenerated.rawValue,
                    title: "Workflow: Detect Faces",
                    detail: "Indexed faces in \(withFaces) of \(photosSnapshot.count) photo\(photosSnapshot.count == 1 ? "" : "s")",
                    photoId: photosSnapshot.count == 1 ? photosSnapshot[0].id : nil,
                    timestamp: ISO8601DateFormatter().string(from: Date())
                )
                try? await db.dbPool.write { database in try entry.insert(database) }

                await MainActor.run {
                    results = jobResults
                    status = .complete
                }
            }
            return
        }

        currentTask = Task {
            let fm = FileManager.default
            let proxyDir = ProxyGenerationActor.proxiesDirectory()
            var jobResults: [WorkflowPhotoResult] = []

            if template == .autoOrient {
                let classifier = OrientationClassificationService()
                for photo in photosSnapshot {
                    let baseName = (photo.canonicalName as NSString).deletingPathExtension
                    let proxyURL = proxyDir.appendingPathComponent(baseName + ".jpg")

                    guard fm.fileExists(atPath: proxyURL.path) else {
                        jobResults.append(.init(id: photo.id, photoName: photo.canonicalName, success: false, error: "Proxy not found"))
                        await MainActor.run { processedCount += 1 }
                        continue
                    }

                    let orient = await classifier.classify(proxyURL: proxyURL)

                    if orient.rotationDegrees == 0 {
                        jobResults.append(.init(id: photo.id, photoName: photo.canonicalName, success: true, error: nil))
                    } else if let input = CIImage(contentsOf: proxyURL),
                              let cs = CGColorSpace(name: CGColorSpace.sRGB),
                              let data = ciContext.jpegRepresentation(
                                  of: Self.applyCWDegrees(orient.rotationDegrees, to: input),
                                  colorSpace: cs, options: [:]
                              ) {
                        do {
                            try data.write(to: proxyURL, options: .atomic)
                            jobResults.append(.init(id: photo.id, photoName: photo.canonicalName, success: true, error: nil))
                        } catch {
                            jobResults.append(.init(id: photo.id, photoName: photo.canonicalName, success: false, error: error.localizedDescription))
                        }
                    } else {
                        jobResults.append(.init(id: photo.id, photoName: photo.canonicalName, success: false, error: "Render failed"))
                    }

                    await MainActor.run { processedCount += 1 }
                }
            } else {
            for photo in photosSnapshot {
                let baseName = (photo.canonicalName as NSString).deletingPathExtension
                let proxyURL = proxyDir.appendingPathComponent(baseName + ".jpg")

                do {
                    guard fm.fileExists(atPath: proxyURL.path) else {
                        jobResults.append(.init(id: photo.id, photoName: photo.canonicalName, success: false, error: "Proxy not found"))
                        await MainActor.run { processedCount += 1 }
                        continue
                    }
                    guard let input = CIImage(contentsOf: proxyURL) else {
                        jobResults.append(.init(id: photo.id, photoName: photo.canonicalName, success: false, error: "Unreadable image"))
                        await MainActor.run { processedCount += 1 }
                        continue
                    }

                    let output = Self.applyTransform(template, to: input)

                    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
                          let data = ciContext.jpegRepresentation(of: output, colorSpace: cs, options: [:]) else {
                        jobResults.append(.init(id: photo.id, photoName: photo.canonicalName, success: false, error: "Render failed"))
                        await MainActor.run { processedCount += 1 }
                        continue
                    }

                    try data.write(to: proxyURL, options: .atomic)
                    jobResults.append(.init(id: photo.id, photoName: photo.canonicalName, success: true, error: nil))
                } catch {
                    jobResults.append(.init(id: photo.id, photoName: photo.canonicalName, success: false, error: error.localizedDescription))
                }

                await MainActor.run { processedCount += 1 }
            }
            }

            // Log to activity
            if let db {
                let succeeded = jobResults.filter { $0.success }.count
                let entry = ActivityDB(
                    id: UUID().uuidString,
                    kind: ActivityKind.workflowGenerated.rawValue,
                    title: "Workflow: \(templateName)",
                    detail: "\(templateDesc) applied to \(succeeded) of \(photosSnapshot.count) photo\(photosSnapshot.count == 1 ? "" : "s")",
                    photoId: photosSnapshot.count == 1 ? photosSnapshot[0].id : nil,
                    timestamp: ISO8601DateFormatter().string(from: Date())
                )
                try? await db.dbPool.write { database in
                    try entry.insert(database)
                }
            }

            let finalResults = jobResults
            await MainActor.run {
                results = finalResults
                status = .complete
            }
        }
    }

    // MARK: - Image Transforms

    nonisolated static func applyTransform(_ template: WorkflowTemplate, to image: CIImage) -> CIImage {
        let w = image.extent.width
        let h = image.extent.height
        switch template {
        case .rotateLeft:
            // 90° CCW: rotate then translate right by original height
            return image.transformed(by:
                CGAffineTransform(rotationAngle: .pi / 2)
                    .concatenating(CGAffineTransform(translationX: h, y: 0))
            )
        case .rotateRight:
            // 90° CW: rotate then translate up by original width
            return image.transformed(by:
                CGAffineTransform(rotationAngle: -.pi / 2)
                    .concatenating(CGAffineTransform(translationX: 0, y: w))
            )
        case .flipHorizontal:
            return image.transformed(by:
                CGAffineTransform(scaleX: -1, y: 1)
                    .concatenating(CGAffineTransform(translationX: w, y: 0))
            )
        case .flipVertical:
            return image.transformed(by:
                CGAffineTransform(scaleX: 1, y: -1)
                    .concatenating(CGAffineTransform(translationX: 0, y: h))
            )
        case .grayscale:
            return image.applyingFilter("CIPhotoEffectMono")
        case .autoOrient, .detectFaces, .splitFilmStrip, .location, .gear, .date, .filmStock, .lighting, .editorial:
            return image  // handled separately — not CIImage transforms
        }
    }

    /// Apply a clockwise rotation of `degrees` (90/180/270) to a CIImage, translating
    /// so the result origin stays at (0,0).
    nonisolated static func applyCWDegrees(_ degrees: Int, to image: CIImage) -> CIImage {
        let w = image.extent.width
        let h = image.extent.height
        switch degrees {
        case 90:   // 90° CW
            return image.transformed(by:
                CGAffineTransform(rotationAngle: -.pi / 2)
                    .concatenating(CGAffineTransform(translationX: 0, y: w)))
        case 180:
            return image.transformed(by:
                CGAffineTransform(rotationAngle: .pi)
                    .concatenating(CGAffineTransform(translationX: w, y: h)))
        case 270:  // 270° CW = 90° CCW
            return image.transformed(by:
                CGAffineTransform(rotationAngle: .pi / 2)
                    .concatenating(CGAffineTransform(translationX: h, y: 0)))
        default:
            return image
        }
    }
}

// MARK: - WorkflowPhotoTile

private struct WorkflowPhotoTile: View {
    let photo: PhotoAsset
    let result: WorkflowPhotoResult?
    let isRunning: Bool
    @State private var proxyImage: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = proxyImage {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(.linearGradient(
                            colors: photo.placeholderGradient,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.white.opacity(0.6))
                        }
                }
            }
            .frame(width: 88, height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            )

            if isRunning && result == nil {
                ProgressView()
                    .scaleEffect(0.65)
                    .padding(3)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(4)
            } else if let result {
                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result.success ? .green : .red)
                    .font(.system(size: 16, weight: .semibold))
                    .shadow(radius: 1)
                    .padding(4)
            }
        }
        .task {
            let baseName = (photo.canonicalName as NSString).deletingPathExtension
            let url = ProxyGenerationActor.proxiesDirectory().appendingPathComponent(baseName + ".jpg")
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            proxyImage = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: url)
            }.value
        }
    }
}

// MARK: - WorkflowTemplateButton

private struct WorkflowTemplateButton: View {
    let template: WorkflowTemplate
    let isSelected: Bool
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: template.systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 30, alignment: .center)
                    .foregroundStyle(isSelected ? .white : .primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : .primary)
                    Text(template.actionDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .white.opacity(0.75) : .secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
            )
        }
        .buttonStyle(.plain)
        .opacity(badge != nil ? 0.5 : 1)
        .overlay(alignment: .topTrailing) {
            if let badge {
                Text(badge)
                    .font(.system(size: 8, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.85)))
                    .foregroundStyle(.white)
                    .padding(6)
            }
        }
    }
}

// MARK: - LibraryFilmExtractorSheet

/// Presents the detect → review → import pipeline for a photo already in the library.
/// Reuses the same `FilmStripDetectingView` + `FrameReviewView` flow.
struct LibraryFilmExtractorSheet: View {

    let sourceURL: URL
    let onDismiss: () -> Void

    @Environment(\.appDatabase) private var appDatabase
    @Environment(\.activityEventService) private var activityEventService

    private enum Phase {
        case detecting
        case reviewing([DetectedFrame])
        case failed(String)
    }

    @State private var phase: Phase = .detecting

    var body: some View {
        Group {
            switch phase {
            case .detecting:
                VStack(spacing: 20) {
                    ProgressView().scaleEffect(1.5)
                    Text("Detecting film frames…")
                        .font(.title3).foregroundStyle(.secondary)
                    Text(sourceURL.lastPathComponent)
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(width: 360, height: 240)

            case .reviewing(let frames):
                FrameReviewView(
                    template: .filmScans,
                    frames: frames,
                    onImport: { _ in onDismiss() },
                    onBack: { onDismiss() }
                )
                .frame(minWidth: 800, minHeight: 600)

            case .failed(let msg):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36)).foregroundStyle(.orange)
                    Text("Frame Detection Failed").font(.title3.bold())
                    Text(msg).font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Close") { onDismiss() }.buttonStyle(.bordered)
                }
                .padding(40)
            }
        }
        .task { await prepareFrames() }
    }

    private func prepareFrames() async {
        guard YOLOFrameDetector.isAvailable else {
            await MainActor.run { phase = .failed("Film frame detection model is not available.") }
            return
        }
        let loadedImage = try? await Task.detached(priority: .userInitiated) {
            try FilmStripFrameExtractor.loadImage(at: sourceURL)
        }.value
        guard let cgImage = loadedImage else {
            await MainActor.run { phase = .failed("Could not load image at \(sourceURL.lastPathComponent).") }
            return
        }
        let rects = (try? await YOLOFrameDetector().detectFrames(in: cgImage)) ?? []
        guard !rects.isEmpty else {
            await MainActor.run { phase = .failed("No film frames detected in \(sourceURL.lastPathComponent).") }
            return
        }
        let frames = await Task.detached(priority: .userInitiated) {
            rects.enumerated().compactMap { index, rect -> DetectedFrame? in
                guard let thumb = FilmStripDetectingView.thumbnail(from: cgImage, rect: rect) else { return nil }
                return DetectedFrame(id: UUID(), sourceScanURL: sourceURL,
                                    cropRect: rect, thumbnail: thumb, frameIndex: index + 1)
            }
        }.value
        await MainActor.run { phase = .reviewing(frames) }
    }
}
