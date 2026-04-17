import SwiftUI
import MapKit

// MARK: - SearchPage

enum SearchPage: String, CaseIterable, Identifiable {
    case search  = "Search"
    case people  = "People"
    case map     = "Map"
    case history = "History"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .search:  return "magnifyingglass"
        case .people:  return "person.2"
        case .map:     return "map"
        case .history: return "clock"
        }
    }
}

// MARK: - SearchHostView

/// Top-level wrapper for the Search section that adds sub-page navigation.
/// Routes between: Search, People, Map, History.
struct SearchHostView: View {

    @ObservedObject var viewModel: LibraryViewModel
    let db: AppDatabase

    @State private var currentPage: SearchPage = .search

    var body: some View {
        VStack(spacing: 0) {
            pageTabStrip
            Divider()

            Group {
                switch currentPage {
                case .search:
                    SearchExperienceView(viewModel: viewModel, db: db)

                case .people:
                    SearchPeopleView(db: db, viewModel: viewModel)

                case .map:
                    MapPhotoView(
                        photoRepo: viewModel.photoRepo,
                        selectedLocationFilter: .constant(nil)
                    )

                case .history:
                    SearchHistoryView(db: db) { query in
                        viewModel.searchText = query
                        currentPage = .search
                        Task { await viewModel.executeSearch() }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { syncBreadcrumb() }
        .onChange(of: currentPage) { _, _ in syncBreadcrumb() }
    }

    // MARK: - Breadcrumb Sync

    private func syncBreadcrumb() {
        viewModel.searchBreadcrumbSubtitle = currentPage.rawValue
    }

    // MARK: - Page Tab Strip

    private var pageTabStrip: some View {
        HStack(spacing: 2) {
            ForEach(SearchPage.allCases) { page in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        currentPage = page
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: page.icon)
                            .font(.system(size: 10))
                        Text(page.rawValue)
                            .font(.system(size: 10, weight: currentPage == page ? .semibold : .regular))
                    }
                    .foregroundStyle(currentPage == page ? .primary : .tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(currentPage == page ? Color.primary.opacity(0.08) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - SearchPeopleView

/// Browse-by-person entry point. Shows labeled people as larger chips with a
/// name filter field. Tapping a person runs a search for their photos.
struct SearchPeopleView: View {

    let db: AppDatabase
    @ObservedObject var viewModel: LibraryViewModel

    @State private var nameFilter: String = ""
    @State private var representatives: [FaceGalleryRecord] = []
    @State private var loaded = false
    @State private var hasAnyEmbeddings = false

    private var filtered: [FaceGalleryRecord] {
        guard !nameFilter.isEmpty else { return representatives }
        let q = nameFilter.lowercased()
        return representatives.filter { ($0.personName ?? "").lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Filter by name", text: $nameFilter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !nameFilter.isEmpty {
                    Button { nameFilter = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if !loaded {
                Spacer()
                ProgressView()
                Spacer()
            } else if representatives.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: hasAnyEmbeddings ? "person.badge.key" : "person.slash")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text(hasAnyEmbeddings
                         ? "Label people in the People tab to browse here."
                         : "No faces indexed yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
                Spacer()
            } else if filtered.isEmpty {
                Spacer()
                Text("No people matching \"\(nameFilter)\"")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 16)], spacing: 16) {
                        ForEach(filtered) { record in
                            PersonCard(record: record, viewModel: viewModel, db: db)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            guard !loaded else { return }
            loaded = true
            let faceRepo = FaceEmbeddingRepository(db: db)
            hasAnyEmbeddings = (try? await faceRepo.fetchHasAnyEmbeddings()) ?? false
            if let reps = try? await faceRepo.fetchLabeledPersonRepresentatives() {
                representatives = reps
            }
        }
    }
}

// MARK: - PersonCard

private struct PersonCard: View {
    let record: FaceGalleryRecord
    @ObservedObject var viewModel: LibraryViewModel
    let db: AppDatabase

    @State private var faceImage: NSImage? = nil

    var body: some View {
        Button {
            guard let personName = record.personName,
                  let personId = record.embedding.personId else { return }
            Task {
                await viewModel.searchByPerson(
                    personId: personId, personName: personName, faceImage: faceImage, db: db
                )
            }
        } label: {
            VStack(spacing: 8) {
                Group {
                    if let img = faceImage {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color(nsColor: .controlBackgroundColor)
                            .overlay(
                                Image(systemName: "person.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.tertiary)
                            )
                    }
                }
                .frame(width: 72, height: 72)
                .clipShape(Circle())

                Text(record.personName ?? "Unknown")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
        .buttonStyle(.plain)
        .task {
            guard faceImage == nil else { return }
            faceImage = await FaceCropCache.shared.crop(
                id: record.id,
                proxyURL: record.proxyURL,
                bbox: record.bbox
            )
        }
    }
}

// MARK: - SearchHistoryView

/// Full-page list of search history with timestamps and the ability to re-run searches.
struct SearchHistoryView: View {

    let db: AppDatabase
    var onRerun: (String) -> Void

    @State private var events: [ActivityEvent] = []
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            if !loaded {
                Spacer()
                ProgressView()
                Spacer()
            } else if events.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No search history yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Your searches will appear here so you can revisit them.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(32)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(events) { event in
                            SearchHistoryRow(event: event) {
                                onRerun(event.title)
                            }
                            Divider().padding(.leading, 44)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            guard !loaded else { return }
            loaded = true
            do {
                let repo = ActivityEventRepository(db: db)
                events = try await repo.fetchRecent(kind: .search, limit: 50)
            } catch {
                // Silently fail — history is non-critical
            }
        }
    }
}

// MARK: - SearchHistoryRow

private struct SearchHistoryRow: View {
    let event: ActivityEvent
    let onTap: () -> Void

    private var timeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: event.occurredAt, relativeTo: Date())
    }

    private var resultCount: String? {
        guard let metadata = event.metadata,
              let data = metadata.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = json["result_count"] as? Int else { return nil }
        return "\(count) result\(count == 1 ? "" : "s")"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    HStack(spacing: 6) {
                        Text(timeString)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        if let count = resultCount {
                            Text("·")
                                .font(.system(size: 11))
                                .foregroundStyle(.quaternary)
                            Text(count)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer()

                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
