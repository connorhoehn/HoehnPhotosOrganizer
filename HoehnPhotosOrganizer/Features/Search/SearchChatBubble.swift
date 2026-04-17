import SwiftUI

// MARK: - SearchChatBubble

/// Chat bubble for the conversational search thread.
/// User messages appear right-aligned in accent color.
/// Assistant messages appear left-aligned with filter chips and suggestions.
struct SearchChatBubble: View {
    let message: SearchMessage
    let onSuggestionTap: (String) -> Void
    var onShowResults: (() -> Void)? = nil
    var onNewSearch: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .user {
                Spacer(minLength: 80)
                userBubble
            } else {
                assistantBubble
                Spacer(minLength: 80)
            }
        }
    }

    // MARK: - User bubble

    private var userBubble: some View {
        Text(message.content)
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.accentColor)
            )
    }

    // MARK: - Assistant bubble

    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Avatar + reply text
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.purple)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.purple.opacity(0.12)))

                VStack(alignment: .leading, spacing: 6) {
                    Text(message.content)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)

                    // Result count badge + show results link
                    if let count = message.resultCount {
                        if count > 0 {
                            HStack(spacing: 8) {
                                HStack(spacing: 4) {
                                    Image(systemName: "photo.stack")
                                        .font(.system(size: 10))
                                    Text("\(count) photo\(count == 1 ? "" : "s") match")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))

                                if let action = onShowResults {
                                    Button {
                                        action()
                                    } label: {
                                        HStack(spacing: 3) {
                                            Image(systemName: "arrow.right.circle.fill")
                                                .font(.system(size: 10))
                                            Text("Show Results")
                                                .font(.system(size: 11, weight: .medium))
                                        }
                                        .foregroundStyle(Color.accentColor)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } else {
                            // 0 results — show nearby hint if available
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 4) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 10))
                                    Text("0 photos match")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))

                                if let hint = message.nearbyHint {
                                    Label(hint, systemImage: "lightbulb")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }

                    // Inline thumbnail strip
                    if let names = message.previewPhotoNames, !names.isEmpty {
                        thumbnailStrip(names)
                    }
                }
            }

            // Active filter chips
            if let filter = message.parsedFilter, !filter.isEmpty {
                filterChips(filter, personNames: message.personNames)
            }

            // Suggestion pills
            if let suggestions = message.suggestions, !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button {
                                onSuggestionTap(suggestion)
                            } label: {
                                Text(suggestion)
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.1)))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
        )
    }

    // MARK: - Thumbnail strip

    private func thumbnailStrip(_ names: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(names, id: \.self) { name in
                    SearchThumbnail(canonicalName: name)
                }

                if let count = message.resultCount, count > names.count {
                    Text("+\(count - names.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.06))
                        )
                }
            }
        }
        .frame(height: 36)
    }

    // MARK: - Filter chips

    @ViewBuilder
    private func filterChips(_ filter: SearchFilter, personNames: [String]?) -> some View {
        let chips = buildChipList(filter, personNames: personNames)
        if !chips.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(chips, id: \.self) { chip in
                    Text(chip)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(Color.purple.opacity(0.1))
                        )
                        .foregroundStyle(.purple)
                }
            }
        }
    }

    private func buildChipList(_ filter: SearchFilter, personNames: [String]?) -> [String] {
        var chips: [String] = []
        if let loc = filter.location       { chips.append(loc) }
        if let y1 = filter.yearFrom, let y2 = filter.yearTo {
            chips.append(y1 == y2 ? "\(y1)" : "\(y1)–\(y2)")
        } else if let y = filter.yearFrom  { chips.append("from \(y)") }
        else if let y = filter.yearTo      { chips.append("through \(y)") }
        if let cs = filter.curationState   { chips.append(cs.replacingOccurrences(of: "_", with: " ")) }
        if let sc = filter.sceneType       { chips.append(sc) }
        if let tod = filter.timeOfDay      { chips.append(tod.replacingOccurrences(of: "_", with: " ")) }
        if let ft = filter.fileType        { chips.append(ft.uppercased()) }
        if let cm = filter.cameraModel     { chips.append(cm) }
        if filter.peopleDetected == true   { chips.append("with people") }
        if filter.printAttempted == true    { chips.append("printed") }
        if let kw = filter.keywords        { chips.append(contentsOf: kw) }
        if let names = personNames         { chips.append(contentsOf: names) }
        return chips
    }
}

// MARK: - SearchThumbnail (async proxy image loader)

/// Loads a proxy thumbnail off the main thread to avoid blocking during scroll.
private struct SearchThumbnail: View {
    let canonicalName: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.3))
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    )
            }
        }
        .frame(width: 48, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .opacity(image == nil ? 0 : 1)
        .animation(.easeIn(duration: 0.18), value: image == nil)
        .task {
            let baseName = (canonicalName as NSString).deletingPathExtension
            let proxyURL = ProxyGenerationActor.proxiesDirectory()
                .appendingPathComponent(baseName + ".jpg")
            let loaded = await Task.detached(priority: .utility) {
                NSImage(contentsOf: proxyURL)
            }.value
            image = loaded
        }
    }
}

// FlowLayout is defined in MetadataExtractionSheet.swift and shared across the app.
