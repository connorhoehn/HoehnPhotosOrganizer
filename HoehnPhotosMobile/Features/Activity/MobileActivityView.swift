import SwiftUI
import HoehnPhotosCore

struct MobileActivityView: View {

    var isEmbedded: Bool = false

    @Environment(\.appDatabase) private var appDatabase
    @State private var events: [ActivityEvent] = []
    @State private var isLoading = true
    @State private var kindFilter: Set<ActivityEventKind>? = nil
    @State private var selectedEvent: ActivityEvent? = nil
    @State private var eventLimit: Int = 50

    // MARK: - Filter chip definitions

    private static let filterCategories: [(id: String, label: String, kinds: Set<ActivityEventKind>?)] = [
        ("all",         "All",         nil),
        ("imports",     "Imports",     [.importBatch]),
        ("studio",      "Studio",      [.pipelineRun]),
        ("print",       "Print",       [.printJob, .printAttempt]),
        ("adjustments", "Adjustments", [.adjustment, .colorGrade, .reAdjustment]),
        ("notes",       "Notes",       [.note]),
    ]

    private var selectedChipId: String? {
        guard let filter = kindFilter else { return "all" }
        return Self.filterCategories.first(where: { $0.kinds == filter })?.id
    }

    private var filterChips: [FilterChip] {
        Self.filterCategories.map { cat in
            FilterChip(id: cat.id, label: cat.label)
        }
    }

    // MARK: - Filtered + Grouped events

    private var filteredEvents: [ActivityEvent] {
        guard let filter = kindFilter else { return events }
        return events.filter { filter.contains($0.kind) }
    }

    private var groupedEvents: [(String, [ActivityEvent])] {
        let grouped = Dictionary(grouping: filteredEvents) { event -> String in
            HPDateFormatter.relativeLabel(for: event.occurredAt)
        }
        return grouped.sorted { a, b in
            if a.key == "Today" { return true }
            if b.key == "Today" { return false }
            if a.key == "Yesterday" { return true }
            if b.key == "Yesterday" { return false }
            // Sort by actual date of first event, not string label
            let dateA = a.value.first?.occurredAt ?? .distantPast
            let dateB = b.value.first?.occurredAt ?? .distantPast
            return dateA > dateB
        }
    }

    var body: some View {
        if isEmbedded {
            innerContent
        } else {
            NavigationStack {
                innerContent
            }
        }
    }

    private var innerContent: some View {
        contentView
            .navigationTitle("Activity")
            .task { await loadEvents() }
            .refreshable { await loadEvents() }
            .sheet(item: $selectedEvent) { event in
                MobileEventDetailView(event: event)
            }
    }

    @ViewBuilder
    private var contentView: some View {
        if isLoading {
            SkeletonActivityList(sectionCount: 2, rowsPerSection: 3)
        } else if events.isEmpty && kindFilter == nil {
            EmptyStateView(
                icon: "clock",
                title: "No Activity",
                message: "Import photos and work on jobs to see activity here."
            )
        } else {
            VStack(spacing: 0) {
                FilterChipBar(
                    chips: filterChips,
                    selectedId: selectedChipId
                ) { chipId in
                    let selected = Self.filterCategories.first(where: { $0.id == chipId })
                    kindFilter = selected?.kinds
                }

                if filteredEvents.isEmpty {
                    filteredEmptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(groupedEvents, id: \.0) { section, sectionEvents in
                            Section {
                                ForEach(sectionEvents) { event in
                                    Button {
                                        selectedEvent = event
                                    } label: {
                                        HStack(spacing: HPSpacing.md) {
                                            Image(systemName: sfSymbol(for: event.kind))
                                                .foregroundStyle(HPColor.chipActive)
                                                .frame(width: 28, height: 28)
                                                .background(Circle().fill(HPColor.chipActive.opacity(0.2)))
                                            VStack(alignment: .leading, spacing: HPSpacing.xxs) {
                                                Text(event.title).font(HPFont.body)
                                                if let detail = event.detail {
                                                    Text(detail)
                                                        .font(HPFont.cardSubtitle)
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(2)
                                                }
                                                Text(HPDateFormatter.relative(event.occurredAt))
                                                    .font(HPFont.timestamp)
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel("\(event.title). \(event.detail ?? "")")
                                    .accessibilityValue(event.occurredAt.formatted(date: .abbreviated, time: .shortened))
                                    .accessibilityAddTraits(.isButton)
                                }
                            } header: {
                                SectionHeader(section, style: .inline)
                            }
                        }

                        if events.count >= eventLimit {
                            Button {
                                eventLimit += 50
                                Task { await loadEvents() }
                            } label: {
                                Text("Load more")
                                    .font(HPFont.bodyStrong)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, HPSpacing.sm)
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Per-Filter Empty States

    @ViewBuilder
    private var filteredEmptyState: some View {
        EmptyStateView(
            icon: emptyStateIcon,
            title: emptyStateTitle,
            message: emptyStateSubtitle
        )
        .padding(.top, HPSpacing.xxxl)
    }

    private var emptyStateIcon: String {
        guard let filter = kindFilter else { return "clock" }
        if filter.contains(.importBatch) { return "square.and.arrow.down" }
        if filter.contains(.pipelineRun) { return "paintbrush.pointed" }
        if filter.contains(.printJob)    { return "printer" }
        if filter.contains(.adjustment)  { return "slider.horizontal.3" }
        if filter.contains(.note)        { return "note.text" }
        return "tray"
    }

    private var emptyStateTitle: String {
        guard let filter = kindFilter else { return "No Activity" }
        if filter.contains(.importBatch) { return "No Imports" }
        if filter.contains(.pipelineRun) { return "No Studio Activity" }
        if filter.contains(.printJob)    { return "No Print Activity" }
        if filter.contains(.adjustment)  { return "No Adjustments" }
        if filter.contains(.note)        { return "No Notes" }
        return "No Events"
    }

    private var emptyStateSubtitle: String {
        guard let filter = kindFilter else { return "Import photos and work on jobs to see activity here." }
        if filter.contains(.importBatch) { return "Imported photos will appear here." }
        if filter.contains(.pipelineRun) { return "Studio renders and exports will appear here." }
        if filter.contains(.printJob)    { return "Print jobs and attempts will appear here." }
        if filter.contains(.adjustment)  { return "Edits and color grades will appear here." }
        if filter.contains(.note)        { return "Add notes to photos to see them here." }
        return "They will appear here as you work."
    }

    // MARK: - SF Symbol Mapping

    private func sfSymbol(for kind: ActivityEventKind) -> String {
        switch kind {
        case .importBatch:        return "square.and.arrow.down"
        case .frameExtraction:    return "film.stack"
        case .adjustment:         return "slider.horizontal.3"
        case .colorGrade:         return "paintpalette"
        case .printAttempt:       return "printer"
        case .batchTransform:     return "wand.and.stars"
        case .reAdjustment:       return "arrow.uturn.backward"
        case .note:               return "note.text"
        case .todo:               return "checklist"
        case .rollback:           return "arrow.uturn.backward.circle"
        case .pipelineRun:        return "gearshape.2"
        case .editorialReview:    return "text.bubble"
        case .faceDetection:      return "person.crop.rectangle"
        case .metadataEnrichment: return "tag"
        case .printJob:           return "printer.fill"
        case .scanAttachment:     return "doc.viewfinder"
        case .aiSummary:          return "brain"
        case .search:             return "magnifyingglass"
        }
    }

    // MARK: - Data Loading

    private func loadEvents() async {
        guard let db = appDatabase else { return }
        events = (try? await MobileActivityRepository(db: db).fetchRecent(limit: eventLimit)) ?? []
        isLoading = false
    }
}
