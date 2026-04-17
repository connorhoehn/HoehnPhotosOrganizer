import SwiftUI
import GRDB

// MARK: - ThreadDetailView

/// Chronological thread timeline for a single photo.
/// Displays all ThreadEntry kinds (text_note, ai_turn, image_attachment, print_attempt)
/// with rich, social-media-style UI (badges, typography, colors, spacing).
/// Live-updates via GRDB AsyncValueObservation stream.
struct ThreadDetailView: View {

    // MARK: Inputs

    let photoId: String
    let db: AppDatabase
    var hideHeader: Bool = false

    // MARK: State

    @State private var entries: [ThreadEntry] = []
    @State private var loadError: String? = nil
    @State private var showNoteInput: Bool = false

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            if !hideHeader {
                threadHeader
                Divider()
            }

            if entries.isEmpty && loadError == nil {
                emptyState
            } else if let error = loadError {
                errorState(message: error)
            } else {
                ScrollView {
                    threadTimeline
                }
            }
        }
        .sheet(isPresented: $showNoteInput) {
            NoteInputSheet(photoId: photoId, db: db)
        }
        .task {
            await observeThread()
        }
    }

    // MARK: - Header

    private var threadHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 13))
                .foregroundStyle(.blue)
            Text("Thread")
                .font(.system(size: 14, weight: .semibold))
            if !entries.isEmpty {
                Text("\(entries.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
            Spacer()
            Button(action: { showNoteInput = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                    Text("Add Note")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.blue.opacity(0.08))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Timeline

    private var threadTimeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                EntryCardView(entry: entry)
                    .padding(.horizontal, 12)
                    .padding(.top, index == 0 ? 10 : 0)
                    .padding(.bottom, 8)

                if index < entries.count - 1 {
                    Divider()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
            }
            .padding(.bottom, 10)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "message.fill")
                .font(.system(size: 32))
                .foregroundStyle(.quaternary)

            Text("No notes yet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)

            Text("Start the story by adding a note")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(action: { showNoteInput = true }) {
                Label("Add First Note", systemImage: "plus.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    // MARK: - Error State

    private func errorState(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.red)
            Text("Failed to load thread")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Thread Observation

    private func observeThread() async {
        let repo = ThreadRepository(db: db)
        let stream = repo.threadStream(for: photoId)
        do {
            for try await updatedEntries in stream {
                entries = updatedEntries
            }
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - EntryCardView

/// Renders a single ThreadEntry with social-media-style badge, timestamp, and content.
/// Each entry kind has visually distinct colors, icon, badge text, and typography.
struct EntryCardView: View {

    let entry: ThreadEntry
    @State private var isHovered: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Badge row: type badge on left, timestamp on right
            HStack(spacing: 8) {
                entryBadge
                Spacer()
                timestampView
            }

            // Content area with kind-specific typography
            entryContent
                .padding(.leading, 4)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.gray.opacity(0.18), lineWidth: 1)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }

    // MARK: Badge

    private var entryBadge: some View {
        Label(badgeText, systemImage: badgeIcon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(badgeColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(badgeBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var badgeText: String {
        switch entry.kind {
        case "text_note":        return "Note"
        case "ai_turn":          return "AI"
        case "aiConversation":   return "Claude Critique"
        case "image_attachment": return "Image"
        case "print_attempt":    return "Print"
        default:                 return "Entry"
        }
    }

    private var badgeIcon: String {
        switch entry.kind {
        case "text_note":        return "document.text.fill"
        case "ai_turn":          return "sparkles"
        case "aiConversation":   return "sparkles"
        case "image_attachment": return "photo.fill"
        case "print_attempt":    return "printer.fill"
        default:                 return "doc.text"
        }
    }

    private var badgeColor: Color {
        switch entry.kind {
        case "text_note":        return .blue
        case "ai_turn":          return .purple
        case "aiConversation":   return .indigo
        case "image_attachment": return .orange
        case "print_attempt":    return .purple
        default:                 return .gray
        }
    }

    private var badgeBackgroundColor: Color {
        switch entry.kind {
        case "text_note":        return Color.blue.opacity(0.1)
        case "ai_turn":          return Color.purple.opacity(0.1)
        case "aiConversation":   return Color.indigo.opacity(0.1)
        case "image_attachment": return Color.orange.opacity(0.1)
        case "print_attempt":    return Color.purple.opacity(0.1)
        default:                 return Color.gray.opacity(0.1)
        }
    }

    // MARK: Card background

    private var cardBackground: Color {
        let base: Color
        switch entry.kind {
        case "ai_turn", "aiConversation":
            base = Color.indigo.opacity(0.04)
        default:
            base = Color(nsColor: .controlBackgroundColor)
        }
        return isHovered ? Color(nsColor: .controlBackgroundColor).opacity(0.7) : base
    }

    // MARK: Timestamp

    private var timestampView: some View {
        Text(formattedDate)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.secondary)
    }

    private var formattedDate: String {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: entry.createdAt) {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: date, relativeTo: .now)
        }
        return entry.createdAt
    }

    // MARK: Content (kind-specific typography)

    @ViewBuilder
    private var entryContent: some View {
        switch entry.kind {
        case "text_note":
            textNoteContent
        case "ai_turn":
            aiTurnContent
        case "aiConversation":
            aiConversationContent
        case "image_attachment":
            imageAttachmentContent
        case "print_attempt":
            printAttemptContent
        default:
            genericContent
        }
    }

    // text_note: body font, regular weight, primary color
    private var textNoteContent: some View {
        let text = extractField("text") ?? extractField("transcription") ?? entry.contentJson
        return Text(text)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // ai_turn: subheadline font, semibold, blue tint
    private var aiTurnContent: some View {
        let text = extractField("response") ?? extractField("text") ?? entry.contentJson
        return Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.blue)
            .fixedSize(horizontal: false, vertical: true)
    }

    // aiConversation: structured editorial critique summary
    private var aiConversationContent: some View {
        let dict = parsedDict()
        let score      = dict["compositionScore"] as? Int
        let readiness  = dict["printReadiness"] as? String ?? ""
        let analysis   = dict["analysis"] as? String
        let rationale  = dict["adjustmentsRationale"] as? String
        let isReady    = readiness.lowercased() == "ready"

        return VStack(alignment: .leading, spacing: 6) {
            // Score + readiness row
            HStack(spacing: 8) {
                if let score {
                    HStack(spacing: 3) {
                        Text("\(score)/10")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.indigo)
                        Text("composition")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                if !readiness.isEmpty {
                    Label(isReady ? "Print ready" : "Needs work",
                          systemImage: isReady ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isReady ? .green : .orange)
                }
            }

            // Analysis excerpt (first 180 chars)
            if let analysis {
                Text(String(analysis.prefix(180)) + (analysis.count > 180 ? "…" : ""))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Adjustment rationale if present
            if let rationale {
                Text(rationale)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func parsedDict() -> [String: Any] {
        guard let data = entry.contentJson.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return dict
    }

    // image_attachment: caption font, filename + optional thumbnail label
    private var imageAttachmentContent: some View {
        let path = extractField("path") ?? ""
        let filename = path.isEmpty
            ? "Image attachment"
            : URL(fileURLWithPath: path).lastPathComponent
        return HStack(spacing: 6) {
            Image(systemName: "photo.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            Text(filename)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // print_attempt: caption font, semibold, purple
    private var printAttemptContent: some View {
        let process = extractField("process") ?? extractField("print_type") ?? "Print attempt"
        let date = extractField("attempt_date") ?? ""
        return VStack(alignment: .leading, spacing: 2) {
            Text(process)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.purple)
            if !date.isEmpty {
                Text(date)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var genericContent: some View {
        Text(entry.contentJson)
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(.secondary)
            .lineLimit(3)
    }

    // MARK: JSON helpers

    private func extractField(_ key: String) -> String? {
        guard let data = entry.contentJson.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = dict[key] as? String else {
            return nil
        }
        return value
    }
}

// MARK: - Preview

#Preview {
    VStack {
        Text("ThreadDetailView requires AppDatabase for live preview")
            .foregroundStyle(.secondary)
        Text("Use in context with a real AppDatabase instance.")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
    .padding()
}
