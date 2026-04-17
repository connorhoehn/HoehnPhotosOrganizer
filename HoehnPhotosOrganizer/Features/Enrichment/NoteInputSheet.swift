import SwiftUI
import AVFoundation

// MARK: - NoteInputSheet

/// Sheet for capturing a note on one or more photos (voice memo or typed text).
/// Calls Claude Haiku to generate a description + extract searchable metadata,
/// then saves both as thread entries on every target photo.
struct NoteInputSheet: View {

    // MARK: Dependencies

    let photoIds: [String]
    let db: AppDatabase
    @StateObject private var voiceMemoRecorder = VoiceMemoRecorder()
    private let transcriptionService = SpeechTranscriptionService()
    private let metadataExtractor = MetadataExtractor()
    private let noteService = AnthropicNoteService()

    // MARK: Convenience init for single photo

    init(photoId: String, db: AppDatabase) {
        self.photoIds = [photoId]
        self.db = db
        self._voiceMemoRecorder = StateObject(wrappedValue: VoiceMemoRecorder())
    }

    init(photoIds: [String], db: AppDatabase) {
        self.photoIds = photoIds
        self.db = db
        self._voiceMemoRecorder = StateObject(wrappedValue: VoiceMemoRecorder())
    }

    // MARK: State

    @State private var noteText: String = ""
    @State private var isTranscribing: Bool = false
    @State private var isExtracting: Bool = false
    @State private var isGenerating: Bool = false
    @State private var transcriptionError: String? = nil
    @State private var extractionError: OllamaError? = nil
    @State private var generationError: String? = nil
    @State private var extractedMetadata: MetadataExtractionResult? = nil
    @State private var showExtractionSheet: Bool = false
    @State private var analysis: AnthropicNoteService.NoteAnalysis? = nil
    @State private var inputMode: InputMode = .text

    @Environment(\.dismiss) private var dismiss

    enum InputMode {
        case text
        case voice
    }

    private var photoId: String { photoIds.first ?? "" }

    // MARK: Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if photoIds.count > 1 {
                    multiphotoNotice
                }

                modePickerBar

                Divider()

                Group {
                    if inputMode == .voice {
                        voiceRecordingView
                    } else {
                        textInputView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let a = analysis {
                    Divider()
                    analysisPreviewPanel(analysis: a)
                }

                Divider()

                bottomBar
            }
            .navigationTitle(photoIds.count > 1 ? "Add Note to \(photoIds.count) Photos" : "Add Note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showExtractionSheet) {
                if let metadata = extractedMetadata {
                    MetadataExtractionSheet(
                        photoId: photoId,
                        noteText: noteText,
                        extractedMetadata: metadata,
                        onConfirm: { dismiss() },
                        onDecline: { showExtractionSheet = false }
                    )
                }
            }
            .alert(
                "Metadata Extraction Unavailable",
                isPresented: Binding<Bool>(
                    get: { extractionError != nil },
                    set: { if !$0 { extractionError = nil } }
                )
            ) {
                Button("Retry") {
                    extractionError = nil
                    Task { await extractMetadata() }
                }
                Button("Manual Entry") {
                    extractionError = nil
                    Task { await saveRawNote() }
                }
                Button("Cancel", role: .cancel) {
                    extractionError = nil
                }
            } message: {
                Text(extractionErrorMessage)
            }
            .alert(
                "Claude Unavailable",
                isPresented: Binding<Bool>(
                    get: { generationError != nil },
                    set: { if !$0 { generationError = nil } }
                )
            ) {
                Button("Retry") {
                    generationError = nil
                    Task { await generateAnalysis() }
                }
                Button("OK", role: .cancel) {
                    generationError = nil
                }
            } message: {
                Text(generationError ?? "")
            }
        }
    }

    // MARK: - Subviews

    private var multiphotoNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo.stack.fill")
                .font(.caption)
                .foregroundStyle(.purple)
            Text("This note will be added to all \(photoIds.count) selected photos.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.purple.opacity(0.06))
    }

    private var modePickerBar: some View {
        Picker("Input mode", selection: $inputMode) {
            Label("Type Note", systemImage: "keyboard").tag(InputMode.text)
            Label("Voice Memo", systemImage: "mic").tag(InputMode.voice)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var voiceRecordingView: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(voiceMemoRecorder.isRecording ? Color.red.opacity(0.15) : Color.secondary.opacity(0.1))
                    .frame(width: 120, height: 120)

                Image(systemName: voiceMemoRecorder.isRecording ? "waveform" : "mic.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(voiceMemoRecorder.isRecording ? .red : .secondary)
                    .symbolEffect(.pulse, isActive: voiceMemoRecorder.isRecording)
            }

            if voiceMemoRecorder.isRecording {
                Text(formatDuration(voiceMemoRecorder.recordingDuration))
                    .font(.title2.monospacedDigit())
                    .foregroundStyle(.red)
            } else if voiceMemoRecorder.audioURL != nil {
                Label("Recording captured", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Text("Tap to start recording")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 24) {
                if voiceMemoRecorder.isRecording {
                    Button {
                        voiceMemoRecorder.stopRecording()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.bordered)
                } else if voiceMemoRecorder.audioURL != nil {
                    Button { } label: {
                        Label("Preview", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(true)

                    Button(role: .destructive) {
                        voiceMemoRecorder.stopRecording()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await transcribeRecording() }
                    } label: {
                        Label("Transcribe", systemImage: "text.bubble")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isTranscribing)
                } else {
                    Button {
                        Task {
                            do {
                                try await voiceMemoRecorder.startRecording()
                            } catch {
                                transcriptionError = error.localizedDescription
                            }
                        }
                    } label: {
                        Label("Record", systemImage: "mic.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if isTranscribing {
                ProgressView("Transcribing…")
                    .padding(.top, 8)
            }

            if let err = transcriptionError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if !noteText.isEmpty && voiceMemoRecorder.audioURL != nil {
                GroupBox("Transcribed Text (edit before confirming)") {
                    TextEditor(text: $noteText)
                        .frame(minHeight: 80)
                }
                .padding(.horizontal)
            }

            Spacer()
        }
        .padding()
    }

    private var textInputView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Describe this photo")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 12)

            TextEditor(text: $noteText)
                .font(.body)
                .padding(8)
                .background(Color(.textBackgroundColor))
                .cornerRadius(8)
                .padding(.horizontal)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text("\(noteText.count) characters")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
    }

    /// Purple preview panel shown after Claude analyses the note.
    private func analysisPreviewPanel(analysis: AnthropicNoteService.NoteAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.purple)
                Text("Claude's Description")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.purple)
                Spacer()
                Button {
                    self.analysis = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text(analysis.description)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            let chips = metadataChips(from: analysis.metadata)
            if !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chips, id: \.self) { chip in
                            Text(chip)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.purple.opacity(0.15)))
                                .foregroundStyle(.purple)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color.purple.opacity(0.07))
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Spacer()

            if isGenerating {
                ProgressView("Asking Claude…")
                    .padding(.trailing, 8)
            } else if isExtracting {
                ProgressView("Extracting metadata…")
                    .padding(.trailing, 8)
            } else if analysis != nil {
                Button {
                    Task { await saveNoteWithAnalysis() }
                } label: {
                    Label("Save to Thread", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
            } else {
                Button {
                    Task { await generateAnalysis() }
                } label: {
                    Label("Generate Description", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    Task { await extractMetadata() }
                } label: {
                    Label("Extract Tags", systemImage: "tag")
                }
                .buttonStyle(.bordered)
                .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
    }

    // MARK: - Helpers

    private func metadataChips(from meta: MetadataExtractionResult) -> [String] {
        var chips: [String] = []
        if let loc = meta.location { chips.append("📍 \(loc)") }
        if let occ = meta.occasion { chips.append("🎯 \(occ)") }
        if let mood = meta.mood { chips.append("✦ \(mood)") }
        chips += meta.people.map { "👤 \($0)" }
        chips += meta.keywords.prefix(5).map { "#\($0)" }
        return chips
    }

    private var extractionErrorMessage: String {
        guard let err = extractionError else { return "" }
        switch err {
        case .ollamaUnavailable:
            return "Ollama is not running. Start Ollama and retry, enter tags manually, or cancel."
        case .httpError(let code):
            return "Server error (HTTP \(code)). Retry, enter tags manually, or cancel."
        case .networkError(let underlying):
            return "Network error: \(underlying.localizedDescription). Retry, enter tags manually, or cancel."
        case .parsingFailed(let msg):
            return "Could not parse extraction result: \(msg). Retry, enter tags manually, or cancel."
        case .invalidJSON(let msg):
            return "Invalid response from Ollama: \(msg). Retry, enter tags manually, or cancel."
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%01d:%02d", minutes, seconds)
    }

    // MARK: - Actions

    private func transcribeRecording() async {
        guard let audioURL = voiceMemoRecorder.audioURL else { return }
        isTranscribing = true
        transcriptionError = nil
        do {
            noteText = try await transcriptionService.transcribe(audioURL: audioURL)
        } catch {
            transcriptionError = error.localizedDescription
        }
        isTranscribing = false
    }

    private func extractMetadata() async {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isExtracting = true
        do {
            extractedMetadata = try await metadataExtractor.extractMetadata(from: text)
            showExtractionSheet = true
        } catch let error as OllamaError {
            extractionError = error
        } catch {
            extractionError = .networkError(error)
        }
        isExtracting = false
    }

    /// Call Claude Haiku to generate a description + extract structured metadata.
    private func generateAnalysis() async {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isGenerating = true
        generationError = nil
        do {
            analysis = try await noteService.analyse(note: text)
        } catch let error as AnthropicNoteService.NoteServiceError {
            generationError = error.localizedDescription
        } catch {
            generationError = error.localizedDescription
        }
        isGenerating = false
    }

    /// Save user note + Claude description + extracted metadata to every selected photo's thread.
    private func saveNoteWithAnalysis() async {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let a = analysis else { return }

        let repo = ThreadRepository(db: db)

        // Build content JSON for the user note (with extracted metadata inline)
        let noteContentJson: String
        do {
            var noteDict: [String: Any] = ["text": text]
            if let metaData = try? JSONEncoder().encode(a.metadata),
               let metaObj = try? JSONSerialization.jsonObject(with: metaData) {
                noteDict["extracted_metadata"] = metaObj
            }
            let data = try JSONSerialization.data(withJSONObject: noteDict)
            noteContentJson = String(data: data, encoding: .utf8) ?? "{\"text\":\"\(text)\"}"
        } catch {
            noteContentJson = "{\"text\":\"\(text)\"}"
        }

        // Build AI turn content JSON
        let aiContentJson: String
        do {
            let aiDict: [String: String] = ["response": a.description]
            let data = try JSONSerialization.data(withJSONObject: aiDict)
            aiContentJson = String(data: data, encoding: .utf8) ?? "{\"response\":\"\"}"
        } catch {
            aiContentJson = "{\"response\":\"\"}"
        }

        // Write to all photo IDs
        do {
            for pid in photoIds {
                try await repo.addEntry(photoId: pid, kind: "text_note", contentJson: noteContentJson, authoredBy: "user")
                try await repo.addEntry(photoId: pid, kind: "ai_turn", contentJson: aiContentJson, authoredBy: "ai")
            }
        } catch {
            generationError = "Failed to save: \(error.localizedDescription)"
            return
        }

        dismiss()
    }

    /// Save the raw note directly, skipping AI analysis (fallback path).
    private func saveRawNote() async {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { dismiss(); return }

        let repo = ThreadRepository(db: db)
        do {
            let data = try JSONSerialization.data(withJSONObject: ["text": text])
            let json = String(data: data, encoding: .utf8) ?? "{}"
            for pid in photoIds {
                try await repo.addEntry(photoId: pid, kind: "text_note", contentJson: json, authoredBy: "user")
            }
        } catch {}
        dismiss()
    }
}

// MARK: - Preview

#Preview {
    Text("NoteInputSheet requires AppDatabase — use in context.")
        .foregroundStyle(.secondary)
        .padding()
}
