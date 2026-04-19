import SwiftUI
import HoehnPhotosCore
import GRDB

struct MobileLibraryView: View {

    @Binding var showSettings: Bool
    @Environment(\.appDatabase) private var appDatabase
    @EnvironmentObject private var syncService: PeerSyncService
    @State private var monthSections: [MonthSection] = []
    @State private var expandedMonths: Set<String> = []
    @State private var isLoading = true
    @State private var selectedPhotoIndex: Int?
    @State private var loadError: String?
    @State private var showActivity = false
    @State private var loadedMonthCount: Int = 3
    @State private var allMonthsLoaded = false

    // Batch selection state
    @State private var isSelecting = false
    @State private var selectedPhotoIDs: Set<String> = []

    // Filter state
    @AppStorage("libraryCurationFilter") private var selectedFilterRaw: String = "all"
    @State private var showStaged = false

    // Reduce motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Phase 4 — Hero zoom namespace shared between the source tile and
    // the destination MobilePhotoDetailView.
    @Namespace private var heroNamespace

    // Cached photo count — updated in loadPhotos() instead of computed on every body evaluation
    @State private var allPhotoCount: Int = 0

    // Flat photos array for detail sheet and batch operations
    private var allPhotos: [PhotoAsset] {
        monthSections.flatMap(\.photos)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    filterBar
                    if isLoading && monthSections.isEmpty {
                        skeletonGrid
                    } else if monthSections.isEmpty {
                        Spacer()
                        emptyState
                        Spacer()
                    } else {
                        photoGrid
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isSelecting && !selectedPhotoIDs.isEmpty {
                    batchActionBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .animation(reduceMotion ? .default : .spring(response: 0.35, dampingFraction: 0.75), value: selectedPhotoIDs.isEmpty)
                }
            }
            .navigationTitle("Library (\(allPhotoCount))")
            .toolbar {
                if isSelecting {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            HPHaptic.selection()
                            if selectedPhotoIDs.count == allPhotos.count {
                                selectedPhotoIDs.removeAll()
                            } else {
                                selectedPhotoIDs = Set(allPhotos.map { $0.id })
                            }
                        } label: {
                            Text(selectedPhotoIDs.count == allPhotos.count ? "Deselect All" : "Select All")
                        }
                    }
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            HPHaptic.light()
                            Task { await reloadAndFetch() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Reload library")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        HPHaptic.selection()
                        withAnimation {
                            isSelecting.toggle()
                            if !isSelecting { selectedPhotoIDs.removeAll() }
                        }
                    } label: {
                        Text(isSelecting ? "Done" : "Select")
                    }
                }
                if !isSelecting {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            HPHaptic.light()
                            showActivity = true
                        } label: {
                            Image(systemName: "clock")
                        }
                        .accessibilityLabel("Activity")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            HPHaptic.selection()
                            showStaged.toggle()
                            Task { await resetAndLoad() }
                        } label: {
                            Image(systemName: showStaged ? "tray.full.fill" : "tray.fill")
                        }
                        .accessibilityLabel(showStaged ? "Hide staged photos" : "Show staged photos")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            HPHaptic.light()
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
            }
            .navigationDestination(isPresented: $showActivity) {
                MobileActivityView(isEmbedded: true)
            }
            .task {
                await reloadAndFetch()
            }
            .onChange(of: syncService.state) { _, newState in
                switch newState {
                case .completed:
                    Task { await reloadAndFetch() }
                default: break
                }
            }
            .sheet(isPresented: Binding(
                get: { selectedPhotoIndex != nil },
                set: { if !$0 { selectedPhotoIndex = nil } }
            )) {
                MobilePhotoDetailView(
                    photos: allPhotos,
                    initialIndex: selectedPhotoIndex ?? 0,
                    heroNamespace: heroNamespace
                )
            }
        }
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        FilterChipBar(
            chips: [
                FilterChip(id: "all", label: "All"),
                FilterChip(id: "keeper", label: "Keeper", tint: HPColor.keeper),
                FilterChip(id: "archive", label: "Archive", tint: HPColor.archive),
                FilterChip(id: "needs_review", label: "Needs Review", tint: HPColor.needsReview),
                FilterChip(id: "rejected", label: "Reject", tint: HPColor.reject),
            ],
            selectedId: selectedFilterRaw,
            onSelect: { id in
                selectedFilterRaw = id ?? "all"
                Task { await resetAndLoad() }
            }
        )
        .background(HPColor.chromeBackground)
    }

    // MARK: - Skeleton Grid

    private var skeletonGrid: some View {
        ScrollView {
            VStack(spacing: HPSpacing.base) {
                BentoSkeletonSection()
                BentoSkeletonSection()
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: HPSpacing.base) {
            EmptyStateView(
                icon: "photo.on.rectangle.angled",
                title: "No Photos",
                message: "Sync from your Mac first, then tap reload."
            )

            if let err = loadError {
                ErrorBanner(message: err) {
                    Task { await reloadAndFetch() }
                }
            }

            Button {
                HPHaptic.light()
                Task { await reloadAndFetch() }
            } label: {
                Label("Reload Database", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Photo Grid

    private var photoGrid: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(monthSections) { section in
                    Section {
                        BentoSectionView(
                            photos: section.photos,
                            isExpanded: expandedMonths.contains(section.monthKey),
                            isSelecting: isSelecting,
                            selectedPhotoIDs: selectedPhotoIDs,
                            onTapPhoto: { photo in handlePhotoTap(photo) },
                            onToggleExpand: {
                                HPHaptic.selection()
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    if expandedMonths.contains(section.monthKey) {
                                        expandedMonths.remove(section.monthKey)
                                    } else {
                                        expandedMonths.insert(section.monthKey)
                                    }
                                }
                            },
                            onCuratePhoto: { photo, state in
                                HPHaptic.medium()
                                curate(photo: photo, state: state)
                            },
                            heroNamespace: heroNamespace
                        )
                    } header: {
                        SectionHeader(section.displayLabel, count: section.photos.count, style: .sticky)
                    }
                }

                if !allMonthsLoaded {
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            loadedMonthCount += 3
                            Task { await loadPhotos() }
                        }
                }
            }
        }
        .refreshable {
            await reloadAndFetch()
        }
    }

    // MARK: - Photo Tap Handler

    private func handlePhotoTap(_ photo: PhotoAsset) {
        HPHaptic.light()
        if isSelecting {
            withAnimation(reduceMotion ? .default : HPAnimation.cardSpring) {
                if selectedPhotoIDs.contains(photo.id) {
                    selectedPhotoIDs.remove(photo.id)
                } else {
                    selectedPhotoIDs.insert(photo.id)
                }
            }
        } else {
            if let idx = allPhotos.firstIndex(where: { $0.id == photo.id }) {
                selectedPhotoIndex = idx
            }
        }
    }

    // MARK: - Batch Action Bar

    private var batchActionBar: some View {
        VStack(spacing: 0) {
            Divider()
            Text("\(selectedPhotoIDs.count) selected")
                .font(HPFont.badgeLabel)
                .padding(.top, HPSpacing.sm)
            HStack(spacing: 0) {
                Spacer()
                Button {
                    HPHaptic.heavy()
                    Task { await batchCurate(.keeper) }
                } label: {
                    VStack(spacing: HPSpacing.xs) {
                        Image(systemName: "hand.thumbsup.fill").foregroundStyle(.green)
                        Text("Keep").font(HPFont.badgeLabel)
                    }
                    .accessibilityElement(children: .combine)
                }
                .accessibilityLabel("Keep \(selectedPhotoIDs.count) photos")
                Spacer()
                Button {
                    HPHaptic.heavy()
                    Task { await batchCurate(.archive) }
                } label: {
                    VStack(spacing: HPSpacing.xs) {
                        Image(systemName: "archivebox.fill").foregroundStyle(.blue)
                        Text("Archive").font(HPFont.badgeLabel)
                    }
                    .accessibilityElement(children: .combine)
                }
                .accessibilityLabel("Archive \(selectedPhotoIDs.count) photos")
                Spacer()
                Button {
                    HPHaptic.heavy()
                    Task { await batchCurate(.rejected) }
                } label: {
                    VStack(spacing: HPSpacing.xs) {
                        Image(systemName: "hand.thumbsdown.fill").foregroundStyle(.red)
                        Text("Reject").font(HPFont.badgeLabel)
                    }
                    .accessibilityElement(children: .combine)
                }
                .accessibilityLabel("Reject \(selectedPhotoIDs.count) photos")
                Spacer()
            }
            .padding(.vertical, HPSpacing.md)
            .background(HPColor.chromeBackground)
        }
    }

    // MARK: - Batch Curation

    private func batchCurate(_ state: CurationState) async {
        guard let db = appDatabase else { return }
        let ids = Array(selectedPhotoIDs)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        do {
            try await db.dbPool.write { conn in
                for id in ids {
                    try conn.execute(
                        sql: "UPDATE photo_assets SET curation_state = ? WHERE id = ?",
                        arguments: [state.rawValue, id]
                    )
                }
            }
            // Enqueue sync deltas
            for id in ids {
                syncService.enqueueDelta(PhotoCurationDelta(photoId: id, curationState: state.rawValue))
            }
            // Update local monthSections array
            for sectionIndex in monthSections.indices {
                for photoIndex in monthSections[sectionIndex].photos.indices {
                    if selectedPhotoIDs.contains(monthSections[sectionIndex].photos[photoIndex].id) {
                        monthSections[sectionIndex].photos[photoIndex].curationState = state.rawValue
                    }
                }
            }
            withAnimation {
                selectedPhotoIDs.removeAll()
                isSelecting = false
            }
        } catch {
            print("[BatchCurate] \(error)")
        }
    }

    // MARK: - Curation

    private func curate(photo: PhotoAsset, state: CurationState) {
        guard let db = appDatabase else { return }
        Task {
            do {
                try await db.dbPool.write { dbConn in
                    try dbConn.execute(
                        sql: "UPDATE photo_assets SET curation_state = ? WHERE id = ?",
                        arguments: [state.rawValue, photo.id]
                    )
                }
                // Enqueue sync delta
                syncService.enqueueDelta(PhotoCurationDelta(photoId: photo.id, curationState: state.rawValue))
                // Refresh the photo in the local monthSections array
                for sectionIndex in monthSections.indices {
                    if let photoIndex = monthSections[sectionIndex].photos.firstIndex(where: { $0.id == photo.id }) {
                        var updated = monthSections[sectionIndex].photos[photoIndex]
                        updated.curationState = state.rawValue
                        monthSections[sectionIndex].photos[photoIndex] = updated
                        break
                    }
                }
            } catch {
                print("[Library] curate error: \(error)")
            }
        }
    }

    // MARK: - Data Loading

    private func reloadAndFetch() async {
        guard let db = appDatabase else {
            loadError = "No database connection"
            isLoading = false
            return
        }

        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dbPath = appSupport.appendingPathComponent("HoehnPhotos/Catalog.db").path
        let fileExists = fm.fileExists(atPath: dbPath)
        let fileSize = (try? fm.attributesOfItem(atPath: dbPath)[.size] as? Int) ?? 0
        print("[Library] DB file: exists=\(fileExists), size=\(fileSize) bytes, path=\(dbPath)")

        do {
            try db.reload()
            print("[Library] DB reloaded")
        } catch {
            print("[Library] Reload error: \(error)")
            loadError = "DB reload: \(error.localizedDescription)"
        }
        await resetAndLoad()
    }

    private func resetAndLoad() async {
        monthSections = []
        loadedMonthCount = 3
        allMonthsLoaded = false
        await loadPhotos()
    }

    private func loadPhotos() async {
        guard let db = appDatabase else { return }
        let curationFilter: CurationState? = selectedFilterRaw == "all" ? nil : CurationState(rawValue: selectedFilterRaw)
        do {
            let sections = try await MobilePhotoRepository(db: db).fetchLibraryPhotosGroupedByMonth(
                curationFilter: curationFilter,
                showStaged: showStaged,
                monthLimit: loadedMonthCount
            )
            allMonthsLoaded = sections.count < loadedMonthCount
            monthSections = sections
            allPhotoCount = sections.reduce(0) { $0 + $1.photos.count }
        } catch {
            loadError = "Query: \(error.localizedDescription)"
        }
        isLoading = false
    }
}

// MARK: - MobilePhotoCell

struct MobilePhotoCell: View {
    let photo: PhotoAsset
    var isSelected: Bool = false
    @State private var image: UIImage?
    @State private var shimmerPhase: CGFloat = -1

    private var proxyURL: URL {
        let baseName = (photo.canonicalName as NSString).deletingPathExtension
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("HoehnPhotos")
            .appendingPathComponent("proxies")
            .appendingPathComponent(baseName + ".jpg")
    }

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)

            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color(uiColor: .systemFill), location: shimmerPhase - 0.3),
                                .init(color: Color(uiColor: .secondarySystemFill), location: shimmerPhase),
                                .init(color: Color(uiColor: .systemFill), location: shimmerPhase + 0.3),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .onAppear {
                        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                            shimmerPhase = 2
                        }
                    }
            }

            if let state = CurationState(rawValue: photo.curationState), state != .needsReview {
                VStack {
                    HStack {
                        Spacer()
                        Circle().fill(state.tint)
                            .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 0.5))
                            .frame(width: 8, height: 8).padding(HPSpacing.xs)
                    }
                    Spacer()
                }
                .accessibilityHidden(true)
            }

            if isSelected {
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.3)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .padding(HPSpacing.sm)
                }
                .accessibilityHidden(true)
            }
        }
        .clipped()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityPhotoLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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

    private var accessibilityPhotoLabel: String {
        let state = CurationState(rawValue: photo.curationState)?.title ?? "Uncategorized"
        let name = photo.canonicalName
        if isSelected {
            return "\(name), \(state), selected"
        }
        return "\(name), \(state)"
    }
}

// ShimmerCell moved to HoehnPhotosMobile/Shared/SkeletonComponents.swift
