import Combine
import Foundation

// MARK: - SearchMessage

/// A single message in a multi-turn search conversation.
struct SearchMessage: Identifiable {
    let id = UUID()
    let role: Role
    let content: String
    let timestamp: Date

    /// Parsed filter state after this message (assistant messages only).
    var parsedFilter: SearchFilter?
    /// Person names extracted (assistant messages only).
    var personNames: [String]?
    /// Suggested follow-up refinements (assistant messages only).
    var suggestions: [String]?
    /// Approximate result count at this turn (assistant messages only).
    var resultCount: Int?
    /// Whether the assistant recommends map view.
    var preferMapView: Bool?
    /// Preview photo canonical names for inline thumbnail strip (max ~8).
    var previewPhotoNames: [String]?
    /// Hint shown when resultCount is 0, explaining nearby matches.
    var nearbyHint: String?

    enum Role {
        case user
        case assistant

        var apiString: String {
            switch self {
            case .user: return "user"
            case .assistant: return "assistant"
            }
        }
    }
}

// MARK: - ConversationResponse

/// JSON response format from Claude in conversational search mode.
struct ConversationResponse: Codable {
    let reply: String
    let filter: SearchFilter?
    let personNames: [String]?
    let suggestions: [String]?
    let preferMapView: Bool?
}

// MARK: - SearchConversation

/// Manages the state of a multi-turn search conversation.
/// Each user message refines the accumulated search filter.
final class SearchConversation: ObservableObject {
    @Published var messages: [SearchMessage] = []
    @Published var isThinking: Bool = false
    @Published var state: ConversationState = .building

    /// The accumulated filter built across all turns.
    @Published var currentFilter: SearchFilter = SearchFilter()
    /// Accumulated person names across all turns.
    @Published var currentPersonNames: [String] = []

    enum ConversationState {
        case building    // Still refining the query
        case executing   // User committed — results being fetched
        case done        // Results displayed
    }

    /// Whether there's enough filter state to execute a search.
    var canExecute: Bool {
        !currentFilter.isEmpty || !currentPersonNames.isEmpty
    }

    /// Add a user message and return it.
    @discardableResult
    func addUserMessage(_ text: String) -> SearchMessage {
        let msg = SearchMessage(
            role: .user,
            content: text,
            timestamp: Date()
        )
        messages.append(msg)
        return msg
    }

    /// Add an assistant response from a parsed ConversationResponse.
    func addAssistantResponse(_ response: ConversationResponse, resultCount: Int?) {
        // Merge the new filter with the accumulated one
        if let newFilter = response.filter {
            currentFilter = mergeFilter(base: currentFilter, update: newFilter)
        }

        // Replace person names with what Claude returned for this turn
        // (the model sees the full conversation and returns the relevant people for the current query)
        if let names = response.personNames {
            currentPersonNames = names
        }

        let msg = SearchMessage(
            role: .assistant,
            content: response.reply,
            timestamp: Date(),
            parsedFilter: currentFilter,
            personNames: currentPersonNames.isEmpty ? nil : currentPersonNames,
            suggestions: response.suggestions,
            resultCount: resultCount,
            preferMapView: response.preferMapView
        )
        messages.append(msg)
    }

    /// Reset to start a new conversation.
    func reset() {
        messages = []
        currentFilter = SearchFilter()
        currentPersonNames = []
        state = .building
        isThinking = false
    }

    /// Build the messages array for the Claude API call (full conversation history).
    func apiMessages() -> [(role: String, content: String)] {
        messages.map { (role: $0.role.apiString, content: $0.content) }
    }

    // MARK: - Serialization (for activity event persistence / resume)

    /// Serializable snapshot of the conversation for storage in activity metadata.
    struct Snapshot: Codable {
        let messages: [SnapshotMessage]
        let filter: SearchFilter
        let personNames: [String]
    }

    struct SnapshotMessage: Codable {
        let role: String
        let content: String
        let suggestions: [String]?
        let parsedFilter: SearchFilter?
        let personNames: [String]?
        let resultCount: Int?
        let previewPhotoNames: [String]?
        let nearbyHint: String?
    }

    /// Create a serializable snapshot of the current conversation.
    func snapshot() -> Snapshot {
        Snapshot(
            messages: messages.map { msg in
                SnapshotMessage(
                    role: msg.role.apiString,
                    content: msg.content,
                    suggestions: msg.suggestions,
                    parsedFilter: msg.parsedFilter,
                    personNames: msg.personNames,
                    resultCount: msg.resultCount,
                    previewPhotoNames: msg.previewPhotoNames,
                    nearbyHint: msg.nearbyHint
                )
            },
            filter: currentFilter,
            personNames: currentPersonNames
        )
    }

    /// Encode the snapshot to JSON for storing in activity event metadata.
    func snapshotJSON() -> String? {
        do {
            let data = try JSONEncoder().encode(snapshot())
            return String(data: data, encoding: .utf8)
        } catch {
            print("[SearchConversation] snapshot encoding failed: \(error)")
            return nil
        }
    }

    /// Restore a conversation from a persisted snapshot.
    func restore(from snapshot: Snapshot) {
        reset()
        currentFilter = snapshot.filter
        currentPersonNames = snapshot.personNames
        for msg in snapshot.messages {
            let message = SearchMessage(
                role: msg.role == "user" ? .user : .assistant,
                content: msg.content,
                timestamp: Date(),
                parsedFilter: msg.parsedFilter,
                personNames: msg.personNames,
                suggestions: msg.suggestions,
                resultCount: msg.resultCount,
                preferMapView: nil,
                previewPhotoNames: msg.previewPhotoNames,
                nearbyHint: msg.nearbyHint
            )
            messages.append(message)
        }
        state = .building
    }

    /// Restore from JSON string (e.g. from activity event metadata).
    func restoreFromJSON(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return false }
        restore(from: snapshot)
        return true
    }

    // MARK: - Filter merging

    /// Merge an update filter into the base. Non-nil fields in update override base.
    private func mergeFilter(base: SearchFilter, update: SearchFilter) -> SearchFilter {
        var merged = base
        if let v = update.location        { merged.location = v }
        if let v = update.yearFrom        { merged.yearFrom = v }
        if let v = update.yearTo          { merged.yearTo = v }
        if let v = update.cameraModel     { merged.cameraModel = v }
        if let v = update.fileType        { merged.fileType = v }
        if let v = update.curationState   { merged.curationState = v }
        if let v = update.processingState { merged.processingState = v }
        if let v = update.keywords {
            let existing = base.keywords ?? []
            merged.keywords = existing + v.filter { !existing.contains($0) }
        }
        if let v = update.timeOfDay       { merged.timeOfDay = v }
        if let v = update.sceneType       { merged.sceneType = v }
        if let v = update.peopleDetected  { merged.peopleDetected = v }
        if let v = update.printAttempted  { merged.printAttempted = v }
        return merged
    }
}
