import SwiftUI
import GRDB
import UniformTypeIdentifiers

// MARK: - JobsView

struct JobsView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.appDatabase) private var db
    @Environment(\.activityEventService) private var activityService

    @State private var rootJobs: [TriageJob] = []
    @State private var childJobsMap: [String: [TriageJob]] = [:]
    @State private var expandedJobIds: Set<String> = []
    @State private var selectedJobId: String?
    @State private var isLoading = true
    @State private var taskReadiness: [String: (completed: Int, total: Int)] = [:]
    @State private var searchText = ""
    @State private var statusFilter: JobStatusFilter = .all
    @State private var filterExpanded = false
    @State private var hoveredJobId: String?

    enum JobStatusFilter: String, CaseIterable {
        case all      = "All"
        case open     = "Open"
        case complete = "Complete"
        case archived = "Archived"
    }

    var body: some View {
        HStack(spacing: 0) {
            jobListPanel
                .frame(width: 280)
                .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            jobDetailPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .task { await loadJobs() }
        .onChange(of: viewModel.pendingJobSelection) { _, newValue in
            if let jobId = newValue {
                selectedJobId = jobId
                viewModel.pendingJobSelection = nil
            }
        }
        .onKeyPress("]") { selectAdjacentOpenJob(direction: .next); return .handled }
        .onKeyPress("[") { selectAdjacentOpenJob(direction: .previous); return .handled }
        .onKeyPress(.downArrow) { selectAdjacentVisibleJob(direction: .next); return .handled }
        .onKeyPress(.upArrow) { selectAdjacentVisibleJob(direction: .previous); return .handled }
    }

    // MARK: - Keyboard Navigation

    private enum NavigationDirection { case next, previous }

    private func selectAdjacentOpenJob(direction: NavigationDirection) {
        let openJobs = rootJobs.filter { $0.status == .open }
        guard !openJobs.isEmpty else { return }

        guard let currentId = selectedJobId,
              let currentIndex = openJobs.firstIndex(where: { $0.id == currentId }) else {
            selectedJobId = openJobs.first?.id
            return
        }

        let nextIndex: Int
        switch direction {
        case .next:
            nextIndex = (currentIndex + 1) % openJobs.count
        case .previous:
            nextIndex = (currentIndex - 1 + openJobs.count) % openJobs.count
        }
        selectedJobId = openJobs[nextIndex].id
    }

    /// Flat list of all visible job IDs in display order (respecting expanded parents).
    private var visibleJobIds: [String] {
        var ids: [String] = []
        let open = filteredJobs.filter { $0.status == .open }
        for job in open {
            ids.append(job.id)
            if expandedJobIds.contains(job.id), let children = childJobsMap[job.id] {
                ids.append(contentsOf: children.map(\.id))
            }
        }
        let done = filteredJobs.filter { $0.status != .open }
        for job in done {
            ids.append(job.id)
        }
        return ids
    }

    private func selectAdjacentVisibleJob(direction: NavigationDirection) {
        let ids = visibleJobIds
        guard !ids.isEmpty else { return }

        guard let currentId = selectedJobId,
              let currentIndex = ids.firstIndex(of: currentId) else {
            selectedJobId = ids.first
            return
        }

        let nextIndex: Int
        switch direction {
        case .next:
            nextIndex = min(currentIndex + 1, ids.count - 1)
        case .previous:
            nextIndex = max(currentIndex - 1, 0)
        }
        selectedJobId = ids[nextIndex]
    }

    // MARK: - Job List

    private var jobListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Jobs").font(.title2.bold())
                Spacer()
                if openCount > 0 {
                    Text("\(openCount) open").font(.caption).foregroundStyle(.secondary)
                }
                if readyCount > 0 {
                    Text("\(readyCount) ready").font(.caption).foregroundStyle(.green)
                }
                if completeCount > 0 {
                    Button("Archive Done") {
                        Task { await archiveCompleteJobs() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help("Archive all completed jobs")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()

            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 12))
                TextField("Search jobs…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            // Status filter — collapsible
            DisclosureGroup(isExpanded: $filterExpanded) {
                Picker("", selection: $statusFilter) {
                    ForEach(JobStatusFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.top, 4)
            } label: {
                HStack(spacing: 4) {
                    Text("Filter")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    if statusFilter != .all {
                        Text(statusFilter.rawValue)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.blue.opacity(0.2), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            Divider()

            if isLoading {
                Spacer(); ProgressView().frame(maxWidth: .infinity); Spacer()
            } else if rootJobs.isEmpty {
                emptyListState
            } else if filteredJobs.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "magnifyingglass").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("No matching jobs").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        let open = filteredJobs.filter { $0.status == .open }
                        if !open.isEmpty {
                            sectionLabel("Open")
                            ForEach(open) { job in
                                jobRow(job, depth: 0)
                                if expandedJobIds.contains(job.id),
                                   let children = childJobsMap[job.id] {
                                    ForEach(children) { child in jobRow(child, depth: 1) }
                                }
                            }
                        }
                        let done = filteredJobs.filter { $0.status != .open }
                        if !done.isEmpty {
                            sectionLabel("Completed").padding(.top, 12)
                            ForEach(done) { job in jobRow(job, depth: 0) }
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 8)
                }
            }
        }
    }

    @ViewBuilder
    private var jobDetailPanel: some View {
        if let jobId = selectedJobId, let job = findJob(jobId) {
            JobDetailView(
                job: job,
                viewModel: viewModel,
                onJobChanged: { await loadJobs() },
                expandParentAfterSplit: { parentId in
                    expandedJobIds.insert(parentId)
                    // Select the first child if available
                    if let children = childJobsMap[parentId], let first = children.first {
                        selectedJobId = first.id
                    }
                }
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "checklist").font(.system(size: 48)).foregroundStyle(.tertiary)
                Text("Select a job").font(.title3).foregroundStyle(.secondary)
                Text("Import photos to create your first triage job.")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 240)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Row

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
    }

    private func jobRow(_ job: TriageJob, depth: Int) -> some View {
        let isSelected = selectedJobId == job.id
        let isHovered = hoveredJobId == job.id
        let readiness = taskReadiness[job.id]
        let hasChildren = childJobsMap[job.id] != nil && !(childJobsMap[job.id]?.isEmpty ?? true)
        let isExpanded = expandedJobIds.contains(job.id)

        return HStack(spacing: 8) {
            // Disclosure indicator for parent jobs
            if hasChildren && depth == 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if isExpanded {
                            expandedJobIds.remove(job.id)
                        } else {
                            expandedJobIds.insert(job.id)
                        }
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if depth == 1 {
                // Indent spacer for child rows (dot marker)
                Circle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 4, height: 4)
            }

            JobReadinessRing(
                completed: readiness?.completed ?? 0,
                total: readiness?.total ?? 0,
                status: job.status
            )
            .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(job.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(2).foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Text("\(job.photoCount) photo\(job.photoCount == 1 ? "" : "s")")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if hasChildren {
                        Text("· \(childJobsMap[job.id]?.count ?? 0) sub-jobs")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .padding(.leading, depth == 1 ? 20 : 0)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(
                isSelected
                    ? Color.accentColor.opacity(0.15)
                    : (isHovered ? Color.primary.opacity(0.04) : Color.clear)
            )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedJobId = job.id
        }
        .onHover { hovering in
            hoveredJobId = hovering ? job.id : nil
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(job.title), \(job.photoCount) photos")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var emptyListState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "tray").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("No jobs yet").font(.headline).foregroundStyle(.secondary)
            Text("Import photos to automatically create a triage job.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 220)
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    private var openCount: Int { rootJobs.filter { $0.status == .open }.count }
    private var completeCount: Int { rootJobs.filter { $0.status == .complete }.count }
    /// Jobs whose tasks are all complete but haven't been committed/archived yet.
    private var readyCount: Int {
        rootJobs.filter { $0.status == .open || $0.status == .complete }.filter { job in
            guard let r = taskReadiness[job.id], r.total > 0 else { return false }
            return r.completed == r.total
        }.count
    }

    private var filteredJobs: [TriageJob] {
        rootJobs.filter { job in
            let matchesSearch = searchText.isEmpty ||
                job.title.localizedCaseInsensitiveContains(searchText)
            let matchesStatus: Bool = {
                switch statusFilter {
                case .all:      return true
                case .open:     return job.status == .open
                case .complete: return job.status == .complete
                case .archived: return job.status == .archived
                }
            }()
            return matchesSearch && matchesStatus
        }
    }

    private func findJob(_ id: String) -> TriageJob? {
        rootJobs.first(where: { $0.id == id }) ??
            childJobsMap.values.flatMap { $0 }.first(where: { $0.id == id })
    }

    private func loadJobs() async {
        guard let db else { return }
        isLoading = true; defer { isLoading = false }
        let repo = TriageJobRepository(db: db)
        do {
            rootJobs = try await repo.fetchRootJobs()
            var map: [String: [TriageJob]] = [:]
            var readinessMap: [String: (completed: Int, total: Int)] = [:]
            for root in rootJobs {
                let children = try await repo.fetchChildJobs(parentId: root.id)
                if !children.isEmpty { map[root.id] = children }
                // Compute task readiness for non-archived jobs
                if root.status != .archived {
                    readinessMap[root.id] = (try? await repo.computeTaskCounts(jobId: root.id)) ?? (0, 0)
                }
                for child in children where child.status != .archived {
                    readinessMap[child.id] = (try? await repo.computeTaskCounts(jobId: child.id)) ?? (0, 0)
                }
            }
            childJobsMap = map
            taskReadiness = readinessMap
            if selectedJobId == nil {
                selectedJobId = rootJobs.first(where: { $0.status == .open })?.id ?? rootJobs.first?.id
            }
        } catch { print("[JobsView] \(error)") }
    }

    private func archiveCompleteJobs() async {
        guard let db else { return }
        let repo = TriageJobRepository(db: db)
        let completeJobs = rootJobs.filter { $0.status == .complete }
        for job in completeJobs {
            try? await repo.commitJobToLibrary(jobId: job.id, activityService: activityService)
        }
        await viewModel.refreshCurationCounts()
        await loadJobs()
    }
}

// MARK: - Job Detail View

struct JobDetailView: View {
    let job: TriageJob
    @ObservedObject var viewModel: LibraryViewModel
    var onJobChanged: (() async -> Void)? = nil
    var expandParentAfterSplit: ((String) -> Void)? = nil
    @Environment(\.appDatabase) private var db
    @Environment(\.activityEventService) private var activityService

    @State private var photos: [PhotoAsset] = []
    @State private var isLoading = true
    @State private var tasks: [JobTask] = []
    @State private var showReviewSheet = false
    @State private var developPhotos: [PhotoAsset] = []
    @State private var showPeopleWidget = false
    /// Photo IDs captured at the moment the people widget is opened, so the
    /// sheet content always uses the correct job-scoped set of IDs.
    @State private var peopleWidgetPhotoIds: [String] = []
    @State private var showCancelConfirm = false
    @State private var showCompleteConfirm = false
    @State private var previewPhoto: PhotoAsset?
    @State private var faceCount = 0
    @State private var identifiedCount = 0
    @State private var chatExpanded = false
    @State private var chatHovered = false
    @State private var chatCompleteness = 0
    /// Stable random sample for the filmstrip — set once in loadDetail, never reshuffled.
    @State private var displayedPhotos: [PhotoAsset] = []
    /// Filmstrip hover preview state
    @State private var hoveredPhotoId: String?
    @State private var hoverTimerTask: Task<Void, Never>?
    @State private var showHoverPreview = false
    /// Drag-to-reorder state for the filmstrip
    @State private var draggedPhotoId: String?
    @State private var showSplitSheet = false
    @State private var showDustRemoval = false
    @State private var ringCompletionPulse = false

    /// True when all photos have been rated (review task complete).
    private var isReviewDone: Bool {
        tasks.first(where: { $0.id == "review" })?.isComplete == true
    }

    /// Keeper photos from the current job.
    private var keeperPhotosInJob: [PhotoAsset] {
        photos.filter { $0.curationState == CurationState.keeper.rawValue }
    }

    private var isArchiveReady: Bool {
        guard !tasks.isEmpty else { return false }
        return tasks.allSatisfy { $0.isComplete }
    }

    var body: some View {
        HStack(spacing: 0) {
            // ── Main content ──────────────────────────────────────────
            VStack(spacing: 0) {
                jobHeader.padding(20)
                Divider()

                if isLoading {
                    HStack {
                        Spacer()
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("Loading job…")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(40)
                        Spacer()
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    // Photos filmstrip — always visible at top
                    photosFilmstrip

                    Divider()

                    // Middle: banners + tasks — scrollable
                    ScrollView {
                        VStack(spacing: 0) {
                            if job.status == .open {
                                stagedBanner.padding(.horizontal, 16).padding(.vertical, 10)
                                Divider()
                            }
                            if isArchiveReady {
                                archiveReadyBanner.padding(.horizontal, 16).padding(.vertical, 10)
                                Divider()
                            }
                            tasksSection
                        }
                    }

                    Divider()

                    // Chat — collapsed by default, semi-transparent, hover to preview
                    VStack(spacing: 0) {
                        // Expand / collapse handle
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { chatExpanded.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.purple)
                                Text("Job Assistant")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if chatCompleteness > 0 {
                                    Text("\(chatCompleteness)% documented")
                                        .font(.system(size: 10))
                                        .foregroundStyle(chatCompleteness >= 80 ? .green : .secondary)
                                        .monospacedDigit()
                                }
                                if chatExpanded {
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.2)) { chatExpanded = false }
                                    } label: {
                                        Text("Close")
                                            .font(.system(size: 10, weight: .medium))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(
                                                Capsule().fill(Color.primary.opacity(0.08))
                                            )
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    Image(systemName: "chevron.up")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Divider()

                        if chatExpanded || chatHovered {
                            JobChatSection(
                                job: job,
                                photos: photos,
                                faceCount: faceCount,
                                identifiedCount: identifiedCount,
                                completeness: $chatCompleteness
                            )
                            .frame(maxHeight: chatExpanded ? .infinity : 120)
                            .opacity(chatExpanded ? 1 : 0.7)
                        }
                    }
                    .onHover { hovering in
                        guard !chatExpanded else { return }
                        withAnimation(.easeInOut(duration: 0.15)) { chatHovered = hovering }
                    }
                    .opacity(chatExpanded ? 1 : 0.6)
            }
        }   // end main content VStack
        .frame(maxWidth: .infinity)

    }   // end HStack
    .task(id: job.id) {
        previewPhoto = nil
        await loadDetail()
    }
    .sheet(isPresented: $showReviewSheet, onDismiss: {
        developPhotos = []
        Task {
            await loadDetail()
            await viewModel.refreshCurationCounts()
            await onJobChanged?()
        }
    }) {
        if let db {
            JobReviewSheet(photos: developPhotos.isEmpty ? photos : developPhotos, db: db)
        }
    }
    .sheet(isPresented: $showSplitSheet) {
        SplitJobSheet(
            parentJob: job,
            photos: photos,
            onComplete: { [jobId = job.id] in
                // Reload jobs list first so childJobsMap is populated
                // before we try to expand/select a child.
                await onJobChanged?()
                await loadDetail()
                // Auto-expand parent to reveal new child jobs
                expandParentAfterSplit?(jobId)
            }
        )
    }
    .sheet(isPresented: $showPeopleWidget, onDismiss: { Task { await loadDetail() } }) {
        JobPeopleWidget(photoIds: peopleWidgetPhotoIds, onDone: {
            Task { await loadDetail() }
        })
    }
    .sheet(isPresented: $showDustRemoval) {
        BatchDustRemovalView(photoIds: photos.map(\.id))
    }
    .sheet(item: $previewPhoto) { photo in
        QuickPhotoPreview(initialPhoto: photo, allPhotos: photos, viewModel: viewModel)
    }
}

    // MARK: - Header

    private var jobHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(job.title).font(.title2.bold()).lineLimit(1)
                    statusBadge
                }
                Text("Created \(job.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            HStack(spacing: 8) {
                if job.status == .open {
                    Button("Mark Complete") {
                        let done = tasks.filter(\.isComplete).count
                        if done < tasks.count {
                            showCompleteConfirm = true
                        } else {
                            completeAndCommit()
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .confirmationDialog(
                        "Complete \"\(job.title)\"?",
                        isPresented: $showCompleteConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Complete & Add to Library") {
                            completeAndCommit()
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        let done = tasks.filter(\.isComplete).count
                        Text("\(tasks.count - done) of \(tasks.count) tasks are still incomplete. Completing will promote all \(job.photoCount) photos to your Library.")
                    }

                    if job.photoCount > 10 && job.parentJobId == nil {
                        Button {
                            showSplitSheet = true
                        } label: {
                            Label("Split Job", systemImage: "scissors")
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("Use AI to split this job into focused sub-jobs by time and location")
                    }

                }
                Button("Cancel Job", role: .destructive) {
                    showCancelConfirm = true
                }
                .buttonStyle(.bordered).controlSize(.small)
                .confirmationDialog(
                    "Cancel \"\(job.title)\"?",
                    isPresented: $showCancelConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Delete \(job.photoCount) Photos & Cancel Job", role: .destructive) {
                        Task {
                            guard let db else { return }
                            try? await TriageJobRepository(db: db).cancelAndDeletePhotos(jobId: job.id)
                            await viewModel.refreshCurationCounts()
                            await onJobChanged?()
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This will permanently delete all \(job.photoCount) staged photos and move the originals to Trash. This cannot be undone.")
                }
            }
        }
    }

    private var statusBadge: some View {
        let (label, color): (String, Color) = switch job.status {
            case .open:     ("Open", .orange)
            case .complete: ("Complete", .green)
            case .archived: ("Archived", .secondary)
        }
        return Text(label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private var stagedBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 18))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Photos are staged")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(job.photoCount) photo\(job.photoCount == 1 ? "" : "s") are waiting for review — not yet visible in your Library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.blue.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var archiveReadyBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "archivebox.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.mint)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Ready to Commit")
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12))
                }
                Text("All tasks complete. Commit to add these photos to your Library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Commit to Library") {
                Task {
                    guard let db else { return }
                    try? await TriageJobRepository(db: db).commitJobToLibrary(jobId: job.id, activityService: activityService)
                    await viewModel.refreshCurationCounts()
                    await onJobChanged?()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.mint)
            .controlSize(.small)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.mint.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.mint.opacity(0.25), lineWidth: 1)
                )
        )
    }

    // MARK: - Photos Filmstrip

    private var photosFilmstrip: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(photos.count) Photo\(photos.count == 1 ? "" : "s")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)

            if photos.isEmpty {
                HStack {
                    Spacer()
                    Text("No photos yet")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(height: 78)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(displayedPhotos) { photo in
                            photoThumb(photo)
                        }
                        // "View all" tile when showing a sample
                        if photos.count > 20 {
                            Button {
                                viewModel.filterToPhotoIds(photos.map(\.id))
                                viewModel.selectedSection = .library
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: "photo.stack")
                                        .font(.system(size: 18))
                                        .foregroundStyle(.secondary)
                                    Text("+\(photos.count - 20) more")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 72, height: 68)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                            }
                            .buttonStyle(.plain)
                            .help("Open all \(photos.count) photos in Library")
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 10)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    private func photoThumb(_ photo: PhotoAsset) -> some View {
        let baseName = (photo.canonicalName as NSString).deletingPathExtension
        let thumbURL = ProxyGenerationActor.thumbsDirectory().appendingPathComponent(baseName + ".jpg")
        let isHoverTarget = showHoverPreview && hoveredPhotoId == photo.id
        return Button {
            previewPhoto = photo
        } label: {
            ZStack(alignment: .bottomTrailing) {
                let isSelected = previewPhoto?.id == photo.id
                Group {
                    if let img = NSImage(contentsOf: thumbURL) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.primary.opacity(0.06)
                            .overlay { Image(systemName: "photo").foregroundStyle(.tertiary) }
                    }
                }
                .frame(width: 100, height: 68).clipped().cornerRadius(5)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(
                            isReviewDone && photo.curationState == CurationState.keeper.rawValue
                                ? Color.green
                                : Color.accentColor,
                            lineWidth: isSelected ? 2
                                : (isReviewDone && photo.curationState == CurationState.keeper.rawValue ? 2 : 0)
                        )
                )
                .opacity(
                    isSelected ? 0.85
                    : (isReviewDone && photo.curationState == CurationState.rejected.rawValue ? 0.4 : 1.0)
                )

                if let color = curationDotColor(photo) {
                    Circle().fill(color).frame(width: 8, height: 8).padding(3)
                }
            }
        }
        .buttonStyle(.plain)
        .help(photo.canonicalName)
        .onHover { hovering in
            if hovering {
                hoverTimerTask?.cancel()
                hoveredPhotoId = photo.id
                hoverTimerTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    showHoverPreview = true
                }
            } else {
                guard hoveredPhotoId == photo.id else { return }
                hoverTimerTask?.cancel()
                hoverTimerTask = nil
                showHoverPreview = false
                hoveredPhotoId = nil
            }
        }
        .popover(isPresented: .init(
            get: { isHoverTarget },
            set: { newVal in
                if !newVal, hoveredPhotoId == photo.id {
                    showHoverPreview = false
                    hoveredPhotoId = nil
                }
            }
        ), arrowEdge: .bottom) {
            FilmstripHoverPreview(photo: photo)
        }
        .onDrag {
            draggedPhotoId = photo.id
            return NSItemProvider(object: photo.id as NSString)
        }
        .onDrop(of: [.text], delegate: FilmstripDropDelegate(
            targetPhoto: photo,
            displayedPhotos: $displayedPhotos,
            photos: $photos,
            draggedPhotoId: $draggedPhotoId,
            jobId: job.id,
            db: db
        ))
    }

    private func curationDotColor(_ photo: PhotoAsset) -> Color? {
        switch CurationState(rawValue: photo.curationState) {
        case .keeper: return .green
        case .rejected: return .red
        case .archive: return .blue
        default: return nil
        }
    }

    // MARK: - Tasks (vertical cards)

    private var tasksSection: some View {
        VStack(spacing: 0) {
            if !tasks.isEmpty {
                let done = tasks.filter(\.isComplete).count
                // Slim progress strip
                HStack(spacing: 10) {
                    ProgressView(value: Double(done), total: Double(tasks.count))
                        .tint(done == tasks.count ? .green : .accentColor)
                    Text(done == tasks.count
                         ? "All done"
                         : "\(tasks.count - done) remaining")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(done == tasks.count ? .green : .secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

                // Develop milestone guidance
                if isReviewDone {
                    if keeperPhotosInJob.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .font(.system(size: 12))
                            Text("No keepers to develop. All photos were rejected during triage.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16).padding(.bottom, 10)
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.blue)
                                .font(.system(size: 12))
                            Text("Your photos are now in the Library. Open them in Develop to edit.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16).padding(.bottom, 10)
                    }
                }

                VStack(spacing: 8) {
                    ForEach(tasks) { task in
                        TaskCard(
                            task: task,
                            actionOverride: task.id == "review" ? { showReviewSheet  = true }
                                          : task.id == "people" ? {
                                              peopleWidgetPhotoIds = photos.map(\.id)
                                              showPeopleWidget = true
                                          }
                                          : nil
                        )
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
    }

    // MARK: - Inspector Pane

    private var inspectorPane: some View {
        VStack(spacing: 0) {
            // ── Fixed header: overall ring ────────────────────────────
            let doneTasks = tasks.filter(\.isComplete).count
            let totalTasks = tasks.count
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.08), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: totalTasks > 0 ? CGFloat(doneTasks) / CGFloat(totalTasks) : 0)
                        .stroke(
                            doneTasks == totalTasks && totalTasks > 0 ? Color.green : Color.accentColor,
                            style: StrokeStyle(lineWidth: 7, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.4), value: doneTasks)
                    VStack(spacing: 1) {
                        Text(totalTasks > 0 ? "\(doneTasks)/\(totalTasks)" : "–")
                            .font(.system(size: 16, weight: .bold).monospacedDigit())
                        Text("tasks")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 68, height: 68)
                .scaleEffect(ringCompletionPulse ? 1.12 : 1.0)
                .animation(.spring(response: 0.4, dampingFraction: 0.5), value: ringCompletionPulse)
                .onChange(of: doneTasks) { oldDone, newDone in
                    guard totalTasks > 0, newDone == totalTasks, oldDone < totalTasks else { return }
                    ringCompletionPulse = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        ringCompletionPulse = false
                    }
                }

                if chatCompleteness > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(.purple)
                        Text("\(chatCompleteness)% documented")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(chatCompleteness >= 80 ? .green : .secondary)
                            .monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // ── Scrollable detail ─────────────────────────────────────
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    // Photos
                    let keepers  = photos.filter { $0.curationState == CurationState.keeper.rawValue }.count
                    let rejected = photos.filter { $0.curationState == CurationState.rejected.rawValue }.count
                    let archive  = photos.filter { $0.curationState == CurationState.archive.rawValue }.count
                    let unreviewed = photos.filter { $0.curationState == CurationState.needsReview.rawValue }.count
                    inspectorSection("Photos") {
                        inspectorRow("Total",      "\(photos.count)")
                        inspectorRow("Keepers",    "\(keepers)",    color: keepers  > 0 ? .green  : .secondary)
                        inspectorRow("Rejected",   "\(rejected)",   color: rejected > 0 ? .red    : .secondary)
                        if archive    > 0 { inspectorRow("Archive",    "\(archive)",    color: .blue) }
                        if unreviewed > 0 { inspectorRow("Unreviewed", "\(unreviewed)", color: .orange) }
                    }

                    Divider().padding(.horizontal, 12)

                    // People
                    if faceCount > 0 {
                        inspectorSection("People") {
                            inspectorRow("Detected",    "\(faceCount)")
                            inspectorRow("Identified",  "\(identifiedCount)", color: .green)
                            let unid = faceCount - identifiedCount
                            if unid > 0 { inspectorRow("Unidentified", "\(unid)", color: .orange) }
                        }
                        Divider().padding(.horizontal, 12)
                    }

                    // Steps detail
                    if !tasks.isEmpty {
                        inspectorSection("Steps") {
                            VStack(spacing: 12) {
                                ForEach(tasks) { task in
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(spacing: 6) {
                                            Image(systemName: task.icon)
                                                .font(.system(size: 10))
                                                .foregroundStyle(task.iconColor)
                                                .frame(width: 14)
                                            Text(task.title)
                                                .font(.system(size: 11, weight: .medium))
                                            Spacer()
                                            if task.isComplete {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 9, weight: .bold))
                                                    .foregroundStyle(.green)
                                            }
                                        }
                                        if task.progress >= 0 {
                                            ProgressView(value: task.progress)
                                                .tint(task.isComplete ? .green : task.iconColor)
                                        }
                                        Text(task.description)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(3)
                                    }
                                }
                            }
                        }
                    }

                    // Timeline section
                    inspectorSection("Timeline") {
                        inspectorRow("Created", job.createdAt.formatted(date: .abbreviated, time: .shortened))
                        if let triageDate = job.triageCompletedAt {
                            inspectorRow("Imported", triageDate.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let developDate = job.developCompletedAt {
                            inspectorRow("Developed", developDate.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let completed = job.completedAt {
                            inspectorRow("Completed", completed.formatted(date: .abbreviated, time: .shortened))
                        }
                    }

                    Spacer(minLength: 20)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func inspectorSection<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)
            content()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }

    private func inspectorRow(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(color)
        }
    }

    // MARK: - Complete & Commit

    private func completeAndCommit() {
        Task {
            guard let db else { return }
            try? await TriageJobRepository(db: db).commitJobToLibrary(jobId: job.id, activityService: activityService)
            await viewModel.refreshCurationCounts()
            await onJobChanged?()
        }
    }

    // MARK: - Load

    private func loadDetail() async {
        guard let db else { return }
        isLoading = true; defer { isLoading = false }
        faceCount = 0; identifiedCount = 0
        let repo = TriageJobRepository(db: db)
        do {
            photos = try await repo.fetchPhotos(jobId: job.id)
            displayedPhotos = photos.count > 20 ? Array(photos.shuffled().prefix(20)) : photos
            // Compute face counts for the chat section's context
            let photoIds = photos.map(\.id)
            if !photoIds.isEmpty {
                let inClause = photoIds.map { "'\($0)'" }.joined(separator: ",")
                faceCount = (try? await db.dbPool.read { d in
                    try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM face_embeddings WHERE photo_id IN (\(inClause))")
                }) ?? 0
                // Count any face with a person_id assigned — including "Stranger"
                // (Stranger = user made a decision; counts as identified for job completeness)
                identifiedCount = (try? await db.dbPool.read { d in
                    try Int.fetchOne(d, sql: """
                        SELECT COUNT(*) FROM face_embeddings
                        WHERE photo_id IN (\(inClause))
                        AND person_id IS NOT NULL
                    """)
                }) ?? 0
            }
            tasks = await buildTasks(photos: photos)
        } catch {
            photos = []
            tasks = []
            print("[JobDetailView] \(error)")
        }
    }

    private func buildTasks(photos: [PhotoAsset]) async -> [JobTask] {
        guard !photos.isEmpty else { return [] }
        let photoIds = photos.map(\.id)
        let total = photos.count
        let inClause = photoIds.map { "'\($0)'" }.joined(separator: ",")

        // Review & Cull
        let culled = photos.filter { $0.curationState != CurationState.needsReview.rawValue }.count
        let reviewDone = culled == total

        // Face identification
        let facesDone = faceCount > 0 && identifiedCount >= faceCount

        // Develop: keepers with non-default adjustments
        let keeperPhotos = photos.filter { $0.curationState == CurationState.keeper.rawValue }
        let keeperCount = keeperPhotos.count
        let keeperClause = keeperPhotos.isEmpty ? "''" : keeperPhotos.map { "'\($0.id)'" }.joined(separator: ",")
        let developed: Int = keeperPhotos.isEmpty ? 0 : (try? await db?.dbPool.read { d in
            // Count keepers that have EITHER a development version OR non-empty adjustments
            try Int.fetchOne(d, sql: """
                SELECT COUNT(*) FROM photo_assets
                WHERE id IN (\(keeperClause))
                AND (
                    (adjustments_json IS NOT NULL AND adjustments_json != '' AND adjustments_json != '{}')
                    OR id IN (SELECT DISTINCT photo_id FROM development_versions)
                )
            """) ?? 0
        }) ?? 0

        // Metadata completeness — check per-photo metadata OR job-level chat metadata
        let jobHasMetadata: Bool = {
            guard let meta = job.inheritedMetadata, !meta.isEmpty, meta != "{}" else { return false }
            guard let data = meta.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            // Job chat metadata counts if at least 3 of 5 fields are filled
            var filled = 0
            if dict["location"] != nil { filled += 1 }
            if dict["camera"] != nil { filled += 1 }
            if dict["occasion"] != nil { filled += 1 }
            if let ppl = dict["people"] as? [String], !ppl.isEmpty { filled += 1 }
            if let kw = dict["keywords"] as? [String], !kw.isEmpty { filled += 1 }
            return filled >= 3
        }()

        let keepersWithoutMetadata: Int
        if jobHasMetadata {
            // Job-level metadata from chat covers all keepers
            keepersWithoutMetadata = 0
        } else {
            keepersWithoutMetadata = keeperPhotos.isEmpty ? 0 : (try? await db?.dbPool.read { d in
                try Int.fetchOne(d, sql: """
                    SELECT COUNT(*) FROM photo_assets
                    WHERE id IN (\(keeperClause))
                    AND (
                        user_metadata_json IS NULL
                        OR user_metadata_json = '{}'
                        OR user_metadata_json NOT LIKE '%"title"%'
                    )
                """) ?? 0
            }) ?? 0
        }
        let photosWithMetadata = keeperCount - keepersWithoutMetadata
        let metadataDone = keeperCount > 0 && keepersWithoutMetadata == 0

        var result: [JobTask] = []

        result.append(JobTask(
            id: "review",
            icon: reviewDone ? "checkmark.circle.fill" : "eye",
            iconColor: reviewDone ? .green : .orange,
            title: "Rate All Photos",
            description: reviewDone
                ? "All \(total) photos reviewed."
                : "\(total - culled) of \(total) photos still need a rating.",
            progress: total > 0 ? Double(culled) / Double(total) : 1,
            actionLabel: reviewDone ? "Re-review" : "Start Review",
            isComplete: reviewDone,
            action: { }
        ))

        if faceCount > 0 {
            result.append(JobTask(
                id: "people",
                icon: facesDone ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark",
                iconColor: facesDone ? .green : .blue,
                title: "Identify People",
                description: facesDone
                    ? "\(identifiedCount) face\(identifiedCount == 1 ? "" : "s") identified."
                    : "\(faceCount - identifiedCount) of \(faceCount) detected face\(faceCount == 1 ? "" : "s") not yet identified.",
                progress: faceCount > 0 ? Double(identifiedCount) / Double(faceCount) : 1,
                actionLabel: facesDone ? "Re-identify" : "Identify Faces",
                isComplete: facesDone,
                action: { }
            ))
        }

        let developDesc: String
        let developDone: Bool
        if keeperCount == 0 {
            developDesc = "Review photos first to mark your selects, then develop them."
            developDone = false
        } else if developed >= keeperCount {
            developDesc = "\(keeperCount) select\(keeperCount == 1 ? "" : "s") developed."
            developDone = true
        } else {
            developDesc = "\(developed) of \(keeperCount) keeper\(keeperCount == 1 ? "" : "s") developed."
            developDone = false
        }
        result.append(JobTask(
            id: "develop",
            icon: developDone ? "checkmark.circle.fill" : "slider.horizontal.3",
            iconColor: developDone ? .green : .purple,
            title: "Develop Selects",
            description: developDesc,
            progress: keeperCount > 0 ? min(1, Double(developed) / Double(keeperCount)) : (culled > 0 ? 0 : -1),
            actionLabel: keeperCount > 0 ? "Open in Develop" : "Review Photos",
            isComplete: developDone,
            action: {
                if keeperPhotos.isEmpty {
                    // No keepers yet — open the cull modal so the user can rate photos first
                    developPhotos = photos
                    showReviewSheet = true
                } else {
                    // Navigate to Develop mode filtered to keeper photos from this job
                    viewModel.developSequence = keeperPhotos
                    viewModel.developPhoto = keeperPhotos.first
                    viewModel.selectedPhotoID = keeperPhotos.first?.id
                    viewModel.showDevelopMode = true
                }
            }
        ))

        let metaDesc: String
        if keeperCount == 0 {
            metaDesc = "Rate photos first to identify your keepers."
        } else if metadataDone {
            metaDesc = "All \(keeperCount) keeper\(keeperCount == 1 ? "" : "s") have title and caption."
        } else {
            metaDesc = "\(keepersWithoutMetadata) of \(keeperCount) keeper\(keeperCount == 1 ? "" : "s") need title or caption."
        }
        result.append(JobTask(
            id: "metadata",
            icon: metadataDone ? "checkmark.circle.fill" : "text.badge.plus",
            iconColor: metadataDone ? .green : .teal,
            title: "Complete Metadata",
            description: metaDesc,
            progress: keeperCount > 0 ? Double(photosWithMetadata) / Double(keeperCount) : (culled > 0 ? 0 : -1),
            actionLabel: "Edit Metadata",
            isComplete: metadataDone,
            action: {
                withAnimation(.easeInOut(duration: 0.2)) { chatExpanded = true }
            }
        ))

        return result
    }
}

// MARK: - Quick Photo Preview

private struct QuickPhotoPreview: View {
    let initialPhoto: PhotoAsset
    let allPhotos: [PhotoAsset]
    @ObservedObject var viewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var currentIndex: Int
    @State private var image: NSImage? = nil

    init(initialPhoto: PhotoAsset, allPhotos: [PhotoAsset], viewModel: LibraryViewModel) {
        self.initialPhoto = initialPhoto
        self.allPhotos = allPhotos
        self.viewModel = viewModel
        self._currentIndex = State(initialValue: allPhotos.firstIndex(where: { $0.id == initialPhoto.id }) ?? 0)
    }

    private var currentPhoto: PhotoAsset { allPhotos[safe: currentIndex] ?? initialPhoto }

    private var proxyURL: URL {
        let base = (currentPhoto.canonicalName as NSString).deletingPathExtension
        return ProxyGenerationActor.proxiesDirectory().appendingPathComponent(base + ".jpg")
    }

    private var exifSummary: String? {
        guard let raw = currentPhoto.rawExifJson,
              let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var parts: [String] = []
        if let make = dict["Make"] as? String, let model = dict["Model"] as? String {
            parts.append("\(make) \(model)")
        }
        if let lens = dict["LensModel"] as? String ?? dict["Lens"] as? String { parts.append(lens) }
        if let date = dict["DateTimeOriginal"] as? String ?? dict["CreateDate"] as? String {
            parts.append(date)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 12) {
                // Navigation
                if allPhotos.count > 1 {
                    HStack(spacing: 4) {
                        Button { navigate(-1) } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(currentIndex == 0)
                        .keyboardShortcut(.leftArrow, modifiers: [])

                        Text("\(currentIndex + 1) / \(allPhotos.count)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: 52, alignment: .center)

                        Button { navigate(1) } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(currentIndex == allPhotos.count - 1)
                        .keyboardShortcut(.rightArrow, modifiers: [])
                    }
                    .buttonStyle(.bordered).controlSize(.small)

                    Divider().frame(height: 18)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(currentPhoto.canonicalName)
                        .font(.headline).lineLimit(1)
                    if let exif = exifSummary {
                        Text(exif)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button("Open in Develop") {
                    viewModel.developSequence = allPhotos
                    viewModel.developPhoto = currentPhoto
                    viewModel.selectedPhotoID = currentPhoto.id
                    viewModel.showDevelopMode = true
                    dismiss()
                }
                .buttonStyle(.borderedProminent).controlSize(.small)

                Button("Done") { dismiss() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 20).padding(.vertical, 12)

            Divider()

            // Photo (async loaded)
            ZStack {
                Color.black
                if let img = image {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeIn(duration: 0.15), value: image == nil)
        }
        .frame(minWidth: 800, minHeight: 580)
        .task(id: currentIndex) { await loadImage() }
    }

    private func navigate(_ delta: Int) {
        let next = currentIndex + delta
        guard allPhotos.indices.contains(next) else { return }
        image = nil
        currentIndex = next
    }

    private func loadImage() async {
        let url = proxyURL
        let loaded = await Task.detached(priority: .userInitiated) {
            NSImage(contentsOf: url)
        }.value
        await MainActor.run { image = loaded }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Job Chat Section

struct JobChatSection: View {
    let job: TriageJob
    let photos: [PhotoAsset]
    let faceCount: Int
    let identifiedCount: Int
    @Binding var completeness: Int

    @Environment(\.appDatabase) private var db
    @State private var messages: [ChatMsg] = []
    @State private var inputText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var nextQuestion: String? = nil
    @State private var extractedMetadata: DictationChunkingService.ChunkedMetadata?
    @State private var metadataPropagated = false
    @State private var propagationCount = 0
    @FocusState private var inputFocused: Bool
    struct ChatMsg: Identifiable {
        let id = UUID()
        let role: String   // "user" or "assistant"
        let text: String
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList

            if let q = nextQuestion, !isLoading {
                nextQuestionChip(q)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .animation(.easeOut(duration: 0.2), value: nextQuestion)
            }

            if let meta = extractedMetadata, !meta.isEmpty {
                extractedMetadataPills(meta)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .animation(.easeOut(duration: 0.25), value: extractedMetadata?.people.count)
            }

            // Propagation confirmation banner
            if metadataPropagated {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12))
                    Text("Metadata applied to \(propagationCount) keeper photo\(propagationCount == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        withAnimation { metadataPropagated = false }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Color.green.opacity(0.06))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            // Manual "Apply to Photos" button
            if filledFieldCount >= 3, !metadataPropagated {
                HStack(spacing: 6) {
                    Button {
                        Task { await propagateJobMetadata(jobId: job.id) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down.doc.fill")
                                .font(.system(size: 10))
                            Text("Apply to Photos")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.accentColor, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Write job metadata to all keeper photos")

                    Text("\(filledFieldCount) fields")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .transition(.opacity)
            }

            Divider()

            inputBar
        }
        .task(id: job.id) {
            inputText = ""
            errorMessage = nil
            nextQuestion = nil
            extractedMetadata = nil
            isLoading = false
            metadataPropagated = false
            propagationCount = 0
            await loadConversation()
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if messages.isEmpty {
                        emptyPlaceholder.padding(.top, 8)
                    }
                    ForEach(messages) { msg in
                        messageBubble(msg).id(msg.id)
                    }
                    if isLoading { typingIndicator }
                    if let err = errorMessage {
                        HStack(alignment: .top, spacing: 6) {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                            Spacer(minLength: 0)
                            Button {
                                withAnimation { errorMessage = nil }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .onAppear {
                            Task {
                                try? await Task.sleep(for: .seconds(6))
                                withAnimation { errorMessage = nil }
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("chat-bottom")
                }
                .padding(.vertical, 10)
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("chat-bottom") }
            }
            .onChange(of: isLoading) { _, loading in
                if loading {
                    withAnimation { proxy.scrollTo("chat-bottom") }
                }
            }
            .overlay(alignment: .top) {
                LinearGradient(
                    stops: [
                        .init(color: Color(nsColor: .windowBackgroundColor), location: 0),
                        .init(color: Color(nsColor: .windowBackgroundColor).opacity(0), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 48)
                .allowsHitTesting(false)
            }
        }
        .frame(maxHeight: 260)
    }

    private var emptyPlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tell me about these \(job.photoCount) photo\(job.photoCount == 1 ? "" : "s")")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Text("Where were they taken? Who's in them? What camera or lens was used? What was the occasion? I'll help document this job so it's ready to archive.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.purple.opacity(0.07), Color.blue.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.purple.opacity(0.15), lineWidth: 1)
                )
        )
        .padding(.horizontal, 14)
    }

    private func messageBubble(_ msg: ChatMsg) -> some View {
        let isUser = msg.role == "user"
        return HStack(alignment: .bottom, spacing: 0) {
            if isUser { Spacer(minLength: 48) }

            Text(msg.text)
                .font(.system(size: 12))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isUser
                              ? Color.accentColor
                              : Color(nsColor: .controlBackgroundColor))
                )
                .foregroundStyle(isUser ? Color.white : Color.primary)
                .textSelection(.enabled)

            if !isUser { Spacer(minLength: 48) }
        }
        .padding(.horizontal, 14)
    }

    private var typingIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: "ellipsis")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $inputText)
                    .font(.system(size: 13))
                    .frame(minHeight: 62, maxHeight: 104)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .focused($inputFocused)
                    .onKeyPress(phases: .down) { press in
                        if press.key == .return && !press.modifiers.contains(.shift) {
                            sendMessage()
                            return .handled
                        }
                        return .ignored
                    }

                if inputText.isEmpty {
                    Text("Type a message…  (Enter to send, Shift+Enter for new line)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: .placeholderTextColor))
                        .padding(.horizontal, 12)
                        .padding(.top, 13)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )

            Button {
                sendMessage()
            } label: {
                Image(systemName: isLoading ? "ellipsis.circle" : "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(canSend ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func nextQuestionChip(_ question: String) -> some View {
        Button {
            inputText = question
            nextQuestion = nil
            inputFocused = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.purple.opacity(0.7))
                Text(question)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.purple.opacity(0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.purple.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var canSend: Bool {
        !isLoading && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var completenessColor: Color {
        switch completeness {
        case 0:       return Color.secondary.opacity(0.5)
        case 1..<50:  return Color.orange
        case 50..<80: return Color.yellow
        default:      return Color.green
        }
    }

    // MARK: - Actions

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading, let db else { return }

        let userMsg = ChatMsg(role: "user", text: text)
        messages.append(userMsg)
        inputText = ""
        isLoading = true
        errorMessage = nil
        nextQuestion = nil

        // Build history for the service: everything except the user msg we just appended
        let history = messages.dropLast().map {
            JobChatService.ChatMessage(
                role: $0.role == "user" ? .user : .assistant,
                text: $0.text
            )
        }

        let exifSample = buildExifSample()
        let capturedJob = job

        Task {
            // Run local text chunking to extract structured metadata
            let chunker = DictationChunkingService()
            let personRepo = PersonRepository(db: db)
            let knownPeople = (try? await personRepo.fetchAll()) ?? []
            let chunked = await chunker.chunk(text: text, knownPeople: knownPeople)

            await MainActor.run {
                withAnimation { extractedMetadata = chunked.isEmpty ? nil : chunked }
            }

            do {
                let service = JobChatService()
                let response = try await service.send(
                    message: text,
                    history: history,
                    jobTitle: capturedJob.title,
                    photoCount: capturedJob.photoCount,
                    existingMetadata: capturedJob.inheritedMetadata,
                    sampleExif: exifSample,
                    faceCount: faceCount,
                    identifiedCount: identifiedCount,
                    db: db,
                    jobId: capturedJob.id
                )
                await MainActor.run {
                    messages.append(ChatMsg(role: "assistant", text: response.reply))
                    if response.completeness > 0 { completeness = response.completeness }
                    let q = response.nextQuestion?.trimmingCharacters(in: .whitespacesAndNewlines)
                    nextQuestion = (q?.isEmpty == false) ? q : nil
                    isLoading = false
                }
                if response.updatedMetadata, response.completeness >= 60 {
                    await propagateJobMetadata(jobId: capturedJob.id)
                }
            } catch {
                await MainActor.run {
                    // Restore: remove optimistic user message, put text back
                    if messages.last?.role == "user" { messages.removeLast() }
                    inputText = text
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func loadConversation() async {
        guard let db else { return }
        let loadingJobId = job.id
        do {
            let repo = ThreadRepository(db: db)
            let entries = try await repo.thread(for: loadingJobId)
            let chatEntries = entries.filter { $0.kind == "job_chat" }

            let loaded: [ChatMsg] = chatEntries.compactMap { entry in
                guard let data = entry.contentJson.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let role = dict["role"] as? String,
                      let text = dict["text"] as? String
                else { return nil }
                return ChatMsg(role: role, text: text)
            }

            let initialCompleteness = computeInitialCompleteness()
            await MainActor.run {
                guard job.id == loadingJobId else { return }
                messages = loaded
                completeness = initialCompleteness
            }
        } catch {
            print("[JobChatSection] Failed to load conversation: \(error)")
        }
    }

    private func computeInitialCompleteness() -> Int {
        guard let meta = job.inheritedMetadata,
              !meta.isEmpty, meta != "{}",
              let data = meta.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return 0 }
        var score = 0
        if dict["location"] != nil { score += 20 }
        if dict["camera"] != nil { score += 20 }
        if dict["occasion"] != nil { score += 20 }
        if let ppl = dict["people"] as? [String], !ppl.isEmpty { score += 20 }
        if let kw = dict["keywords"] as? [String], !kw.isEmpty { score += 20 }
        return score
    }

    // MARK: - Extracted Metadata Pills

    private func extractedMetadataPills(_ meta: DictationChunkingService.ChunkedMetadata) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(meta.people, id: \.name) { person in
                    metadataPill(icon: "person.fill", text: person.name, color: .blue)
                }
                ForEach(meta.dates, id: \.text) { dateRef in
                    metadataPill(icon: "calendar", text: dateRef.text, color: .orange)
                }
                if let equip = meta.equipment {
                    if let body = equip.cameraBody {
                        metadataPill(icon: "camera.fill", text: body, color: .purple)
                    }
                    if let lens = equip.lens {
                        metadataPill(icon: "camera.metering.spot", text: lens, color: .purple)
                    }
                    if let film = equip.filmStock {
                        metadataPill(icon: "film", text: film, color: .brown)
                    }
                }
                ForEach(meta.locations, id: \.self) { loc in
                    metadataPill(icon: "mappin.and.ellipse", text: loc, color: .green)
                }

                Button {
                    withAnimation { extractedMetadata = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss suggestions")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func metadataPill(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .cornerRadius(12)
    }

    private func buildExifSample() -> String {
        guard let first = photos.first,
              let rawExif = first.rawExifJson,
              !rawExif.isEmpty,
              let data = rawExif.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }

        // Keys match EXIFSnapshot.CodableSnapshot (captureDate, cameraMake, cameraModel, lens, etc.)
        var parts: [String] = []
        if let make = dict["cameraMake"] as? String { parts.append(make) }
        if let model = dict["cameraModel"] as? String { parts.append(model) }
        if let lens = dict["lens"] as? String {
            parts.append("/ \(lens)")
        }
        if let date = dict["captureDate"] as? String {
            parts.append("(\(date))")
        }
        if let iso = dict["iso"] as? Int { parts.append("ISO \(iso)") }
        if let fl = dict["focalLength"] as? Double { parts.append("\(Int(fl))mm") }
        return parts.joined(separator: " ")
    }

    // MARK: - Metadata Propagation

    private func propagateJobMetadata(jobId: String) async {
        guard let db else { return }
        let repo = TriageJobRepository(db: db)
        do {
            let count = try await repo.propagateMetadataToKeeperPhotos(jobId: jobId)
            await MainActor.run {
                if count > 0 {
                    propagationCount = count
                    metadataPropagated = true
                }
            }
        } catch {
            print("[JobChatSection] metadata propagation failed: \(error)")
        }
    }

    private var filledFieldCount: Int {
        guard let meta = job.inheritedMetadata,
              !meta.isEmpty, meta != "{}",
              let data = meta.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return 0 }
        var count = 0
        if dict["location"] != nil { count += 1 }
        if dict["camera"] != nil { count += 1 }
        if dict["occasion"] != nil { count += 1 }
        if let ppl = dict["people"] as? [String], !ppl.isEmpty { count += 1 }
        if let kw = dict["keywords"] as? [String], !kw.isEmpty { count += 1 }
        return count
    }
}

// MARK: - Job Readiness Ring

/// Small circular progress ring for the job sidebar row.
/// Replaces the solid status dot with a richer readiness indicator:
///  - Gray track with accent-colored arc proportional to completed tasks.
///  - Solid green circle with checkmark when all tasks are complete.
///  - Archived/complete jobs that aren't archive-ready use a simple filled dot.
struct JobReadinessRing: View {
    let completed: Int
    let total: Int
    let status: TriageJobStatus

    @State private var completionPulse = false

    private var isArchiveReady: Bool { total > 0 && completed == total }
    private var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }

    private var tooltipText: String {
        if total == 0 { return "No tasks" }
        if isArchiveReady { return "All \(total) tasks complete" }
        return "\(completed) of \(total) task\(total == 1 ? "" : "s") complete"
    }

    var body: some View {
        ZStack {
            if status == .archived {
                Circle().fill(Color.secondary).frame(width: 6, height: 6)
            } else if isArchiveReady {
                // Solid green circle with checkmark
                Circle().fill(Color.green)
                Image(systemName: "checkmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
            } else if total > 0 {
                // Gray track
                Circle()
                    .stroke(Color.primary.opacity(0.1), lineWidth: 2)
                // Accent-colored arc
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                // No tasks computed yet — fallback to status dot
                Circle().fill(statusFallbackColor).frame(width: 6, height: 6)
            }
        }
        .scaleEffect(completionPulse ? 1.25 : 1.0)
        .animation(.spring(response: 0.35, dampingFraction: 0.5), value: completionPulse)
        .help(tooltipText)
        .onChange(of: isArchiveReady) { _, ready in
            guard ready else { return }
            completionPulse = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                completionPulse = false
            }
        }
    }

    private var statusFallbackColor: Color {
        switch status {
        case .open: .orange
        case .complete: .green
        case .archived: .secondary
        }
    }
}

// MARK: - Task Model

struct JobTask: Identifiable {
    let id: String
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    let progress: Double   // 0…1, negative = indeterminate/N/A
    let actionLabel: String
    let isComplete: Bool
    let action: () -> Void
}

// MARK: - Task Card

struct TaskCard: View {
    let task: JobTask
    var actionOverride: (() -> Void)? = nil

    @State private var iconPulse = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: task.icon)
                .font(.system(size: 22))
                .foregroundStyle(task.iconColor)
                .frame(width: 32)
                .padding(.top, 2)
                .scaleEffect(iconPulse ? 1.3 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.5), value: iconPulse)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(task.title)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if task.isComplete {
                        Text("Done")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.12)))
                    }
                }

                Text(task.description)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)

                if task.progress >= 0 {
                    ProgressView(value: task.progress)
                        .tint(task.isComplete ? .green : task.iconColor)
                }

                Button(task.actionLabel) { (actionOverride ?? task.action)() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(task.iconColor)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(task.isComplete ? Color.green.opacity(0.2) : Color.clear, lineWidth: 1)
                )
        )
        .onChange(of: task.isComplete) { _, isNowComplete in
            guard isNowComplete else { return }
            iconPulse = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                iconPulse = false
            }
        }
    }
}

// MARK: - Job Review Sheet

struct JobReviewSheet: View {
    let photos: [PhotoAsset]
    let db: AppDatabase
    @Environment(\.dismiss) private var dismiss

    @State private var reviewPhotos: [PhotoAsset]
    @State private var selectedIndex: Int = 0

    init(photos: [PhotoAsset], db: AppDatabase) {
        self.photos = photos
        self.db = db
        _reviewPhotos = State(initialValue: photos)
    }

    private var selected: PhotoAsset? {
        guard !reviewPhotos.isEmpty, reviewPhotos.indices.contains(selectedIndex) else { return nil }
        return reviewPhotos[selectedIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Review & Cull")
                    .font(.headline)
                Spacer()
                Text("\(culledCount) / \(reviewPhotos.count) rated")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ProgressView(value: reviewPhotos.isEmpty ? 0 : Double(culledCount) / Double(reviewPhotos.count))
                .tint(.orange)
                .frame(height: 3)

            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(reviewPhotos.enumerated()), id: \.element.id) { idx, photo in
                                FilmstripThumb(photo: photo, isSelected: idx == selectedIndex)
                                    .id(idx)
                                    .onTapGesture { selectedIndex = idx }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: selectedIndex) { _, newIdx in
                        withAnimation { proxy.scrollTo(newIdx, anchor: .center) }
                    }
                }
                .frame(width: 130)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                if let photo = selected {
                    ReviewPreviewPane(
                        photo: photo,
                        onCurate: { state in
                            curate(state, at: selectedIndex)
                            if state != .needsReview { advance() }
                        }
                    )
                    .id(photo.id)
                } else {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(
            Group {
                Button("") { curate(.keeper, at: selectedIndex); advance() }
                    .keyboardShortcut("p", modifiers: []).opacity(0)
                Button("") { curate(.rejected, at: selectedIndex); advance() }
                    .keyboardShortcut("x", modifiers: []).opacity(0)
                Button("") { curate(.needsReview, at: selectedIndex) }
                    .keyboardShortcut("u", modifiers: []).opacity(0)
                Button("") { if selectedIndex > 0 { selectedIndex -= 1 } }
                    .keyboardShortcut(.leftArrow, modifiers: []).opacity(0)
                Button("") { if selectedIndex < reviewPhotos.count - 1 { selectedIndex += 1 } }
                    .keyboardShortcut(.rightArrow, modifiers: []).opacity(0)
            }
        )
    }

    private var culledCount: Int {
        reviewPhotos.filter { $0.curationState != CurationState.needsReview.rawValue }.count
    }

    private func advance() {
        if selectedIndex < reviewPhotos.count - 1 {
            selectedIndex += 1
        } else {
            // Last photo rated — auto-dismiss after brief delay
            let rated = reviewPhotos.filter { $0.curationState != CurationState.needsReview.rawValue }.count
            if rated == reviewPhotos.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    dismiss()
                }
            }
        }
    }

    private func curate(_ state: CurationState, at index: Int) {
        guard reviewPhotos.indices.contains(index) else { return }
        var updated = reviewPhotos[index]
        updated.curationState = state.rawValue
        reviewPhotos[index] = updated
        Task {
            try? await PhotoRepository(db: db).updateCurationState(id: updated.id, state: state)
        }
    }
}

private struct FilmstripThumb: View {
    let photo: PhotoAsset
    let isSelected: Bool

    private var thumbURL: URL {
        let base = (photo.canonicalName as NSString).deletingPathExtension
        return ProxyGenerationActor.thumbsDirectory().appendingPathComponent(base + ".jpg")
    }

    private var stateColor: Color? {
        switch CurationState(rawValue: photo.curationState) {
        case .keeper:   return .green
        case .rejected: return .red
        case .archive:  return .blue
        default:        return nil
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let img = NSImage(contentsOf: thumbURL) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.primary.opacity(0.08)
                        .overlay { Image(systemName: "photo").foregroundStyle(.tertiary) }
                }
            }
            .frame(width: 110, height: 74).clipped().cornerRadius(5)

            if let color = stateColor {
                Circle().fill(color).frame(width: 10, height: 10)
                    .padding(4)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .opacity(photo.curationState == CurationState.rejected.rawValue ? 0.45 : 1)
    }
}

private struct ReviewPreviewPane: View {
    let photo: PhotoAsset
    let onCurate: (CurationState) -> Void

    private var proxyURL: URL {
        let base = (photo.canonicalName as NSString).deletingPathExtension
        return ProxyGenerationActor.proxiesDirectory().appendingPathComponent(base + ".jpg")
    }

    private var currentState: CurationState? { CurationState(rawValue: photo.curationState) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let img = NSImage(contentsOf: proxyURL) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo").font(.system(size: 40)).foregroundStyle(.tertiary)
                        Text(photo.canonicalName).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 16) {
                Text(photo.canonicalName)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                curationButton(.keeper,   icon: "star.fill",  label: "Keep (P)",    color: .green)
                curationButton(.archive,  icon: "archivebox", label: "Archive",      color: .blue)
                curationButton(.rejected, icon: "xmark",      label: "Reject (X)",  color: .red)
                if currentState != .needsReview && currentState != nil {
                    Button("Clear (U)") { onCurate(.needsReview) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    @ViewBuilder
    private func curationButton(_ state: CurationState, icon: String, label: String, color: Color) -> some View {
        Button {
            onCurate(state)
        } label: {
            Label(label, systemImage: icon)
        }
        .buttonStyle(.borderedProminent)
        .tint(currentState == state ? color : color.opacity(0.25))
        .controlSize(.small)
    }
}

// MARK: - Filmstrip Hover Preview

private struct FilmstripHoverPreview: View {
    let photo: PhotoAsset

    private var proxyURL: URL {
        let base = (photo.canonicalName as NSString).deletingPathExtension
        return ProxyGenerationActor.proxiesDirectory().appendingPathComponent(base + ".jpg")
    }

    private var curationLabel: (String, Color)? {
        switch CurationState(rawValue: photo.curationState) {
        case .keeper:   return ("Keeper", .green)
        case .rejected: return ("Rejected", .red)
        case .archive:  return ("Archive", .blue)
        default:        return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Proxy image
            Group {
                if let img = NSImage(contentsOf: proxyURL) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Color(nsColor: .controlBackgroundColor)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: 32))
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .frame(width: 400, height: 300)
            .clipped()
            .background(Color.black)

            // Info bar
            HStack(spacing: 8) {
                Text(photo.canonicalName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                if let (label, color) = curationLabel {
                    HStack(spacing: 4) {
                        Circle().fill(color).frame(width: 7, height: 7)
                        Text(label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(color)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(width: 400)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Filmstrip Drag-to-Reorder

private struct FilmstripDropDelegate: DropDelegate {
    let targetPhoto: PhotoAsset
    @Binding var displayedPhotos: [PhotoAsset]
    @Binding var photos: [PhotoAsset]
    @Binding var draggedPhotoId: String?
    let jobId: String
    let db: AppDatabase?

    func dropEntered(info: DropInfo) {
        guard let draggedId = draggedPhotoId,
              draggedId != targetPhoto.id,
              let fromIndex = displayedPhotos.firstIndex(where: { $0.id == draggedId }),
              let toIndex = displayedPhotos.firstIndex(where: { $0.id == targetPhoto.id })
        else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            displayedPhotos.move(fromOffsets: IndexSet(integer: fromIndex),
                                 toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard draggedPhotoId != nil else { return false }
        draggedPhotoId = nil

        // Sync the full photos array to match displayedPhotos ordering.
        let reorderedIds = displayedPhotos.map(\.id)

        // Also update the master photos array to reflect the new order
        if photos.count == displayedPhotos.count {
            photos = displayedPhotos
        }

        // Persist to database
        guard let db else { return true }
        let allPhotoIds: [String]
        if photos.count <= 20 {
            allPhotoIds = reorderedIds
        } else {
            let displayedSet = Set(reorderedIds)
            let rest = photos.filter { !displayedSet.contains($0.id) }.map(\.id)
            allPhotoIds = reorderedIds + rest
        }

        Task {
            let repo = TriageJobRepository(db: db)
            try? await repo.updatePhotoSortOrder(jobId: jobId, photoIds: allPhotoIds)
        }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggedPhotoId != nil
    }
}
