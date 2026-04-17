import SwiftUI
import Foundation
import GRDB

// MARK: - DevelopChatMessage

struct DevelopChatMessage: Identifiable {
    let id: UUID
    let role: Role
    let text: String
    let suggestedAdjustments: SuggestedAdjustments?
    let toolCommands: [String]  // e.g. ["detect_masks", "open_masks"]
    let timestamp: Date

    enum Role: String { case user, assistant, system }

    init(id: UUID = UUID(), role: Role, text: String, suggestedAdjustments: SuggestedAdjustments? = nil, toolCommands: [String] = [], timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.suggestedAdjustments = suggestedAdjustments
        self.toolCommands = toolCommands
        self.timestamp = timestamp
    }
}

/// Codable wrapper for persisting chat messages to thread_entries.
private struct ChatMessagePayload: Codable {
    let role: String
    let text: String
    let adjustmentsJSON: String?  // SuggestedAdjustments serialized
}

// MARK: - DevelopChatView

/// Unified Assistant panel for Develop mode.
/// Combines chat, editorial critique, and adjustment suggestions in one interface.
struct DevelopChatView: View {

    let photoId: String
    let photoName: String
    let proxyImageBase64: String?
    let photoContext: String  // EXIF, people, metadata — injected from DevelopView
    let currentAdjustments: () -> PhotoAdjustments
    let onApplyAdjustments: (SuggestedAdjustments) -> Void
    let onUndoAdjustments: (PhotoAdjustments) -> Void
    let onRequestEditorial: () -> Void
    let onAutoAdjust: () -> Void
    let onDetectMasks: () -> Void
    let onSwitchTool: (String) -> Void  // "adjust", "masks", "history"
    let onSearchByFace: (Int, NSImage) -> Void
    let photo: PhotoAsset?
    let editorialFeedback: EditorialFeedback?
    let editorialLoading: Bool

    @Environment(\.appDatabase) private var appDatabase: AppDatabase?
    @State private var messages: [DevelopChatMessage] = []
    @State private var inputText = ""
    @State private var isLoading = false
    @FocusState private var inputFocused: Bool
    /// Tracks which message IDs have been applied (for undo)
    @State private var appliedMessageIDs: Set<UUID> = []
    /// Snapshot of adjustments before each apply, keyed by message ID
    @State private var undoSnapshots: [UUID: PhotoAdjustments] = [:]

    var body: some View {
        VStack(spacing: 0) {
            // Messages area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if messages.isEmpty {
                            emptyState
                        }

                        ForEach(messages) { msg in
                            chatBubble(msg).id(msg.id)
                        }

                        // Editorial feedback inline
                        if editorialLoading {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("Running editorial critique...").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                        } else if let fb = editorialFeedback, messages.isEmpty || messages.last?.role != .system {
                            editorialCard(fb)
                        }

                        if isLoading {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("Thinking...").font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .id("loading")
                        }
                    }
                    .padding(12)
                }
                .onChange(of: messages.count) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation {
                            if isLoading {
                                proxy.scrollTo("loading", anchor: .bottom)
                            } else if let lastId = messages.last?.id {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                }
                .onChange(of: isLoading) {
                    if isLoading {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            withAnimation { proxy.scrollTo("loading", anchor: .bottom) }
                        }
                    }
                }
            }

            Divider()

            // Input area
            VStack(spacing: 8) {
                TextEditor(text: $inputText)
                    .font(.system(size: 13))
                    .focused($inputFocused)
                    .frame(minHeight: 44, maxHeight: 80)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .overlay(alignment: .topLeading) {
                        if inputText.isEmpty {
                            Text("Message assistant...")
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 12).padding(.top, 12)
                                .allowsHitTesting(false)
                        }
                    }
                    .onKeyPress(.return) {
                        if NSEvent.modifierFlags.contains(.shift) {
                            // Shift+Enter: insert newline (let it pass through)
                            return .ignored
                        } else {
                            // Enter: send message
                            sendMessage()
                            return .handled
                        }
                    }

                HStack {
                    if !messages.isEmpty {
                        Button {
                            messages.removeAll()
                            appliedMessageIDs.removeAll()
                            undoSnapshots.removeAll()
                            Task { await saveMessages() }
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear chat history")
                    }

                    Text("Enter to send")
                        .font(.caption2).foregroundStyle(.quaternary)
                    Spacer()
                    Button { sendMessage() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up")
                            Text("Send")
                        }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(12)
        }
        .onAppear { inputFocused = true }
        .task { await loadMessages() }
        .onDisappear { Task { await saveMessages() } }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Greeting
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hi! I'm your photo assistant.")
                        .font(.callout.weight(.medium))
                    Text("What would you like to do with this photo?")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 4)

            // Face chips — people in this photo
            if let photo = photo, let db = appDatabase {
                FaceChipGrid(photo: photo, db: db) { faceIndex, faceImage in
                    onSearchByFace(faceIndex, faceImage)
                }
            }

            // Tool buttons
            VStack(spacing: 6) {
                toolButton("Run editorial critique", subtitle: "Score, analysis, and adjustment suggestions", icon: "eye") {
                    onRequestEditorial()
                }
                toolButton("Auto-adjust levels", subtitle: "Fix exposure, contrast, and tonal balance", icon: "slider.horizontal.3") {
                    sendQuick("Analyze this photo and suggest optimal exposure, contrast, highlights, shadows, whites, and blacks adjustments")
                }
                toolButton("Optimize for printing", subtitle: "Prepare tones for platinum, cyanotype, or inkjet", icon: "printer") {
                    sendQuick("Make this photo print-ready for platinum-palladium printing — optimize tonal range and contrast")
                }
                toolButton("Color correction", subtitle: "Fix white balance, saturation, color cast", icon: "paintpalette") {
                    sendQuick("Analyze the color balance and suggest corrections for white balance and saturation")
                }
                toolButton("Creative look", subtitle: "Moody, filmic, high-key, low-key styles", icon: "wand.and.stars") {
                    sendQuick("Suggest a creative look for this photo — something moody or filmic")
                }
            }

            Text("Or type anything below to chat freely.")
                .font(.caption2).foregroundStyle(.quaternary)
        }
        .padding(.top, 8)
    }

    private func toolButton(_ title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption.weight(.medium))
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading || editorialLoading)
    }

    // MARK: - Chat Bubble

    @ViewBuilder
    private func chatBubble(_ msg: DevelopChatMessage) -> some View {
        let isUser = msg.role == .user
        let isApplied = appliedMessageIDs.contains(msg.id)
        HStack {
            if isUser { Spacer(minLength: 30) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(msg.timestamp, format: .dateTime.hour().minute())
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)

                Text(msg.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isUser ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06))
                    )

                if let adj = msg.suggestedAdjustments {
                    HStack(spacing: 6) {
                        if isApplied {
                            // Show undo after applying
                            Button {
                                if let snapshot = undoSnapshots[msg.id] {
                                    onUndoAdjustments(snapshot)
                                    appliedMessageIDs.remove(msg.id)
                                    undoSnapshots.removeValue(forKey: msg.id)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.uturn.backward")
                                    Text("Undo")
                                }
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        } else {
                            // Show apply
                            Button {
                                undoSnapshots[msg.id] = currentAdjustments()
                                onApplyAdjustments(adj)
                                appliedMessageIDs.insert(msg.id)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "slider.horizontal.3")
                                    Text("Apply Adjustments")
                                }
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                            }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        }
                    }
                }

                // Tool action buttons — user confirms before executing
                if !msg.toolCommands.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(msg.toolCommands, id: \.self) { cmd in
                            Button {
                                executeToolCommand(cmd)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: toolIcon(for: cmd))
                                    Text(toolLabel(for: cmd))
                                }
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .tint(toolTint(for: cmd))
                        }
                    }
                }
            }
            if !isUser { Spacer(minLength: 30) }
        }
    }

    private func toolIcon(for cmd: String) -> String {
        switch cmd {
        case "auto_adjust": return "wand.and.rays"
        case "detect_masks": return "person.and.background.dotted"
        case "editorial": return "text.magnifyingglass"
        case "open_masks": return "circle.dashed"
        case "open_adjust": return "slider.horizontal.3"
        case "open_history": return "clock.arrow.circlepath"
        default: return "questionmark.circle"
        }
    }

    private func toolLabel(for cmd: String) -> String {
        switch cmd {
        case "auto_adjust": return "Run Auto Levels"
        case "detect_masks": return "Detect Masks"
        case "editorial": return "Run Critique"
        case "open_masks": return "Open Masks"
        case "open_adjust": return "Open Adjust"
        case "open_history": return "Open History"
        default: return cmd
        }
    }

    private func toolTint(for cmd: String) -> Color {
        switch cmd {
        case "auto_adjust": return .orange
        case "detect_masks": return .purple
        case "editorial": return .green
        default: return .accentColor
        }
    }

    // MARK: - Editorial Card

    @ViewBuilder
    private func editorialCard(_ fb: EditorialFeedback) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(fb.compositionScore)/10", systemImage: "star.fill")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(fb.printReadiness)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(fb.printReadiness == "ready" ? Color.green.opacity(0.2) : Color.orange.opacity(0.2)))
                    .foregroundStyle(fb.printReadiness == "ready" ? .green : .orange)
            }

            Text(fb.analysis).font(.system(size: 12)).foregroundStyle(.secondary)

            if let adj = fb.adjustments {
                let editorialID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
                let isApplied = appliedMessageIDs.contains(editorialID)
                HStack(spacing: 6) {
                    if isApplied {
                        Button {
                            if let snapshot = undoSnapshots[editorialID] {
                                onUndoAdjustments(snapshot)
                                appliedMessageIDs.remove(editorialID)
                                undoSnapshots.removeValue(forKey: editorialID)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.uturn.backward")
                                Text("Undo")
                            }.font(.caption.weight(.medium))
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    } else {
                        Button {
                            undoSnapshots[editorialID] = currentAdjustments()
                            onApplyAdjustments(adj)
                            appliedMessageIDs.insert(editorialID)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "slider.horizontal.3")
                                Text("Apply Suggested Adjustments")
                            }.font(.caption.weight(.medium))
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
            }

            if !fb.strengths.isEmpty {
                ForEach(fb.strengths.prefix(2), id: \.self) { s in
                    Label(s, systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.green)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    // MARK: - Send

    private func sendQuick(_ text: String) {
        inputText = ""
        let userMsg = DevelopChatMessage(role: .user, text: text)
        messages.append(userMsg)
        performSend(text)
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""

        let userMsg = DevelopChatMessage(role: .user, text: text)
        messages.append(userMsg)
        performSend(text)
    }

    private func performSend(_ text: String) {
        Task {
            isLoading = true
            defer { isLoading = false }

            do {
                let (responseText, adj, tools) = try await callClaude(userText: text)
                let assistantMsg = DevelopChatMessage(role: .assistant, text: responseText, suggestedAdjustments: adj, toolCommands: tools)
                messages.append(assistantMsg)

                if let db = appDatabase {
                    let repo = ActivityEventRepository(db: db)
                    let service = ActivityEventService(repo: repo)
                    try? await service.emitNote(
                        body: "Assistant: \(text)\nClaude: \(responseText.prefix(200))",
                        photoAssetId: nil
                    )
                }
                // Persist after each exchange
                Task { await saveMessages() }
            } catch {
                let errMsg = DevelopChatMessage(role: .assistant, text: "Error: \(error.localizedDescription)")
                messages.append(errMsg)
            }
        }
    }

    // MARK: - Persistence

    private func loadMessages() async {
        guard let db = appDatabase else { return }
        do {
            let entries = try await db.dbPool.read { db in
                try ThreadEntry
                    .filter(Column("thread_root_id") == photoId)
                    .filter(Column("kind") == "assistant_chat")
                    .order(Column("sequence_number").asc)
                    .fetchAll(db)
            }
            guard !entries.isEmpty else { return }
            var loaded: [DevelopChatMessage] = []
            let decoder = JSONDecoder()
            for entry in entries {
                guard let data = entry.contentJson.data(using: .utf8),
                      let payload = try? decoder.decode(ChatMessagePayload.self, from: data) else { continue }
                let role: DevelopChatMessage.Role = payload.role == "user" ? .user : .assistant
                var adj: SuggestedAdjustments? = nil
                if let adjJSON = payload.adjustmentsJSON,
                   let adjData = adjJSON.data(using: .utf8) {
                    adj = try? decoder.decode(SuggestedAdjustments.self, from: adjData)
                }
                let timestamp = ISO8601DateFormatter().date(from: entry.createdAt) ?? Date()
                loaded.append(DevelopChatMessage(id: UUID(), role: role, text: payload.text,
                                                 suggestedAdjustments: adj, timestamp: timestamp))
            }
            if !loaded.isEmpty {
                messages = loaded
                // Allow SwiftUI to lay out before scrolling
                try? await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            print("[DevelopChatView] Failed to load messages: \(error)")
        }
    }

    private func saveMessages() async {
        guard let db = appDatabase, !messages.isEmpty else { return }
        do {
            try await db.dbPool.write { db in
                // Clear old chat entries for this photo
                try db.execute(
                    sql: "DELETE FROM thread_entries WHERE thread_root_id = ? AND kind = 'assistant_chat'",
                    arguments: [photoId]
                )
                // Write current messages
                let encoder = JSONEncoder()
                for (i, msg) in messages.enumerated() {
                    var adjJSON: String? = nil
                    if let adj = msg.suggestedAdjustments,
                       let data = try? encoder.encode(adj) {
                        adjJSON = String(data: data, encoding: .utf8)
                    }
                    let payload = ChatMessagePayload(
                        role: msg.role.rawValue,
                        text: msg.text,
                        adjustmentsJSON: adjJSON
                    )
                    guard let contentData = try? encoder.encode(payload),
                          let contentStr = String(data: contentData, encoding: .utf8) else { continue }
                    let entry = ThreadEntry(
                        id: UUID().uuidString,
                        threadRootId: photoId,
                        sequenceNumber: i,
                        kind: "assistant_chat",
                        authoredBy: msg.role == .user ? "user" : "ai",
                        contentJson: contentStr,
                        createdAt: ISO8601DateFormatter().string(from: msg.timestamp),
                        syncState: "local_only"
                    )
                    try entry.insert(db)
                }
            }
        } catch {
            print("[DevelopChatView] Failed to save messages: \(error)")
        }
    }

    // MARK: - Claude API

    private func callClaude(userText: String) async throws -> (String, SuggestedAdjustments?, [String]) {
        let adj = currentAdjustments()

        let systemPrompt = """
        Photo editing assistant for a Lightroom-style app. You can see the photo. Be brief and direct (1-2 sentences).

        FILE: \(photoName)
        \(photoContext)
        CURRENT SLIDERS: exposure=\(adj.exposure) contrast=\(adj.contrast) highlights=\(adj.highlights) \
        shadows=\(adj.shadows) whites=\(adj.whites) blacks=\(adj.blacks) saturation=\(adj.saturation) vibrance=\(adj.vibrance)

        You can do two things in your response — emit ADJUSTMENTS and/or TOOL commands, each on its own line:

        ADJUSTMENTS:{"exposure":0.5,"contrast":10}
        — Sets slider values. Only include changed sliders. Ranges: exposure -5 to +5, others -100 to +100.

        TOOL:auto_adjust
        — Runs histogram-based auto levels on the photo.

        TOOL:detect_masks
        — Runs AI segmentation to detect people, faces, background as selectable mask layers.

        TOOL:editorial
        — Runs a full editorial critique with composition score, strengths, and improvement suggestions.

        TOOL:open_masks
        — Switches the right panel to the Masks tool so the user can work with layers.

        TOOL:open_adjust
        — Switches the right panel to the Adjust tool (levels, color, advanced).

        TOOL:open_history
        — Shows the adjustment history for this photo.

        Use these tools proactively. If the user says "fix the exposure", emit ADJUSTMENTS. \
        If they say "detect the people", emit TOOL:detect_masks. \
        If they say "review this photo", emit TOOL:editorial. \
        If they say "auto adjust" or "auto levels", emit TOOL:auto_adjust. \
        You can combine text + adjustments + tools in one response.
        """

        // Build API messages with image in the first user message
        var apiMsgs: [[String: Any]] = []

        // Include last 6 messages as history
        for msg in messages.suffix(6) {
            apiMsgs.append(["role": msg.role == .user ? "user" : "assistant", "content": msg.text])
        }

        // Always include the image so Claude can see what the user is looking at
        if let b64 = proxyImageBase64 {
            apiMsgs.append([
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": b64]],
                    ["type": "text", "text": userText]
                ] as [[String: Any]]
            ])
        } else {
            apiMsgs.append(["role": "user", "content": userText])
        }

        let apiKey = try await AnthropicAuthManager().getAPIKey()

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 512,
            "system": systemPrompt,
            "messages": apiMsgs
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            throw SearchClientError.malformedResponse
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, _) = try await URLSession.shared.data(for: request)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let textBlock = content.first(where: { $0["type"] as? String == "text" }),
              let responseText = textBlock["text"] as? String else {
            throw SearchClientError.malformedResponse
        }

        if let usage = json["usage"] as? [String: Any] {
            let input = usage["input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            await APIUsageLogger.shared.log(
                model: "claude-haiku-4-5-20251001", label: "develop assistant",
                inputTokens: input, outputTokens: output, durationMs: 0
            )
        }

        let adjustments = parseAdjustments(from: responseText)
        let tools = parseToolCommands(from: responseText)

        let cleanText = responseText
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("ADJUSTMENTS:") && !$0.hasPrefix("TOOL:") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (cleanText.isEmpty ? responseText : cleanText, adjustments, tools)
    }

    private func parseAdjustments(from text: String) -> SuggestedAdjustments? {
        guard let range = text.range(of: "ADJUSTMENTS:") else { return nil }
        let jsonStart = text[range.upperBound...]
        guard let openBrace = jsonStart.firstIndex(of: "{") else { return nil }

        var depth = 0
        var endIdx = openBrace
        for i in jsonStart[openBrace...].indices {
            if jsonStart[i] == "{" { depth += 1 }
            if jsonStart[i] == "}" { depth -= 1 }
            if depth == 0 { endIdx = i; break }
        }

        let jsonStr = String(jsonStart[openBrace...endIdx])
        guard let data = jsonStr.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        return SuggestedAdjustments(
            exposure: dict["exposure"] as? Double,
            contrast: (dict["contrast"] as? NSNumber)?.intValue,
            highlights: (dict["highlights"] as? NSNumber)?.intValue,
            shadows: (dict["shadows"] as? NSNumber)?.intValue,
            whites: (dict["whites"] as? NSNumber)?.intValue,
            blacks: (dict["blacks"] as? NSNumber)?.intValue,
            saturation: (dict["saturation"] as? NSNumber)?.intValue,
            vibrance: (dict["vibrance"] as? NSNumber)?.intValue,
            rationale: nil
        )
    }

    private func parseToolCommands(from text: String) -> [String] {
        text.components(separatedBy: "\n")
            .filter { $0.hasPrefix("TOOL:") }
            .map { $0.replacingOccurrences(of: "TOOL:", with: "").trimmingCharacters(in: .whitespaces) }
    }

    private func executeToolCommand(_ command: String) {
        switch command {
        case "auto_adjust":
            onAutoAdjust()
        case "detect_masks":
            onDetectMasks()
        case "editorial":
            onRequestEditorial()
        case "open_masks":
            onSwitchTool("masks")
        case "open_adjust":
            onSwitchTool("adjust")
        case "open_history":
            onSwitchTool("history")
        default:
            print("[DevelopChatView] Unknown tool command: \(command)")
        }
    }
}
