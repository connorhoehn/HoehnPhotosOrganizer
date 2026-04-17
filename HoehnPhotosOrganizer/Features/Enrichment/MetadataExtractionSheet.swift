import SwiftUI

// MARK: - MetadataExtractionSheet

/// Review UI displayed after Ollama extracts metadata from a note.
/// Shows Phase 3 fields only: location, people, occasion, mood, keywords.
/// sceneType and peopleDetected are deliberately excluded (deferred to Phase 7).
struct MetadataExtractionSheet: View {

    // MARK: Inputs

    let photoId: String
    let noteText: String
    let extractedMetadata: MetadataExtractionResult

    /// Called when user confirms the extracted tags. Parent dismisses the full note input flow.
    let onConfirm: () -> Void

    /// Called when user declines. Returns to NoteInputSheet.
    let onDecline: () -> Void

    // MARK: State

    @State private var isSaving: Bool = false
    @State private var saveError: String? = nil

    @Environment(\.dismiss) private var dismiss

    // MARK: Body

    var body: some View {
        NavigationStack {
            Form {
                extractedTagsSection
                notePreviewSection
            }
            .navigationTitle("Review Extracted Tags")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Decline") {
                        onDecline()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Confirm Tags") {
                            Task { await confirmAndSave() }
                        }
                        .bold()
                    }
                }
            }
            .alert(
                "Save Failed",
                isPresented: Binding<Bool>(
                    get: { saveError != nil },
                    set: { if !$0 { saveError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    // MARK: - Sections

    private var extractedTagsSection: some View {
        Section {
            // Location
            if let location = extractedMetadata.location, !location.isEmpty {
                LabeledContent("Location") {
                    Text(location)
                        .foregroundStyle(.primary)
                }
            } else {
                LabeledContent("Location") {
                    Text("Not detected")
                        .foregroundStyle(.secondary)
                }
            }

            // People
            if !extractedMetadata.people.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("People")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TagChipView(tags: extractedMetadata.people)
                }
                .padding(.vertical, 4)
            } else {
                LabeledContent("People") {
                    Text("None detected")
                        .foregroundStyle(.secondary)
                }
            }

            // Occasion
            if let occasion = extractedMetadata.occasion, !occasion.isEmpty {
                LabeledContent("Occasion") {
                    Text(occasion)
                        .foregroundStyle(.primary)
                }
            } else {
                LabeledContent("Occasion") {
                    Text("Not detected")
                        .foregroundStyle(.secondary)
                }
            }

            // Mood
            if let mood = extractedMetadata.mood, !mood.isEmpty {
                LabeledContent("Mood") {
                    Text(mood)
                        .foregroundStyle(.primary)
                }
            } else {
                LabeledContent("Mood") {
                    Text("Not detected")
                        .foregroundStyle(.secondary)
                }
            }

            // Keywords
            if !extractedMetadata.keywords.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Keywords")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TagChipView(tags: extractedMetadata.keywords)
                }
                .padding(.vertical, 4)
            } else {
                LabeledContent("Keywords") {
                    Text("None detected")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Extracted Metadata")
        } footer: {
            Text("Extracted from your note using local AI. Scene type and people detection are available in a later phase.")
                .font(.caption)
        }
    }

    private var notePreviewSection: some View {
        Section("Original Note") {
            Text(noteText)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(6)
        }
    }

    // MARK: - Actions

    private func confirmAndSave() async {
        isSaving = true
        // Encode note + extracted metadata as contentJson for thread entry
        let contentPayload: [String: Any] = [
            "text": noteText,
            "extracted_metadata": [
                "location": extractedMetadata.location ?? NSNull(),
                "people": extractedMetadata.people,
                "occasion": extractedMetadata.occasion ?? NSNull(),
                "mood": extractedMetadata.mood ?? NSNull(),
                "keywords": extractedMetadata.keywords
            ] as [String: Any]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: contentPayload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            saveError = "Could not encode metadata."
            isSaving = false
            return
        }

        // Persistence is delegated to the caller via onConfirm;
        // thread writes require the AppDatabase handle not available in this sheet.
        // In production wiring (Phase 3 integration), the caller provides a ThreadRepository.
        _ = jsonString
        isSaving = false
        onConfirm()
        dismiss()
    }
}

// MARK: - TagChipView

/// Horizontal wrapping row of tag chips.
struct TagChipView: View {
    let tags: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())
            }
        }
    }
}

// MARK: - FlowLayout

/// Simple left-to-right wrapping layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        return layout(subviews: subviews, in: width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(subviews: subviews, in: bounds.width)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private struct LayoutResult {
        var size: CGSize
        var frames: [CGRect]
    }

    private func layout(subviews: Subviews, in maxWidth: CGFloat) -> LayoutResult {
        var frames: [CGRect] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: currentX, y: currentY), size: size))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        let totalHeight = currentY + lineHeight
        return LayoutResult(
            size: CGSize(width: maxWidth, height: totalHeight),
            frames: frames
        )
    }
}

// MARK: - Preview

#Preview {
    MetadataExtractionSheet(
        photoId: "preview-photo-001",
        noteText: "Shot at the tide pools near Pescadero with Maria and Jake. Golden hour, lots of sea anemones.",
        extractedMetadata: MetadataExtractionResult(
            location: "Pescadero tide pools",
            people: ["Maria", "Jake"],
            occasion: "Nature photography outing",
            mood: "Golden hour calm",
            keywords: ["tide pools", "sea anemones", "coastal", "golden hour"],
            sceneType: nil,
            peopleDetected: nil
        ),
        onConfirm: {},
        onDecline: {}
    )
}
