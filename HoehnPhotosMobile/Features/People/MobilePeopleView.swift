import SwiftUI
import UIKit
import HoehnPhotosCore

// MARK: - PeopleSortOrder

enum PeopleSortOrder: String, CaseIterable {
    case mostPhotos = "Most Photos"
    case alphabetical = "A-Z"
}

// MARK: - MobilePeopleView

struct MobilePeopleView: View {

    @Environment(\.appDatabase) private var appDatabase
    @EnvironmentObject private var syncService: PeerSyncService
    @State private var people: [MobilePeopleRepository.PersonSummary] = []
    @State private var faceCrops: [String: UIImage] = [:]  // personId -> crop image
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var searchText = ""
    @State private var sortOrder: PeopleSortOrder = .mostPhotos

    private let columns = [GridItem(.flexible(), spacing: HPSpacing.md), GridItem(.flexible(), spacing: HPSpacing.md)]

    private var displayedPeople: [MobilePeopleRepository.PersonSummary] {
        let filtered: [MobilePeopleRepository.PersonSummary]
        if searchText.isEmpty {
            filtered = people
        } else {
            filtered = people.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
        }

        switch sortOrder {
        case .mostPhotos:
            return filtered.sorted { $0.faceCount > $1.faceCount }
        case .alphabetical:
            return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private var sortChips: [FilterChip] {
        PeopleSortOrder.allCases.map { order in
            FilterChip(
                id: order.rawValue,
                label: order.rawValue,
                icon: order == .mostPhotos ? "photo.stack" : "textformat.abc"
            )
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && people.isEmpty {
                    SkeletonPeopleGrid(count: 6)
                } else if people.isEmpty && loadError == nil {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            if let err = loadError {
                                ErrorBanner(message: err) {
                                    Task { await loadPeople() }
                                }
                                .padding(.bottom, HPSpacing.sm)
                            }

                            FilterChipBar(
                                chips: sortChips,
                                selectedId: sortOrder.rawValue,
                                onSelect: { id in
                                    if let id, let order = PeopleSortOrder(rawValue: id) {
                                        sortOrder = order
                                    }
                                }
                            )

                            LazyVGrid(columns: columns, spacing: HPSpacing.md) {
                                ForEach(displayedPeople) { person in
                                    NavigationLink {
                                        MobilePersonDetailView(person: person)
                                            .environmentObject(syncService)
                                    } label: {
                                        personCell(person)
                                            .task {
                                                await loadFaceCrop(for: person)
                                            }
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button {
                                            UIPasteboard.general.string = person.name
                                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                                        } label: {
                                            Label("Copy Name", systemImage: "doc.on.doc")
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, HPSpacing.md)
                            .padding(.bottom, HPSpacing.md)
                        }
                    }
                }
            }
            .navigationTitle(people.isEmpty ? "People" : "People (\(people.count))")
            .searchable(text: $searchText, prompt: "Search people")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sortOrder) {
                            ForEach(PeopleSortOrder.allCases, id: \.self) { order in
                                Text(order.rawValue).tag(order)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Sort order")
                }
            }
            .task { await loadPeople() }
            .refreshable { await loadPeople() }
        }
    }

    // MARK: - Person Cell

    private func personCell(_ person: MobilePeopleRepository.PersonSummary) -> some View {
        PersonCardView(person: person, crop: faceCrops[person.id])
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack {
            Spacer()
            EmptyStateView(
                icon: "person.2",
                title: "No People Found",
                message: "Run face indexing on your Mac to identify people."
            )
            Spacer()
        }
    }

    // MARK: - Data Loading

    private func loadPeople() async {
        guard let db = appDatabase else { return }
        do {
            people = try await MobilePeopleRepository(db: db).fetchPeople()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func loadFaceCrop(for person: MobilePeopleRepository.PersonSummary) async {
        guard let db = appDatabase,
              faceCrops[person.id] == nil else { return }

        // Fetch the representative face embedding for this person
        let face: FaceEmbedding?
        do {
            face = try await MobilePeopleRepository(db: db).fetchFaceForPerson(personId: person.id)
        } catch {
            return
        }
        guard let face else { return }

        // Build the proxy URL from the canonical name of the photo
        guard let photoAsset = try? await MobilePhotoRepository(db: db).fetchById(face.photoId) else { return }
        let baseName = (photoAsset.canonicalName as NSString).deletingPathExtension
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let proxyURL = appSupport
            .appendingPathComponent("HoehnPhotos")
            .appendingPathComponent("proxies")
            .appendingPathComponent(baseName + ".jpg")

        // Crop the face using the cached actor
        let crop = await FaceCropCache.shared.crop(
            id: face.id,
            proxyURL: proxyURL,
            bbox: face.bboxRect
        )
        if let crop {
            faceCrops[person.id] = crop
        }
    }
}

// MARK: - PersonCardView

private struct PersonCardView: View {
    let person: MobilePeopleRepository.PersonSummary
    let crop: UIImage?

    @ScaledMetric(relativeTo: .body) private var imageSize: CGFloat = 96
    @State private var isPressed = false

    var body: some View {
        VStack(spacing: HPSpacing.sm) {
            // 96pt circle face crop
            Group {
                if let crop {
                    Image(uiImage: crop)
                        .resizable()
                        .scaledToFill()
                } else {
                    HPColor.cardBackground
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.tertiary)
                        )
                }
            }
            .frame(width: imageSize, height: imageSize)
            .clipShape(Circle())

            VStack(spacing: HPSpacing.xxs) {
                Text(person.name)
                    .font(HPFont.cardTitle)
                    .lineLimit(1)

                Text("\(person.faceCount) photo\(person.faceCount == 1 ? "" : "s")")
                    .font(HPFont.cardSubtitle)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, HPSpacing.md)
        .padding(.horizontal, HPSpacing.sm)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: HPRadius.card, style: .continuous)
                .fill(HPColor.cardBackground)
                .shadow(color: Color(.sRGBLinear, white: 0, opacity: 0.15), radius: 4, y: 2)
        )
        .contentShape(Rectangle())
        .scaleEffect(isPressed ? 0.96 : 1.0)
        .animation(HPAnimation.cardSpring, value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityLabel("\(person.name), \(person.faceCount) photo\(person.faceCount == 1 ? "" : "s")")
        .accessibilityHint("Shows photos of \(person.name)")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - MobilePersonDetailView

struct MobilePersonDetailView: View {
    let person: MobilePeopleRepository.PersonSummary

    @Environment(\.appDatabase) private var appDatabase
    @EnvironmentObject private var syncService: PeerSyncService
    @State private var photos: [PhotoAsset] = []
    @State private var isLoading = true
    @State private var selectedPhotoIndex: Int?
    @State private var heroCrop: UIImage?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: HPGrid.photoGutter), count: HPGrid.defaultColumns)

    var body: some View {
        Group {
            if isLoading {
                SkeletonPhotoGrid(rows: 4, columns: 3)
            } else if photos.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: HPSpacing.base) {
                        // MARK: Hero section
                        heroSection

                        // MARK: Photo grid
                        LazyVGrid(columns: columns, spacing: HPGrid.photoGutter) {
                            ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                                MobilePhotoCell(photo: photo)
                                    .aspectRatio(1, contentMode: .fill)
                                    .onTapGesture { selectedPhotoIndex = index }
                                    .photoContextMenu(photo: photo, onCurate: { state in
                                        Task {
                                            guard let db = appDatabase else { return }
                                            await applyCuration(photo: photo, state: state, db: db, syncService: syncService)
                                            await loadPhotos()
                                        }
                                    }, onViewDetails: {
                                        selectedPhotoIndex = index
                                    })
                            }
                        }
                    }
                }
                .refreshable { await loadPhotos() }
            }
        }
        .navigationTitle(person.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadAll() }
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

    // MARK: - Hero Section

    private var heroSection: some View {
        VStack(spacing: HPSpacing.sm) {
            Group {
                if let heroCrop {
                    Image(uiImage: heroCrop)
                        .resizable()
                        .scaledToFill()
                } else {
                    HPColor.cardBackground
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(.tertiary)
                        )
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(Circle())

            Text("\(photos.count) photo\(photos.count == 1 ? "" : "s")")
                .font(HPFont.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, HPSpacing.base)
        .padding(.bottom, HPSpacing.sm)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        EmptyStateView(
            icon: "person.crop.square.badge.camera",
            title: "No Photos Found",
            message: "Photos with \(person.name) will appear here after face detection runs."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data Loading

    private func loadAll() async {
        await loadPhotos()
        await loadHeroCrop()
    }

    private func loadPhotos() async {
        guard let db = appDatabase else {
            isLoading = false
            return
        }
        photos = (try? await MobilePeopleRepository(db: db).fetchPhotosForPerson(personId: person.id)) ?? []
        isLoading = false
    }

    private func loadHeroCrop() async {
        guard let db = appDatabase else { return }
        guard let face = try? await MobilePeopleRepository(db: db).fetchFaceForPerson(personId: person.id) else { return }
        guard let photoAsset = try? await MobilePhotoRepository(db: db).fetchById(face.photoId) else { return }

        let baseName = (photoAsset.canonicalName as NSString).deletingPathExtension
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let proxyURL = appSupport
            .appendingPathComponent("HoehnPhotos")
            .appendingPathComponent("proxies")
            .appendingPathComponent(baseName + ".jpg")

        heroCrop = await FaceCropCache.shared.crop(
            id: face.id,
            proxyURL: proxyURL,
            bbox: face.bboxRect
        )
    }
}
