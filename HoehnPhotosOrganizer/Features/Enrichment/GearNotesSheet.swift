import SwiftUI

// MARK: - GearNotesSheet

/// Two-phase sheet for enriching a photo with technical gear metadata.
///
/// Phase 1 — Input: free-form text (camera, lens, settings, film stock, location).
/// Phase 2 — Review: structured fields parsed by Claude Haiku, editable before save.
/// On confirm: merged into `userMetadataJson` on the PhotoAsset via PhotoRepository.
struct GearNotesSheet: View {

    let photo: PhotoAsset
    let photoRepo: PhotoRepository
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    // MARK: State

    private enum Phase {
        case input
        case reviewing(GearNotesService.GearExtraction)
        case saving
    }

    @State private var phase: Phase = .input
    @State private var noteText: String = ""
    @State private var extractionError: String? = nil
    @State private var isExtracting = false

    // Editable review fields (populated after extraction)
    @State private var camera: String = ""
    @State private var lens: String = ""
    @State private var aperture: String = ""
    @State private var shutterSpeed: String = ""
    @State private var isoText: String = ""
    @State private var filmStock: String = ""
    @State private var location: String = ""
    @State private var keywords: String = ""
    @State private var userNotes: String = ""

    private let service = GearNotesService()

    // MARK: Body

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .input:
                    inputView
                case .reviewing:
                    reviewView
                case .saving:
                    savingView
                }
            }
            .navigationTitle("Gear & Context")
            .toolbar { toolbarItems }
        }
        .frame(minWidth: 480, minHeight: 520)
    }

    // MARK: - Phase 1: Input

    private var inputView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Photo context strip
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.linearGradient(
                        colors: photo.placeholderGradient,
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 44, height: 44)
                    .overlay { Image(systemName: "photo").foregroundStyle(.white.opacity(0.7)) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(photo.canonicalName)
                        .font(.headline).lineLimit(1).truncationMode(.middle)
                    Text("Describe anything you remember about this shot")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Your notes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)

                TextEditor(text: $noteText)
                    .font(.body)
                    .frame(minHeight: 200)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .padding(.horizontal, 20)
                    .overlay(alignment: .topLeading) {
                        if noteText.isEmpty {
                            Text("e.g. Shot this on the Leica M6 with a 35mm Summicron at f/8, Kodak Portra 400, Portland waterfront, dusk...")
                                .font(.body)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 30)
                                .padding(.top, 18)
                                .allowsHitTesting(false)
                        }
                    }

                Text("Claude will extract camera, lens, settings, film stock, and location — you review before saving.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }

            if let error = extractionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
            }

            Spacer()
        }
    }

    // MARK: - Phase 2: Review

    private var reviewView: some View {
        Form {
            Section("Camera & Lens") {
                TextField("Camera body", text: $camera)
                TextField("Lens", text: $lens)
            }

            Section("Exposure") {
                TextField("Aperture (e.g. f/5.6)", text: $aperture)
                TextField("Shutter speed (e.g. 1/250)", text: $shutterSpeed)
                TextField("ISO (number)", text: $isoText)
                TextField("Film stock", text: $filmStock)
            }

            Section("Context") {
                TextField("Location", text: $location)
                TextField("Keywords (comma separated)", text: $keywords)
                TextField("Additional notes", text: $userNotes, axis: .vertical)
                    .lineLimit(3...6)
            }

            Section {
                Text("Review and edit above before saving. These fields will be written to the photo's metadata record.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Saving spinner

    private var savingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Saving metadata…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if isReviewing {
                Button("Back") { phase = .input }
            } else {
                Button("Cancel") { dismiss() }
            }
        }

        ToolbarItem(placement: .confirmationAction) {
            if isInput {
                if isExtracting {
                    ProgressView()
                } else {
                    Button("Extract") { Task { await runExtraction() } }
                        .bold()
                        .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else if isReviewing {
                Button("Save") { Task { await save() } }.bold()
            }
        }
    }

    private var isInput: Bool {
        if case .input = phase { return true }
        return false
    }

    private var isReviewing: Bool {
        if case .reviewing = phase { return true }
        return false
    }

    // MARK: - Actions

    private func runExtraction() async {
        isExtracting = true
        extractionError = nil

        do {
            let result = try await service.extract(from: noteText)
            populateReviewFields(from: result)
            phase = .reviewing(result)
        } catch {
            extractionError = error.localizedDescription
        }

        isExtracting = false
    }

    private func populateReviewFields(from result: GearNotesService.GearExtraction) {
        camera = result.camera ?? ""
        lens = result.lens ?? ""
        aperture = result.aperture ?? ""
        shutterSpeed = result.shutterSpeed ?? ""
        isoText = result.iso.map { "\($0)" } ?? ""
        filmStock = result.filmStock ?? ""
        location = result.location ?? ""
        keywords = result.keywords.joined(separator: ", ")
        userNotes = result.userNotes ?? ""
    }

    private func save() async {
        phase = .saving

        let keywordList = keywords
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let extraction = GearNotesService.GearExtraction(
            camera: camera.nilIfEmpty,
            lens: lens.nilIfEmpty,
            aperture: aperture.nilIfEmpty,
            shutterSpeed: shutterSpeed.nilIfEmpty,
            iso: Int(isoText),
            filmStock: filmStock.nilIfEmpty,
            location: location.nilIfEmpty,
            keywords: keywordList,
            userNotes: userNotes.nilIfEmpty
        )

        // Merge with existing userMetadataJson — preserve any existing fields
        var merged = existingMetadata()
        if let camera = extraction.camera { merged["camera"] = camera }
        if let lens = extraction.lens { merged["lens"] = lens }
        if let aperture = extraction.aperture { merged["aperture"] = aperture }
        if let shutter = extraction.shutterSpeed { merged["shutter_speed"] = shutter }
        if let iso = extraction.iso { merged["iso"] = iso }
        if let film = extraction.filmStock { merged["film_stock"] = film }
        if let loc = extraction.location { merged["location"] = loc }
        if !extraction.keywords.isEmpty { merged["keywords"] = extraction.keywords }
        if let notes = extraction.userNotes { merged["user_notes"] = notes }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: merged),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            phase = .input
            extractionError = "Could not encode metadata for saving."
            return
        }

        var updated = photo
        updated.userMetadataJson = jsonString
        updated.updatedAt = ISO8601DateFormatter().string(from: .now)

        do {
            try await photoRepo.upsert(updated)
            onSaved()
            dismiss()
        } catch {
            phase = .reviewing(.init())
            extractionError = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Decode any existing `userMetadataJson` into a mutable dictionary for merging.
    private func existingMetadata() -> [String: Any] {
        guard let json = photo.userMetadataJson,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }
}

// MARK: - Helpers

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
