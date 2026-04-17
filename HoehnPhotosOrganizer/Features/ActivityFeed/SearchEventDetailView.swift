import SwiftUI

/// Renders a search activity event as a proper conversation thread
/// instead of raw JSON. Reuses SearchChatBubble from the search experience.
struct SearchEventDetailView: View {
    let event: ActivityEvent

    /// Parsed conversation messages from the event metadata.
    private var parsedMessages: [SearchMessage] {
        guard let metadata = event.metadata,
              let data = metadata.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let conversationJSON = json["conversation_json"] as? String,
              let convData = conversationJSON.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(SearchConversation.Snapshot.self, from: convData)
        else { return [] }

        return snapshot.messages.map { msg in
            SearchMessage(
                role: msg.role == "user" ? .user : .assistant,
                content: msg.content,
                timestamp: event.occurredAt,
                suggestions: msg.suggestions
            )
        }
    }

    /// Extract summary info from metadata.
    private var searchMeta: (personNames: [String], resultCount: Int?, filterDesc: String?) {
        guard let metadata = event.metadata,
              let data = metadata.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ([], nil, nil) }

        let people = (json["person_names"] as? [String]) ?? []
        let count = json["result_count"] as? Int
        let filterJSON = json["filter_json"] as? String
        let filterDesc: String? = {
            guard let fj = filterJSON,
                  let fd = fj.data(using: .utf8),
                  let filter = try? JSONDecoder().decode(SearchFilter.self, from: fd) else { return nil }
            var parts: [String] = []
            if let loc = filter.location { parts.append(loc) }
            if let y = filter.yearFrom { parts.append("from \(y)") }
            if let cs = filter.curationState { parts.append(cs.replacingOccurrences(of: "_", with: " ")) }
            if let sc = filter.sceneType { parts.append(sc) }
            if let cm = filter.cameraModel { parts.append(cm) }
            if let kws = filter.keywords, !kws.isEmpty { parts.append(contentsOf: kws) }
            if filter.printAttempted == true { parts.append("printed") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }()
        return (people, count, filterDesc)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            searchHeader
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            Divider()

            // Conversation thread
            conversationBody
        }
    }

    // MARK: - Header

    private var searchHeader: some View {
        let meta = searchMeta
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 52, height: 52)
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.blue)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(event.title)
                        .font(.system(size: 17, weight: .bold))

                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Text(event.occurredAt, style: .relative)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                        Text("·")
                            .foregroundStyle(.quaternary)
                        Text(event.occurredAt, format: .dateTime.month().day().hour().minute())
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()
            }

            // Summary chips
            HStack(spacing: 8) {
                if let count = meta.resultCount {
                    HStack(spacing: 4) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 10))
                        Text("\(count) result\(count == 1 ? "" : "s")")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }

                if !meta.personNames.isEmpty {
                    ForEach(meta.personNames, id: \.self) { name in
                        Text(name)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.purple.opacity(0.1)))
                            .foregroundStyle(.purple)
                    }
                }

                if let desc = meta.filterDesc {
                    Text(desc)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Conversation body

    @ViewBuilder
    private var conversationBody: some View {
        let messages = parsedMessages
        if messages.isEmpty {
            // Fallback: no conversation data, show simple detail
            VStack(spacing: 12) {
                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(messages) { message in
                        SearchChatBubble(
                            message: message,
                            onSuggestionTap: { _ in }
                        )
                    }
                }
                .padding(20)
            }
        }
    }
}
