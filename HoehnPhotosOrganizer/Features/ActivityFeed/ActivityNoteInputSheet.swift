import SwiftUI

// MARK: - ActivityNoteInputSheet
//
// Lightweight note capture sheet that writes directly to ActivityEventService.
// Distinct from NoteInputSheet (Enrichment/) which uses ThreadRepository + Claude AI.
// Use this when adding a note from the Activity Feed or triggering from the inspector
// in an event-threading context.

struct ActivityNoteInputSheet: View {
    // Caller provides one of: photoAssetId, parentEventId, or neither (standalone note)
    var photoAssetId: String? = nil
    var parentEventId: String? = nil
    var onDismiss: (() -> Void)? = nil

    // ActivityEventService is an actor — inject as a parameter rather than @Environment
    let eventService: ActivityEventService

    @State private var noteText: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "text.bubble.fill")
                    .foregroundStyle(.yellow)
                Text(photoAssetId != nil ? "Add note to photo" : "Add note to event")
                    .font(.headline)
                Spacer()
                Button("Cancel") { onDismiss?() }
                    .keyboardShortcut(.escape)
            }

            // Input
            TextEditor(text: $noteText)
                .frame(minHeight: 80)
                .focused($isFocused)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            // Submit
            HStack {
                Spacer()
                Button("Save Note") {
                    Task {
                        guard !noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        try? await eventService.emitNote(
                            body: noteText,
                            photoAssetId: photoAssetId,
                            parentEventId: parentEventId
                        )
                        onDismiss?()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding()
        .frame(minWidth: 360, minHeight: 180)
        .onAppear { isFocused = true }
    }
}
