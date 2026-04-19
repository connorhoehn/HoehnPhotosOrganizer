import SwiftUI
import UIKit
import HoehnPhotosCore

// MARK: - PeopleReviewView

/// Card-stack flow for naming / rejecting / merging unnamed face clusters.
struct PeopleReviewView: View {
    @Environment(\.appDatabase) private var appDatabase
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var syncService: PeerSyncService

    @State private var queue: [PendingItem] = []
    @State private var loaded = false
    @State private var loadError: String?
    @State private var namedPeople: [MobilePeopleRepository.PersonSummary] = []
    @State private var mergeTargetForClusterId: String?
    @State private var toast: ToastMessage?

    struct PendingItem: Identifiable, Equatable {
        var id: String { clusterId }
        let clusterId: String
        let faceCount: Int
        let model: FaceReviewCard.Model
    }

    var body: some View {
        ZStack {
            MeshBackdrop(palette: .dusk, animated: true).opacity(0.5)

            VStack(spacing: HPSpacing.base) {
                header

                if !loaded {
                    ProgressView().tint(.white).padding(.top, HPSpacing.xxxl)
                } else if let err = loadError {
                    ErrorBanner(message: err) { Task { await loadQueue() } }
                } else if queue.isEmpty {
                    allCaughtUpState
                } else {
                    cardStack
                }

                Spacer(minLength: 0)
            }
            .padding(HPSpacing.base)
        }
        .task { await loadQueue() }
        .hapticToast($toast)
        .sheet(item: Binding(
            get: { mergeTargetForClusterId.map { MergeSheetContext(clusterId: $0) } },
            set: { mergeTargetForClusterId = $0?.clusterId }
        )) { ctx in
            mergePicker(for: ctx.clusterId)
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Button {
                HPHaptic.light()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .padding(HPSpacing.sm)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            VStack(spacing: 2) {
                Text("Review faces")
                    .font(HPFont.sectionHeader)
                    .foregroundStyle(.white)
                Text("\(queue.count) left")
                    .font(HPFont.cardSubtitle)
                    .foregroundStyle(.white.opacity(0.75))
                    .contentTransition(.numericText())
            }

            Spacer()

            Image(systemName: "person.crop.square.badge.questionmark")
                .font(.title3)
                .padding(HPSpacing.sm)
                .background(.ultraThinMaterial, in: Circle())
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private var cardStack: some View {
        ZStack {
            ForEach(Array(queue.prefix(3).enumerated()), id: \.element.clusterId) { (depth, item) in
                FaceReviewCard(model: item.model) { action in
                    Task { await handle(action, for: item) }
                }
                .scaleEffect(1 - CGFloat(depth) * 0.04)
                .offset(y: CGFloat(depth) * 8)
                .zIndex(-Double(depth))
                .allowsHitTesting(depth == 0)
            }
        }
    }

    private var allCaughtUpState: some View {
        VStack(spacing: HPSpacing.base) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 54))
                .foregroundStyle(HPColor.keeper)
                .symbolEffect(.bounce, value: queue.count)
            Text("All caught up")
                .font(HPFont.screenTitle)
                .foregroundStyle(.white)
            Text("No unnamed clusters remain.")
                .font(HPFont.cardSubtitle)
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, HPSpacing.xxxl)
    }

    private func mergePicker(for clusterId: String) -> some View {
        NavigationStack {
            List {
                if namedPeople.isEmpty {
                    Text("No named people yet — name this cluster first, then merge others into it.")
                        .font(HPFont.cardSubtitle)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(namedPeople) { person in
                        Button {
                            Task { await merge(clusterId: clusterId, into: person) }
                        } label: {
                            HStack {
                                Text(person.name).font(HPFont.cardTitle)
                                Spacer()
                                Text("\(person.faceCount) faces")
                                    .font(HPFont.metaValue)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Merge into…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { mergeTargetForClusterId = nil }
                }
            }
        }
    }

    // MARK: - Actions

    private func handle(_ action: FaceReviewCard.Action, for item: PendingItem) async {
        guard let db = appDatabase else { return }
        let repo = MobilePeopleRepository(db: db)

        switch action {
        case .name(let typedName):
            let trimmed = typedName.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }

            // If a named person already exists with this exact name, merge into them
            if let existing = namedPeople.first(where: {
                $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
            }) {
                do {
                    try await repo.mergePeople(sourceId: item.clusterId, targetId: existing.id)
                    syncService.enqueuePeopleDelta(
                        .mergePeople(source: item.clusterId, target: existing.id)
                    )
                    NotificationCenter.default.post(name: .cloudSyncPeopleChanged, object: nil)
                    await advance(itemId: item.clusterId)
                    toast = .init(.success, "Merged into \(existing.name)", subtitle: "\(item.faceCount) faces added")
                } catch {
                    toast = .init(.error, "Couldn't merge", subtitle: error.localizedDescription)
                }
            } else {
                // Rename the existing cluster row
                do {
                    try await repo.renamePerson(id: item.clusterId, name: trimmed)
                    syncService.enqueuePeopleDelta(
                        .renamePerson(id: item.clusterId, name: trimmed)
                    )
                    NotificationCenter.default.post(name: .cloudSyncPeopleChanged, object: nil)
                    await advance(itemId: item.clusterId)
                    toast = .init(.success, "Named as \(trimmed)", subtitle: "\(item.faceCount) faces labeled")
                } catch {
                    toast = .init(.error, "Couldn't rename", subtitle: error.localizedDescription)
                }
            }

        case .reject:
            do {
                try await repo.deletePerson(id: item.clusterId)
                syncService.enqueuePeopleDelta(.deletePerson(id: item.clusterId))
                NotificationCenter.default.post(name: .cloudSyncPeopleChanged, object: nil)
                await advance(itemId: item.clusterId)
                toast = .init(.info, "Removed cluster", subtitle: "Faces unassigned")
            } catch {
                toast = .init(.error, "Couldn't remove", subtitle: error.localizedDescription)
            }

        case .merge:
            mergeTargetForClusterId = item.clusterId
        }
    }

    private func merge(clusterId: String, into person: MobilePeopleRepository.PersonSummary) async {
        guard let db = appDatabase else { return }
        let repo = MobilePeopleRepository(db: db)
        do {
            try await repo.mergePeople(sourceId: clusterId, targetId: person.id)
            syncService.enqueuePeopleDelta(.mergePeople(source: clusterId, target: person.id))
            NotificationCenter.default.post(name: .cloudSyncPeopleChanged, object: nil)
            mergeTargetForClusterId = nil
            await advance(itemId: clusterId)
            toast = .init(.success, "Merged into \(person.name)")
        } catch {
            toast = .init(.error, "Couldn't merge", subtitle: error.localizedDescription)
        }
    }

    private func advance(itemId: String) async {
        await MainActor.run {
            withAnimation(HPMotion.smooth) {
                queue.removeAll { $0.clusterId == itemId }
            }
        }
        await loadNamed()
    }

    // MARK: - Loading

    private func loadQueue() async {
        guard let db = appDatabase else { return }
        let repo = MobilePeopleRepository(db: db)
        do {
            async let clustersTask = repo.fetchUnnamedClusters()
            async let peopleTask = repo.fetchPeople()
            let (clusters, people) = try await (clustersTask, peopleTask)

            await MainActor.run {
                namedPeople = people
            }

            var items: [PendingItem] = []
            for cluster in clusters {
                let contextImage = await loadContextImage(photoId: cluster.representativePhotoId)
                let faceImage = await loadFaceThumb(clusterId: cluster.id, photoId: cluster.representativePhotoId)
                let model = FaceReviewCard.Model(
                    id: cluster.id,
                    faceImage: faceImage,
                    contextImage: contextImage,
                    suggestedName: nil,
                    photoDateText: nil
                )
                items.append(.init(clusterId: cluster.id, faceCount: cluster.faceCount, model: model))
            }
            await MainActor.run {
                queue = items
                loaded = true
                loadError = nil
            }
        } catch {
            await MainActor.run {
                loadError = error.localizedDescription
                loaded = true
            }
        }
    }

    private func loadNamed() async {
        guard let db = appDatabase else { return }
        let repo = MobilePeopleRepository(db: db)
        if let people = try? await repo.fetchPeople() {
            await MainActor.run { namedPeople = people }
        }
    }

    private func loadContextImage(photoId: String?) async -> UIImage? {
        guard let photoId, let db = appDatabase else { return nil }
        guard let photo = try? await MobilePhotoRepository(db: db).fetchById(photoId) else { return nil }
        let baseName = (photo.canonicalName as NSString).deletingPathExtension
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HoehnPhotos/proxies/\(baseName).jpg")
        return UIImage(contentsOfFile: url.path)
    }

    private func loadFaceThumb(clusterId: String, photoId: String?) async -> UIImage? {
        guard let photoId, let db = appDatabase else { return nil }
        let repo = MobilePeopleRepository(db: db)
        // Use the first assigned face in this cluster as the representative crop.
        guard let face = try? await repo.fetchFaceForPerson(personId: clusterId) else { return nil }
        guard let photo = try? await MobilePhotoRepository(db: db).fetchById(photoId) else { return nil }
        let baseName = (photo.canonicalName as NSString).deletingPathExtension
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HoehnPhotos/proxies/\(baseName).jpg")
        return await FaceCropCache.shared.crop(id: face.id, proxyURL: url, bbox: face.bboxRect)
    }
}

private struct MergeSheetContext: Identifiable {
    let clusterId: String
    var id: String { clusterId }
}

#Preview {
    PeopleReviewView()
}
