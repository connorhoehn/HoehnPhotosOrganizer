import SwiftUI
import HoehnPhotosCore

// MARK: - CompletenessRing

private struct CompletenessRing: View {
    let score: Double
    var size: CGFloat = 28
    var lineWidth: CGFloat = 3
    var showLabel: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatedScore: Double = 0

    var ringColor: Color {
        animatedScore < 0.33 ? .red : animatedScore < 0.66 ? .orange : .green
    }
    var body: some View {
        ZStack {
            Circle().stroke(ringColor.opacity(0.25), lineWidth: lineWidth)
            Circle().trim(from: 0, to: animatedScore)
                .stroke(ringColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showLabel {
                Text("\(Int(animatedScore * 100))%")
                    .font(.system(size: size * 0.25, weight: .bold).monospacedDigit())
                    .foregroundStyle(ringColor)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            if reduceMotion {
                animatedScore = score
            } else {
                withAnimation(.easeOut(duration: 0.8).delay(0.2)) {
                    animatedScore = score
                }
            }
        }
        .onChange(of: score) { _, newScore in
            if reduceMotion {
                animatedScore = newScore
            } else {
                withAnimation(.easeOut(duration: 0.5)) {
                    animatedScore = newScore
                }
            }
        }
    }
}

// MARK: - MobileJobTask

struct MobileJobTask: Identifiable {
    let id: String
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let progress: Double
    let isComplete: Bool
}

// MARK: - TaskProgressCard

private struct TaskProgressCard: View {
    let task: MobileJobTask

    var body: some View {
        VStack(alignment: .leading, spacing: HPSpacing.sm) {
            HStack {
                Image(systemName: task.icon)
                    .font(.system(size: 18))
                    .foregroundStyle(task.isComplete ? .green : task.iconColor)
                Spacer()
                if task.isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 14))
                }
            }

            Text(task.title)
                .font(HPFont.cardTitle)

            Text(task.subtitle)
                .font(HPFont.cardSubtitle)
                .foregroundStyle(.secondary)

            ProgressView(value: task.progress)
                .tint(task.isComplete ? .green : task.iconColor)
        }
        .padding(HPSpacing.md)
        .background(HPColor.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HPRadius.medium))
    }
}

// MARK: - JobFilmstripThumb

private struct JobFilmstripThumb: View {
    let photo: PhotoAsset
    let proxyURL: URL

    @State private var image: UIImage?

    private var curationState: CurationState? {
        CurationState(rawValue: photo.curationState)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let img = image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    HPColor.cardBackground
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .frame(width: 80, height: 60)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: HPRadius.small))

            // Curation badge overlay
            if let state = curationState, state != .needsReview {
                curationBadge(state)
            }
        }
        .task(id: photo.id) {
            let url = proxyURL
            let loadedImage = await Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: url) else { return nil as UIImage? }
                return UIImage(data: data)
            }.value
            if let img = loadedImage {
                self.image = img
            }
        }
    }

    private func curationBadge(_ state: CurationState) -> some View {
        Image(systemName: state.systemIcon)
            .font(.system(size: 10))
            .foregroundStyle(.white)
            .padding(3)
            .background(Circle().fill(state.tint))
            .padding(3)
            .accessibilityHidden(true)
    }
}

// MARK: - MobileJobsView

struct MobileJobsView: View {
    @Environment(\.appDatabase) private var appDatabase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var syncService: PeerSyncService
    @ScaledMetric(relativeTo: .body) private var ringSize: CGFloat = 28
    @State private var jobs: [TriageJob] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var searchText = ""
    @State private var jobToComplete: TriageJob?
    @State private var showSwipeCompleteConfirmation = false
    @State private var collapsedParents: Set<String> = []
    @State private var selectedFilterId: String?
    @State private var didInitCollapsed = false

    private var statusFilterChips: [FilterChip] {
        let openCount = jobs.filter { $0.status == .open }.count
        let completeCount = jobs.filter { $0.status == .complete }.count
        let archivedCount = jobs.filter { $0.status == .archived }.count
        return [
            FilterChip(id: "all", label: "All", count: jobs.count),
            FilterChip(id: "open", label: "Open", tint: .orange, count: openCount),
            FilterChip(id: "complete", label: "Complete", tint: .green, count: completeCount),
            FilterChip(id: "archived", label: "Archived", tint: .secondary, count: archivedCount),
        ]
    }

    var filteredJobs: [TriageJob] {
        var result = jobs

        // Status filter
        switch selectedFilterId {
        case "open": result = result.filter { $0.status == .open }
        case "complete": result = result.filter { $0.status == .complete }
        case "archived": result = result.filter { $0.status == .archived }
        default: break // "all" or nil — show everything
        }

        // Search filter
        if !searchText.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(searchText)
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                FilterChipBar(
                    chips: statusFilterChips,
                    selectedId: selectedFilterId,
                    onSelect: { selectedFilterId = $0 }
                )

                Group {
                    if isLoading && jobs.isEmpty {
                        SkeletonJobsList(count: 5)
                    } else if jobs.isEmpty {
                        emptyState
                    } else {
                        jobsList
                    }
                }
            }
            .navigationTitle("Jobs")
            .searchable(text: $searchText, prompt: "Search jobs...")
            .task { await loadJobs() }
            .onAppear { Task { await loadJobs() } }
            .confirmationDialog(
                "Mark Job Complete?",
                isPresented: $showSwipeCompleteConfirmation,
                presenting: jobToComplete
            ) { job in
                Button("Mark Complete") {
                    Task {
                        guard let db = appDatabase else { return }
                        try? await MobileJobRepository(db: db).markComplete(jobId: job.id)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        await loadJobs()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { job in
                Text("Mark \"\(job.title)\" as complete? This will close the job.")
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: HPSpacing.base) {
            EmptyStateView(
                icon: "tray.2.fill",
                title: "No Jobs",
                message: "Import photos on your Mac to create triage jobs."
            )
            if let err = loadError {
                ErrorBanner(message: err) {
                    Task { await loadJobs() }
                }
            }
        }
    }

    // MARK: - Jobs List with Hierarchy

    private var jobsList: some View {
        let rootJobs = filteredJobs.filter { $0.parentJobId == nil }
        let childrenByParent = Dictionary(
            grouping: filteredJobs.filter { $0.parentJobId != nil },
            by: { $0.parentJobId! }
        )

        return List {
            ForEach(rootJobs) { parent in
                Section {
                    NavigationLink {
                        MobileJobDetailView(job: parent)
                            .environmentObject(syncService)
                    } label: {
                        jobRow(parent)
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        HPHaptic.selection()
                    })
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if parent.status == .open {
                            Button {
                                jobToComplete = parent
                                showSwipeCompleteConfirmation = true
                            } label: {
                                Label("Complete", systemImage: "checkmark.circle")
                            }
                            .tint(.green)
                        }
                    }
                    if let children = childrenByParent[parent.id] {
                        // Expand/collapse toggle for children
                        Button {
                            withAnimation(reduceMotion ? .default : HPAnimation.cardSpring) {
                                if collapsedParents.contains(parent.id) {
                                    collapsedParents.remove(parent.id)
                                } else {
                                    collapsedParents.insert(parent.id)
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "chevron.right")
                                    .font(HPFont.badgeLabel)
                                    .foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(collapsedParents.contains(parent.id) ? 0 : 90))
                                    .animation(reduceMotion ? .default : HPAnimation.cardSpring, value: collapsedParents.contains(parent.id))
                                Text("\(children.count) sub-job\(children.count == 1 ? "" : "s")")
                                    .font(HPFont.cardSubtitle)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.leading, HPSpacing.base)
                        }
                        .buttonStyle(.plain)

                        if !collapsedParents.contains(parent.id) {
                            ForEach(children) { child in
                                NavigationLink {
                                    MobileJobDetailView(job: child)
                                        .environmentObject(syncService)
                                } label: {
                                    jobRow(child)
                                        .padding(.leading, HPSpacing.base)
                                }
                                .simultaneousGesture(TapGesture().onEnded {
                                    HPHaptic.selection()
                                })
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if child.status == .open {
                                        Button {
                                            jobToComplete = child
                                            showSwipeCompleteConfirmation = true
                                        } label: {
                                            Label("Complete", systemImage: "checkmark.circle")
                                        }
                                        .tint(.green)
                                    }
                                }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await loadJobs()
        }
    }

    // MARK: - Job Row

    private func jobRow(_ job: TriageJob) -> some View {
        HStack(spacing: HPSpacing.md) {
            CompletenessRing(score: job.completenessScore, size: ringSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HPSpacing.xxs) {
                Text(job.title).font(HPFont.cardTitle)
                Text("\(job.photoCount) photos")
                    .font(HPFont.cardSubtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(
                label: job.status.rawValue.capitalized,
                color: jobStatusColor(job.status)
            )
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(job.title), \(Int(job.completenessScore * 100)) percent complete, \(job.photoCount) photos, \(job.status.rawValue)")
        .accessibilityAddTraits(.isButton)
    }

    private func jobStatusColor(_ status: TriageJobStatus) -> Color {
        switch status {
        case .open: return .orange
        case .complete: return .green
        case .archived: return .secondary
        }
    }

    // MARK: - Data Loading

    private func loadJobs() async {
        guard let db = appDatabase else {
            loadError = "No database connection"
            isLoading = false
            return
        }
        do {
            jobs = try await MobileJobRepository(db: db).fetchAll()
            // Default sub-jobs to collapsed on first load
            if !didInitCollapsed {
                let parentIds = Set(
                    jobs.filter { $0.parentJobId == nil }
                        .compactMap { parent in
                            jobs.contains(where: { $0.parentJobId == parent.id }) ? parent.id : nil
                        }
                )
                collapsedParents = parentIds
                didInitCollapsed = true
            }
        } catch {
            loadError = "Query: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

// MARK: - MobileJobDetailView

struct MobileJobDetailView: View {
    let job: TriageJob
    @Environment(\.appDatabase) private var appDatabase
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var syncService: PeerSyncService
    @State private var photos: [PhotoAsset] = []
    @State private var selectedPhotoIndex: Int?
    @State private var showMarkCompleteConfirmation = false
    @State private var peopleProgress: Double = 0
    @State private var peopleSubtitle: String = "Loading..."
    @State private var developProgress: Double = 0
    @State private var developSubtitle: String = "Loading..."

    private let photoColumns = Array(repeating: GridItem(.flexible(), spacing: HPGrid.photoGutter), count: HPGrid.defaultColumns)

    var body: some View {
        ScrollView {
            VStack(spacing: HPSpacing.base) {
                jobDetailHeader
                stagedBanner
                taskCardsGrid
                filmstripSection

                // Batch complete button
                if job.status == .open {
                    Button("Mark All Keepers Complete") {
                        showMarkCompleteConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .padding(.horizontal, HPSpacing.base)
                    .confirmationDialog(
                        "Mark All Keepers Complete?",
                        isPresented: $showMarkCompleteConfirmation
                    ) {
                        Button("Mark Complete") {
                            Task {
                                guard let db = appDatabase else { return }
                                try? await MobileJobRepository(db: db).markComplete(jobId: job.id)
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                dismiss()
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will mark \(job.photoCount) kept photos as reviewed and close the job.")
                    }
                }

                // Photo grid
                if photos.isEmpty {
                    EmptyStateView(
                        icon: "photo.stack",
                        title: "No Photos",
                        message: "No photos in this job"
                    )
                    .padding(.vertical, HPSpacing.xxxl)
                } else {
                    LazyVGrid(columns: photoColumns, spacing: HPGrid.photoGutter) {
                        ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                            MobilePhotoCell(photo: photo)
                                .aspectRatio(1, contentMode: .fill)
                                .onTapGesture { selectedPhotoIndex = index }
                                .photoContextMenu(photo: photo, onCurate: { state in
                                    Task { await setCuration(photo: photo, state: state) }
                                })
                        }
                    }
                }
            }
        }
        .navigationTitle(job.title)
        .task {
            guard let db = appDatabase else { return }
            let repo = MobileJobRepository(db: db)

            photos = (try? await repo.fetchPhotos(jobId: job.id)) ?? []

            // People progress
            if let people = try? await repo.fetchPeopleProgress(jobId: job.id) {
                let total = max(people.total, 1)
                peopleProgress = Double(people.identified) / Double(total)
                peopleSubtitle = people.total > 0
                    ? "\(people.identified) / \(people.total) identified"
                    : "No faces detected"
            } else {
                peopleSubtitle = "–"
            }

            // Develop progress
            if let dev = try? await repo.fetchDevelopProgress(jobId: job.id) {
                let total = max(dev.total, 1)
                developProgress = Double(dev.developed) / Double(total)
                developSubtitle = dev.total > 0
                    ? "\(dev.developed) / \(dev.total) developed"
                    : "No keepers yet"
            } else {
                developSubtitle = "–"
            }
        }
        .sheet(isPresented: Binding(
            get: { selectedPhotoIndex != nil },
            set: { if !$0 { selectedPhotoIndex = nil } }
        )) {
            if let idx = selectedPhotoIndex {
                MobilePhotoDetailView(photos: photos, initialIndex: idx)
                    .environmentObject(syncService)
            }
        }
    }

    // MARK: - Job Detail Header

    private var jobDetailHeader: some View {
        VStack(spacing: HPSpacing.md) {
            HStack(spacing: 14) {
                CompletenessRing(
                    score: job.completenessScore,
                    size: 48,
                    lineWidth: 5,
                    showLabel: true
                )

                VStack(alignment: .leading, spacing: HPSpacing.xs) {
                    Text(job.title)
                        .font(HPFont.sectionHeader)
                    HStack(spacing: HPSpacing.md) {
                        Label("\(job.photoCount) photos", systemImage: "photo.on.rectangle")
                        Label(
                            job.createdAt.formatted(date: .abbreviated, time: .omitted),
                            systemImage: "calendar"
                        )
                    }
                    .font(HPFont.cardSubtitle)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                StatusBadge(
                    label: job.status.rawValue.capitalized,
                    color: statusColor
                )
            }
        }
        .padding(HPSpacing.base)
        .background(HPColor.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HPRadius.large))
        .padding(.horizontal, HPSpacing.base)
    }

    // MARK: - Staged Banner

    private var stagedBanner: some View {
        Group {
            if job.status == .open {
                HStack(spacing: HPSpacing.sm) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    Text("These photos are staged for triage. Review and rate them to make progress.")
                        .font(HPFont.body)
                        .foregroundStyle(.secondary)
                }
                .padding(HPSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: HPRadius.medium))
                .padding(.horizontal, HPSpacing.base)
            }
        }
    }

    // MARK: - Task Cards Grid

    private var taskCardsGrid: some View {
        let columns = [GridItem(.flexible(), spacing: HPSpacing.md), GridItem(.flexible(), spacing: HPSpacing.md)]
        return LazyVGrid(columns: columns, spacing: HPSpacing.md) {
            ForEach(computedTasks) { task in
                TaskProgressCard(task: task)
            }
        }
        .padding(.horizontal, HPSpacing.base)
    }

    private var computedTasks: [MobileJobTask] {
        let total = photos.count
        guard total > 0 else { return [] }

        // Review: photos where curationState != "needs_review"
        let reviewedCount = photos.filter { $0.curationState != CurationState.needsReview.rawValue }.count
        let reviewProgress = Double(reviewedCount) / Double(total)

        // Metadata: keeper photos with non-empty userMetadataJson
        let keepers = photos.filter { $0.curationState == CurationState.keeper.rawValue }
        let keeperCount = max(keepers.count, 1)
        let metadataCount = keepers.filter { ($0.userMetadataJson ?? "").count > 2 }.count
        let metadataProgress = keepers.isEmpty ? 0.0 : Double(metadataCount) / Double(keeperCount)

        return [
            MobileJobTask(
                id: "review", icon: "eye", iconColor: .orange,
                title: "Review", subtitle: "\(reviewedCount) / \(total) rated",
                progress: reviewProgress, isComplete: reviewProgress >= 1.0
            ),
            MobileJobTask(
                id: "people", icon: "person.2", iconColor: .purple,
                title: "People", subtitle: peopleSubtitle,
                progress: peopleProgress, isComplete: peopleProgress >= 1.0
            ),
            MobileJobTask(
                id: "develop", icon: "slider.horizontal.3", iconColor: .blue,
                title: "Develop", subtitle: developSubtitle,
                progress: developProgress, isComplete: developProgress >= 1.0
            ),
            MobileJobTask(
                id: "metadata", icon: "text.badge.checkmark", iconColor: .teal,
                title: "Metadata", subtitle: keepers.isEmpty
                    ? "No keepers yet"
                    : "\(metadataCount) / \(keepers.count) titled",
                progress: metadataProgress, isComplete: metadataProgress >= 1.0
            ),
        ]
    }

    // MARK: - Filmstrip

    private var filmstripSection: some View {
        VStack(alignment: .leading, spacing: HPSpacing.sm) {
            SectionHeader(
                title: "Photos",
                count: photos.count,
                trailing: photos.count > 20
                    ? AnyView(
                        Text("+\(photos.count - 20) more below")
                            .font(HPFont.metaLabel)
                            .foregroundStyle(.tertiary)
                    )
                    : nil
            )

            if photos.isEmpty {
                HStack {
                    Spacer()
                    Text("No photos yet")
                        .font(HPFont.cardSubtitle)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(height: 60)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: HPSpacing.sm) {
                        ForEach(Array(photos.prefix(20).enumerated()), id: \.element.id) { index, photo in
                            JobFilmstripThumb(
                                photo: photo,
                                proxyURL: proxyURL(for: photo)
                            )
                            .onTapGesture {
                                selectedPhotoIndex = index
                            }
                            .photoContextMenu(photo: photo, onCurate: { state in
                                Task { await setCuration(photo: photo, state: state) }
                            })
                        }
                    }
                    .padding(.horizontal, HPSpacing.base)
                }
            }
        }
    }

    private func proxyURL(for photo: PhotoAsset) -> URL {
        let baseName = (photo.canonicalName as NSString).deletingPathExtension
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("HoehnPhotos")
            .appendingPathComponent("proxies")
            .appendingPathComponent(baseName + ".jpg")
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch job.status {
        case .open: return .orange
        case .complete: return .green
        case .archived: return .secondary
        }
    }

    // MARK: - Curation

    private func setCuration(photo: PhotoAsset, state: CurationState) async {
        guard let db = appDatabase else { return }
        try? await MobilePhotoRepository(db: db).updateCurationState(id: photo.id, state: state)
        syncService.enqueueDelta(
            PhotoCurationDelta(photoId: photo.id, curationState: state.rawValue)
        )
        // Refresh photos to show updated curation dot
        photos = (try? await MobileJobRepository(db: db).fetchPhotos(jobId: job.id)) ?? photos
    }
}
