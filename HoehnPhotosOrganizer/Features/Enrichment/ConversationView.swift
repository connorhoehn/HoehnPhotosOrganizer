import SwiftUI
import GRDB

// MARK: - ConversationView

/// Interactive AI conversation view for a single photo's thread.
/// Displays user text_note and AI ai_turn entries as a chat scroll.
/// Manages context window to prevent token explosion (last N entries).
struct ConversationView: View {

    // MARK: Configuration

    /// Maximum number of thread entries to include in the Ollama context window.
    /// Keeping this small prevents token explosion on long threads.
    static let contextWindowSize: Int = 10

    // MARK: Inputs

    let photoId: String
    let db: AppDatabase

    // MARK: State

    @State private var conversationHistory: [ThreadEntry] = []
    @State private var userInput: String = ""
    @State private var isProcessing: Bool = false
    @State private var sendError: String? = nil
    @State private var scrollProxy: ScrollViewProxy? = nil

    private let metadataExtractor = MetadataExtractor()

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            conversationScrollView
            Divider()
            inputBar
        }
        .task {
            await loadConversation()
        }
    }

    // MARK: - Subviews

    private var conversationScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if conversationHistory.isEmpty && !isProcessing {
                        emptyConversationState
                    } else {
                        ForEach(conversationHistory) { entry in
                            ConversationBubble(entry: entry)
                                .id(entry.id)
                        }
                        if isProcessing {
                            typingIndicator
                                .id("typing-indicator")
                        }
                    }
                }
                .padding()
            }
            .onAppear {
                scrollProxy = proxy
            }
            .onChange(of: conversationHistory.count) {
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: isProcessing) {
                if isProcessing {
                    scrollToBottom(proxy: proxy)
                }
            }
        }
    }

    private var emptyConversationState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 40)
            Image(systemName: "brain.head.profile")
                .font(.system(size: 44))
                .foregroundStyle(.quaternary)
            Text("Start a conversation")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Ask questions or add notes about this photo. The AI will respond using local Ollama.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity)
    }

    private var typingIndicator: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.purple.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: "brain")
                    .font(.system(size: 14))
                    .foregroundStyle(.purple)
            }
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 6, height: 6)
                        .opacity(0.6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.controlBackgroundColor))
            .cornerRadius(16)
            Spacer()
        }
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            if let error = sendError {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Dismiss") { sendError = nil }
                        .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.1))
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask a question or add a note…", text: $userInput, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if !userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Task { await sendMessage() }
                        }
                    }

                Button {
                    Task { await sendMessage() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Computed

    private var canSend: Bool {
        !isProcessing && !userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Returns the last N entries for context window (prevents token explosion).
    var contextWindow: [ThreadEntry] {
        let windowSize = Self.contextWindowSize
        guard conversationHistory.count > windowSize else { return conversationHistory }
        return Array(conversationHistory.suffix(windowSize))
    }

    // MARK: - Actions

    private func loadConversation() async {
        let repo = ThreadRepository(db: db)
        let stream = repo.threadStream(for: photoId)
        do {
            for try await entries in stream {
                // Show only text_note and ai_turn entries in conversation view
                conversationHistory = entries.filter { $0.kind == "text_note" || $0.kind == "ai_turn" }
            }
        } catch {
            sendError = "Failed to load conversation: \(error.localizedDescription)"
        }
    }

    private func sendMessage() async {
        let text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        userInput = ""
        sendError = nil
        isProcessing = true

        // Persist user note entry
        do {
            let repo = ThreadRepository(db: db)
            let contentDict: [String: String] = ["text": text]
            if let jsonData = try? JSONSerialization.data(withJSONObject: contentDict),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                try await repo.addEntry(
                    photoId: photoId,
                    kind: "text_note",
                    contentJson: jsonString,
                    authoredBy: "user"
                )
            }
        } catch {
            sendError = "Failed to save note: \(error.localizedDescription)"
            isProcessing = false
            return
        }

        // Build context prompt from context window
        let contextText = buildContextPrompt(userMessage: text)

        // Call Ollama for AI response
        do {
            let response = try await callOllama(prompt: contextText)
            let repo = ThreadRepository(db: db)
            let responseDict: [String: String] = ["response": response]
            if let jsonData = try? JSONSerialization.data(withJSONObject: responseDict),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                try await repo.addEntry(
                    photoId: photoId,
                    kind: "ai_turn",
                    contentJson: jsonString,
                    authoredBy: "ai"
                )
            }
        } catch let error as OllamaError {
            sendError = ollamaErrorDescription(error)
        } catch {
            sendError = "AI response failed: \(error.localizedDescription)"
        }

        isProcessing = false
    }

    private func buildContextPrompt(userMessage: String) -> String {
        var lines: [String] = [
            "You are an assistant helping a photographer discuss and understand their photos.",
            "Conversation so far:"
        ]

        // Use context window to limit token usage
        for entry in contextWindow {
            switch entry.kind {
            case "text_note":
                let text = extractField("text", from: entry.contentJson) ?? ""
                lines.append("User: \(text)")
            case "ai_turn":
                let text = extractField("response", from: entry.contentJson) ?? ""
                lines.append("AI: \(text)")
            default:
                break
            }
        }

        lines.append("User: \(userMessage)")
        lines.append("AI:")
        return lines.joined(separator: "\n")
    }

    private func callOllama(prompt: String) async throws -> String {
        let ollamaURL = URL(string: "http://localhost:11434/api/generate")!
        let body: [String: Any] = [
            "model": "llama3.2",
            "prompt": prompt,
            "stream": false
        ]

        var request = URLRequest(url: ollamaURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.networkError(NSError(domain: "ConversationView", code: -1))
        }
        guard (200...299).contains(http.statusCode) else {
            throw OllamaError.httpError(statusCode: http.statusCode)
        }

        guard let jsonResponse = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseText = jsonResponse["response"] as? String else {
            throw OllamaError.parsingFailed("Invalid response structure from Ollama")
        }

        return responseText
    }

    private func ollamaErrorDescription(_ error: OllamaError) -> String {
        switch error {
        case .ollamaUnavailable:
            return "Ollama is not running. Start Ollama to use AI responses."
        case .httpError(let code):
            return "Ollama returned HTTP \(code). Check Ollama status."
        case .networkError(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .parsingFailed(let msg):
            return "Could not parse AI response: \(msg)"
        case .invalidJSON(let msg):
            return "Invalid AI response format: \(msg)"
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if isProcessing {
            withAnimation(.easeOut(duration: 0.3)) {
                proxy.scrollTo("typing-indicator", anchor: .bottom)
            }
        } else if let last = conversationHistory.last {
            withAnimation(.easeOut(duration: 0.3)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    // MARK: - JSON helper

    private func extractField(_ key: String, from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = dict[key] as? String else { return nil }
        return value
    }
}

// MARK: - ConversationBubble

/// Renders a single user or AI message as a chat bubble.
struct ConversationBubble: View {
    let entry: ThreadEntry

    private var isUser: Bool { entry.authoredBy == "user" }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 40) }

            if !isUser {
                ZStack {
                    Circle()
                        .fill(Color.purple.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: "brain")
                        .font(.system(size: 14))
                        .foregroundStyle(.purple)
                }
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(messageText)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
                    .foregroundStyle(isUser ? Color.white : Color.primary)
                    .cornerRadius(16)
                    .cornerRadius(isUser ? 4 : 16, corners: isUser ? .bottomRight : .bottomLeft)

                Text(formattedTimestamp)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !isUser { Spacer(minLength: 40) }

            if isUser {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: "person")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private var messageText: String {
        guard let data = entry.contentJson.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return entry.contentJson
        }
        if let text = dict["text"] as? String { return text }
        if let response = dict["response"] as? String { return response }
        return entry.contentJson
    }

    private var bubbleBackground: Color {
        isUser ? Color.accentColor : Color(.controlBackgroundColor)
    }

    private var formattedTimestamp: String {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: entry.createdAt) {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .abbreviated
            return f.localizedString(for: date, relativeTo: .now)
        }
        return entry.createdAt
    }
}

// MARK: - CornerRadius extension

/// Allows applying corner radius to specific corners of a view.
extension View {
    fileprivate func cornerRadius(_ radius: CGFloat, corners: RectCorner) -> some View {
        clipShape(RoundedCornersShape(radius: radius, corners: corners))
    }
}

struct RectCorner: OptionSet {
    let rawValue: Int
    static let topLeft     = RectCorner(rawValue: 1 << 0)
    static let topRight    = RectCorner(rawValue: 1 << 1)
    static let bottomLeft  = RectCorner(rawValue: 1 << 2)
    static let bottomRight = RectCorner(rawValue: 1 << 3)
    static let all: RectCorner = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

private struct RoundedCornersShape: Shape {
    var radius: CGFloat
    var corners: RectCorner

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tl = corners.contains(.topLeft)    ? radius : 0
        let tr = corners.contains(.topRight)   ? radius : 0
        let bl = corners.contains(.bottomLeft) ? radius : 0
        let br = corners.contains(.bottomRight) ? radius : 0

        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        if tr > 0 { path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false) }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 { path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false) }
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 { path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false) }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 { path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false) }
        path.closeSubpath()
        return path
    }
}

// MARK: - Preview

#Preview {
    VStack {
        Text("ConversationView requires AppDatabase for live preview")
            .foregroundStyle(.secondary)
        Text("Use in context with a real AppDatabase instance.")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
    .padding()
}
