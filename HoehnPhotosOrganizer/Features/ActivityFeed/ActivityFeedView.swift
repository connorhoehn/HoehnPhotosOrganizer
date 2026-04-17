import SwiftUI
import GRDB

// MARK: - ActivityFeedView

/// Social-style activity feed with inline folio-style navigation.
/// Tapping a card navigates to a full detail view with a breadcrumb trail.
/// The "Add Note" action remains a sheet modal.
struct ActivityFeedView: View {

    @State private var viewModel: ActivityFeedViewModel
    @State private var navigationPath = NavigationPath()
    @State private var showNoteSheet = false
    @State private var isAnalyzingAI = false
    @State private var kindFilter: Set<ActivityEventKind>? = nil
    @State private var searchText: String = ""
    @State private var showOnlyFailed = false
    @State private var expandedGroups: Set<String> = []

    // Observe the pinned store so the feed reacts to pin/unpin.
    @State private var pinnedStore = PinnedNotesStore.shared

    var onResumeInPrintLab: ((PrintJobSnapshot) -> Void)?
    var onApplyAISuggestion: ((PrintJobSnapshot, Double, Double) -> Void)?
    var onSendBatchToWorkflow: (([String]) -> Void)?
    var onOpenInStudio: (() -> Void)?
    var onOpenInJobs: ((String?) -> Void)?
    var onOpenInCurveLab: (() -> Void)?

    init(viewModel: ActivityFeedViewModel,
         onResumeInPrintLab: ((PrintJobSnapshot) -> Void)? = nil,
         onApplyAISuggestion: ((PrintJobSnapshot, Double, Double) -> Void)? = nil,
         onSendBatchToWorkflow: (([String]) -> Void)? = nil,
         onOpenInStudio: (() -> Void)? = nil,
         onOpenInJobs: ((String?) -> Void)? = nil,
         onOpenInCurveLab: (() -> Void)? = nil) {
        _viewModel = State(initialValue: viewModel)
        self.onResumeInPrintLab = onResumeInPrintLab
        self.onApplyAISuggestion = onApplyAISuggestion
        self.onSendBatchToWorkflow = onSendBatchToWorkflow
        self.onOpenInStudio = onOpenInStudio
        self.onOpenInJobs = onOpenInJobs
        self.onOpenInCurveLab = onOpenInCurveLab
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            timelineContent
                .navigationTitle("Activity")
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showOnlyFailed.toggle()
                            }
                        } label: {
                            Label("Failures", systemImage: showOnlyFailed ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                                .foregroundStyle(showOnlyFailed ? .red : .secondary)
                        }
                        .help(showOnlyFailed ? "Showing failed events only — click to clear" : "Show failed events only")
                    }
                    ToolbarItem(placement: .automatic) {
                        Button {
                            showNoteSheet = true
                        } label: {
                            Label("Add Note", systemImage: "square.and.pencil")
                        }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                    }
                }
                .navigationDestination(for: ActivityEvent.self) { event in
                    VStack(spacing: 0) {
                        breadcrumb(for: event)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                            .padding(.bottom, 6)
                        detailDestination(for: event)
                    }
                    .navigationTitle("")
                }
        }
        .sheet(isPresented: $showNoteSheet) {
            ActivityNoteInputSheet(
                onDismiss: { showNoteSheet = false },
                eventService: viewModel.eventService
            )
        }
        .task {
            viewModel.startObserving()
        }
        .onDisappear {
            viewModel.stopObserving()
        }
    }

    // MARK: - Timeline content (home state)

    /// Infers whether an event is a failure based on its title or detail text.
    private func isFailed(_ event: ActivityEvent) -> Bool {
        let haystack = ((event.title) + " " + (event.detail ?? "")).lowercased()
        return haystack.contains("failed") ||
               haystack.contains("error") ||
               haystack.contains("failure") ||
               haystack.contains("could not") ||
               haystack.contains("unable to")
    }

    /// All root events passing the kind chip filter, text search, and failure filter.
    private var filteredEvents: [ActivityEvent] {
        var events = viewModel.rootEvents
        if let filter = kindFilter {
            events = events.filter { filter.contains($0.kind) }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            events = events.filter {
                $0.title.lowercased().contains(query) ||
                ($0.detail?.lowercased().contains(query) ?? false)
            }
        }
        if showOnlyFailed {
            events = events.filter { isFailed($0) }
        }
        return events
    }

    // MARK: - Date grouping helpers

    private func sectionLabel(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.month(.wide).day().year())
    }

    /// Display items built from unpinned events, with consecutive studio renders grouped.
    private var unpinnedDisplayItems: [ActivityDisplayItem] {
        viewModel.buildDisplayItems(from: unpinnedEvents)
    }

    /// Groups display items by their calendar day (most recent first).
    private var groupedUnpinnedDisplayItems: [(label: String, items: [ActivityDisplayItem])] {
        let cal = Calendar.current
        var seen: [Date: [ActivityDisplayItem]] = [:]
        for item in unpinnedDisplayItems {
            let day = cal.startOfDay(for: item.occurredAt)
            seen[day, default: []].append(item)
        }
        return seen.keys.sorted(by: >).map { day in
            (label: sectionLabel(for: day), items: seen[day]!)
        }
    }

    /// Note events that are pinned, ordered by pin-list order (most recently pinned first).
    /// Only shown when no active filter/search would exclude them.
    private var pinnedNoteEvents: [ActivityEvent] {
        // Don't show pinned section if the current filter hides notes.
        if let filter = kindFilter, !filter.contains(.note) { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return pinnedStore.pinnedIds.compactMap { id in
            viewModel.rootEvents.first { $0.id == id }
        }.filter { event in
            guard query.isEmpty else {
                return event.title.lowercased().contains(query) ||
                       (event.detail?.lowercased().contains(query) ?? false)
            }
            return true
        }
    }

    /// Regular chronological events minus any that are currently pinned.
    private var unpinnedEvents: [ActivityEvent] {
        let pinned = Set(pinnedStore.pinnedIds)
        return filteredEvents.filter { !pinned.contains($0.id) }
    }

    /// Human-readable label for the currently active filter chip.
    /// Maps the kind set back to the chip label so the empty state says
    /// "No Studio events" instead of a random member like "No studio export events".
    private var activeFilterLabel: String {
        guard let filter = kindFilter else { return "matching" }
        let chipMap: [(label: String, kinds: Set<ActivityEventKind>)] = [
            ("import", [.importBatch]),
            ("Studio", [.studioRender, .studioVersion, .studioExport, .studioPrintLab]),
            ("print job", [.printJob]),
            ("adjustment", [.adjustment, .versionCreated]),
            ("note", [.note]),
            ("job", [.jobCreated, .jobCompleted, .jobSplit]),
            ("CurveLab", [.curveLinearized, .curveSaved, .curveBlended]),
            ("People", [.faceDetection]),
            ("AI", [.aiSummary]),
        ]
        return chipMap.first(where: { $0.kinds == filter })?.label ?? filter.first?.filterLabel ?? "matching"
    }

    /// Whether any filter/search is active (used to decide which empty state to show).
    private var isFiltered: Bool {
        kindFilter != nil ||
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        showOnlyFailed
    }

    // MARK: - AI cost summary

    /// Sum of `estimated_cost_usd` from all root `editorialReview` events this calendar month.
    private var monthlyAICostUSD: Double {
        let cal = Calendar.current
        let now = Date()
        return viewModel.rootEvents
            .filter {
                $0.kind == .editorialReview &&
                cal.isDate($0.occurredAt, equalTo: now, toGranularity: .month)
            }
            .compactMap { event -> Double? in
                guard let meta = event.metadata,
                      let data = meta.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let cost = json["estimated_cost_usd"] as? Double
                else { return nil }
                return cost
            }
            .reduce(0, +)
    }

    private var timelineContent: some View {
        ScrollView {
            if viewModel.rootEvents.isEmpty {
                emptyState
                    .padding(.top, 80)
            } else {
                VStack(spacing: 0) {
                    // Search field
                    searchBar
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 4)

                    // Kind filter chips
                    filterBar
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)

                    // AI cost summary card (only when no text search active)
                    if monthlyAICostUSD > 0 && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        AICostSummaryCard(costUSD: monthlyAICostUSD)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 6)
                    }

                    LazyVStack(spacing: 10) {
                        // Pinned notes section
                        if !pinnedNoteEvents.isEmpty {
                            pinnedSection
                        }

                        // Main chronological feed grouped by date
                        ForEach(groupedUnpinnedDisplayItems, id: \.label) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                // Date section header
                                HStack(spacing: 5) {
                                    Text(group.label)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Rectangle()
                                        .fill(Color.secondary.opacity(0.2))
                                        .frame(height: 1)
                                }
                                .padding(.horizontal, 2)
                                .padding(.top, 4)

                                ForEach(group.items) { item in
                                    switch item {
                                    case .single(let event):
                                        HStack(alignment: .top, spacing: 6) {
                                            if isFailed(event) {
                                                Image(systemName: "exclamationmark.triangle.fill")
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(.red)
                                                    .padding(.top, 10)
                                            }
                                            ActivityThreadCard(
                                                event: event,
                                                children: viewModel.childrenCache[event.id],
                                                isExpanded: viewModel.expandedEventIds.contains(event.id),
                                                onToggleExpand: { viewModel.toggleExpand(eventId: event.id) },
                                                onTap: { navigationPath.append(event) },
                                                proxyURL: viewModel.resolveProxyURL(for: event.photoAssetId),
                                                childProxyURLResolver: { viewModel.resolveProxyURL(for: $0) }
                                            )
                                        }

                                    case .group(let events, let medium):
                                        studioRenderGroupCard(events: events, medium: medium, groupId: item.id)

                                    case .importGroup(let events, let totalPhotos):
                                        importGroupCard(events: events, totalPhotos: totalPhotos, groupId: item.id)
                                    }
                                }
                            }
                        }

                        // Filtered empty state
                        if unpinnedDisplayItems.isEmpty && pinnedNoteEvents.isEmpty {
                            filteredEmptyState
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - Studio render group card

    private func studioRenderGroupCard(events: [ActivityEvent], medium: String, groupId: String) -> some View {
        let isExpanded = expandedGroups.contains(groupId)
        let latest = events.first!

        return VStack(alignment: .leading, spacing: 0) {
            // Collapsed summary card
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedGroups.remove(groupId)
                    } else {
                        expandedGroups.insert(groupId)
                    }
                }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    // Icon badge
                    ZStack {
                        Circle()
                            .fill(Color.purple.opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: "paintbrush.pointed.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.purple)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Studio render \u{00B7} \(medium) (\(events.count) iterations)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        if let detail = latest.detail, !detail.isEmpty {
                            Text("Latest: \(detail)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Text("\(events.count) render\(events.count == 1 ? "" : "s")")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.purple.opacity(0.1)))
                    }

                    Spacer(minLength: 4)

                    VStack(alignment: .trailing, spacing: 4) {
                        TimelineView(.periodic(from: .now, by: 60)) { ctx in
                            Text(latest.occurredAt.relativeVerbose(now: ctx.date))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded: show individual events
            if isExpanded {
                Divider()
                    .padding(.horizontal, 14)

                VStack(spacing: 6) {
                    ForEach(events) { event in
                        ActivityThreadCard(
                            event: event,
                            children: viewModel.childrenCache[event.id],
                            isExpanded: viewModel.expandedEventIds.contains(event.id),
                            onToggleExpand: { viewModel.toggleExpand(eventId: event.id) },
                            onTap: { navigationPath.append(event) },
                            proxyURL: viewModel.resolveProxyURL(for: event.photoAssetId),
                            childProxyURLResolver: { viewModel.resolveProxyURL(for: $0) }
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(
                topLeadingRadius: 10, bottomLeadingRadius: 10,
                bottomTrailingRadius: 0, topTrailingRadius: 0
            )
            .fill(Color.purple)
            .frame(width: 3)
        }
        .shadow(color: Color.black.opacity(0.05), radius: 3, x: 0, y: 1)
    }

    // MARK: - Import group card

    private func importGroupCard(events: [ActivityEvent], totalPhotos: Int, groupId: String) -> some View {
        let isExpanded = expandedGroups.contains(groupId)
        let latest = events.first!
        let batchCount = events.count

        return VStack(alignment: .leading, spacing: 0) {
            // Collapsed summary card
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedGroups.remove(groupId)
                    } else {
                        expandedGroups.insert(groupId)
                    }
                }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    // Icon badge
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: "square.and.arrow.down.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.blue)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Imported \(totalPhotos) photos (\(batchCount) batches)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        if let detail = latest.detail, !detail.isEmpty {
                            Text("Latest: \(detail)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Text("\(batchCount) batch\(batchCount == 1 ? "" : "es")")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.blue.opacity(0.1)))
                    }

                    Spacer(minLength: 4)

                    VStack(alignment: .trailing, spacing: 4) {
                        TimelineView(.periodic(from: .now, by: 60)) { ctx in
                            Text(latest.occurredAt.relativeVerbose(now: ctx.date))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded: show individual import events
            if isExpanded {
                Divider()
                    .padding(.horizontal, 14)

                VStack(spacing: 6) {
                    ForEach(events) { event in
                        ActivityThreadCard(
                            event: event,
                            children: viewModel.childrenCache[event.id],
                            isExpanded: viewModel.expandedEventIds.contains(event.id),
                            onToggleExpand: { viewModel.toggleExpand(eventId: event.id) },
                            onTap: { navigationPath.append(event) },
                            proxyURL: viewModel.resolveProxyURL(for: event.photoAssetId),
                            childProxyURLResolver: { viewModel.resolveProxyURL(for: $0) }
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(
                topLeadingRadius: 10, bottomLeadingRadius: 10,
                bottomTrailingRadius: 0, topTrailingRadius: 0
            )
            .fill(Color.blue)
            .frame(width: 3)
        }
        .shadow(color: Color.black.opacity(0.05), radius: 3, x: 0, y: 1)
    }

    // MARK: - Pinned section

    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Pinned")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)

            ForEach(pinnedNoteEvents) { event in
                ActivityThreadCard(
                    event: event,
                    children: viewModel.childrenCache[event.id],
                    isExpanded: viewModel.expandedEventIds.contains(event.id),
                    onToggleExpand: { viewModel.toggleExpand(eventId: event.id) },
                    onTap: { navigationPath.append(event) },
                    proxyURL: viewModel.resolveProxyURL(for: event.photoAssetId),
                    childProxyURLResolver: { viewModel.resolveProxyURL(for: $0) }
                )
            }

            Divider()
                .padding(.top, 2)
        }
    }

    // MARK: - Filtered empty state

    private var filteredEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: isFiltered ? "magnifyingglass" : "tray")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)

            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No results for \"\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))\"")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("Try a different search term or remove the filter.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if showOnlyFailed {
                Text("No failed events.")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("All recent activity completed successfully.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if kindFilter != nil {
                Text("No \(activeFilterLabel) events.")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("They will appear here as you work.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.horizontal, 32)
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)

            TextField("Search activity…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))

            if !searchText.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        searchText = ""
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.15), value: searchText.isEmpty)
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip(label: "All", kinds: nil)
                filterChip(label: "Imports", kinds: [.importBatch])
                filterChip(label: "Studio", kinds: [.studioRender, .studioVersion, .studioExport, .studioPrintLab])
                filterChip(label: "Print Jobs", kinds: [.printJob])
                filterChip(label: "Adjustments", kinds: [.adjustment, .versionCreated])
                filterChip(label: "Notes", kinds: [.note])
                filterChip(label: "Jobs", kinds: [.jobCreated, .jobCompleted, .jobSplit])
                filterChip(label: "CurveLab", kinds: [.curveLinearized, .curveSaved, .curveBlended])
                filterChip(label: "People", kinds: [.faceDetection])
                filterChip(label: "AI", kinds: [.aiSummary])
            }
        }
    }

    private func isStudioEvent(_ event: ActivityEvent) -> Bool {
        [.studioRender, .studioVersion, .studioExport, .studioPrintLab].contains(event.kind)
    }

    private func isJobEvent(_ event: ActivityEvent) -> Bool {
        [.jobCreated, .jobCompleted, .jobSplit].contains(event.kind)
    }

    private func isCurveLabEvent(_ event: ActivityEvent) -> Bool {
        [.curveLinearized, .curveSaved, .curveBlended].contains(event.kind)
    }

    private func filterChip(label: String, kinds: Set<ActivityEventKind>?) -> some View {
        let isActive = kindFilter == kinds
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                kindFilter = kinds
            }
        } label: {
            Text(label)
                .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? .white : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(isActive ? Color.accentColor : Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Breadcrumb

    private func breadcrumb(for event: ActivityEvent) -> some View {
        HStack(spacing: 4) {
            Button {
                navigationPath = NavigationPath()
            } label: {
                Text("Activity")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)

            Text(event.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - Detail destination (inline navigation)

    @ViewBuilder
    private func detailDestination(for event: ActivityEvent) -> some View {
        if event.kind == .printJob {
            printJobDetail(event: event)
        } else if event.kind == .importBatch {
            importBatchDetail(event: event)
        } else if event.kind == .search {
            SearchEventDetailView(event: event)
        } else {
            EventDetailView(
                event: event,
                viewModel: viewModel,
                onOpenInStudio: isStudioEvent(event) ? {
                    navigationPath = NavigationPath()
                    onOpenInStudio?()
                } : nil,
                onOpenInJobs: isJobEvent(event) ? { jobId in
                    navigationPath = NavigationPath()
                    onOpenInJobs?(jobId)
                } : nil,
                onOpenInCurveLab: isCurveLabEvent(event) ? {
                    navigationPath = NavigationPath()
                    onOpenInCurveLab?()
                } : nil
            )
        }
    }

    // MARK: - Print Job Detail (inline)

    @ViewBuilder
    private func printJobDetail(event: ActivityEvent) -> some View {
        let snapshot = PrintJobSnapshot.decode(from: event.metadata)
        let children = viewModel.childrenCache[event.id] ?? []
        PrintJobThreadView(
            event: event,
            children: children,
            snapshot: snapshot,
            onResume: { snap in
                navigationPath = NavigationPath()
                onResumeInPrintLab?(snap)
            },
            onAddNote: { body in
                Task {
                    try? await viewModel.addNote(body: body, toEvent: event.id)
                    refreshChildren(for: event.id)
                }
            },
            onAttachScan: {
                Task {
                    let scansDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                        .appendingPathComponent("HoehnPhotosOrganizer/Scans", isDirectory: true)
                    if let contents = try? FileManager.default.contentsOfDirectory(at: scansDir, includingPropertiesForKeys: [.creationDateKey]),
                       let latest = contents.sorted(by: {
                           let d1 = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                           let d2 = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                           return d1 > d2
                       }).first {
                        try? await viewModel.eventService.emitScanAttachment(
                            parentEventId: event.id,
                            photoAssetId: event.photoAssetId,
                            title: "Scan: \(latest.lastPathComponent)",
                            detail: nil,
                            filePath: latest.path
                        )
                        refreshChildren(for: event.id)
                    }
                }
            },
            onApplySuggestion: { center, range in
                guard let snap = snapshot else { return }
                navigationPath = NavigationPath()
                onApplyAISuggestion?(snap, center, range)
            },
            onRequestAI: {
                guard !isAnalyzingAI, let snap = snapshot else { return }
                isAnalyzingAI = true
                Task {
                    defer { isAnalyzingAI = false }
                    let service = PrintJobAnalysisService()
                    do {
                        let result = try await service.analyze(snapshot: snap, children: children)
                        var suggestions: [String: Any] = [:]
                        if let center = result.refinedBrightnessCenter {
                            suggestions["refinedBrightnessCenter"] = center
                        }
                        if let range = result.refinedRange {
                            suggestions["refinedRange"] = range
                        }
                        if let action = result.suggestedAction {
                            suggestions["suggestedAction"] = action
                        }
                        try? await viewModel.eventService.emitAISummary(
                            parentEventId: event.id,
                            photoAssetId: event.photoAssetId,
                            detail: result.summary + (result.suggestedAction.map { "\n\nSuggested: \($0)" } ?? ""),
                            suggestions: suggestions.isEmpty ? nil : suggestions
                        )
                        refreshChildren(for: event.id)
                    } catch {
                        // Best-effort — AI analysis failure is non-fatal
                    }
                }
            }
        )
        .frame(minWidth: 600, minHeight: 500)
        .task {
            if viewModel.childrenCache[event.id] == nil {
                viewModel.toggleExpand(eventId: event.id)
            }
        }
    }

    // MARK: - Import Batch Detail (inline)

    @ViewBuilder
    private func importBatchDetail(event: ActivityEvent) -> some View {
        let children = viewModel.childrenCache[event.id] ?? []
        ImportBatchThreadView(
            event: event,
            children: children,
            photos: viewModel.batchPhotos,
            onSendToWorkflow: { photoIds in
                navigationPath = NavigationPath()
                onSendBatchToWorkflow?(photoIds)
            },
            onAddNote: { body in
                Task {
                    try? await viewModel.addNote(body: body, toEvent: event.id)
                    refreshChildren(for: event.id)
                }
            },
            onApplyMetadata: { photoIDs, location, gear, tags in
                Task {
                    await viewModel.applyBulkMetadata(
                        photoIDs: photoIDs,
                        location: location,
                        gear: gear,
                        tags: tags
                    )
                }
            },
            onOpenInJobs: { jobId in
                navigationPath = NavigationPath()
                onOpenInJobs?(jobId)
            }
        )
        .frame(minWidth: 700, minHeight: 550)
        .task {
            await viewModel.fetchPhotosForBatch(eventId: event.id)
        }
    }

    private func refreshChildren(for eventId: String) {
        viewModel.childrenCache.removeValue(forKey: eventId)
        viewModel.toggleExpand(eventId: eventId)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 44))
                .foregroundStyle(.quaternary)

            Text("No activity yet.")
                .font(.headline)
                .foregroundStyle(.primary)

            Text("Import some photos to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }
}

// MARK: - AICostSummaryCard

/// Compact banner showing this month's AI API spend, computed from editorial review events.
private struct AICostSummaryCard: View {

    let costUSD: Double
    @State private var isExpanded: Bool = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.purple)

                VStack(alignment: .leading, spacing: 1) {
                    Text("This month's AI costs")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(String(format: "$%.2f", costUSD))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.primary)
                }

                Spacer()

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.purple.opacity(0.06))
                    .stroke(Color.purple.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Total estimated Claude API spend for editorial reviews this month")
    }
}

// MARK: - Preview

#Preview("ActivityFeedView") {
    Text("ActivityFeedView requires AppDatabase and ActivityEventRepository/Service.\nUse in ContentView context.")
        .foregroundStyle(.secondary)
        .padding()
        .frame(width: 400, height: 300)
}
