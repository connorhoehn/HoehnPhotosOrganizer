import SwiftUI
import GRDB
import HoehnPhotosCore

// MARK: - PhotoFacesStrip
//
// Horizontal row of FaceChips, one per detected face in the photo.
// - Named chip  -> `onSelectPerson(name)` callback (typically drives a
//                  Search-tab People-scope filter via DeepLinkCoordinator).
// - Unknown chip -> modal naming sheet (inline; no tab switch) backed by
//                   `MobilePeopleRepository` + `PeerSyncService`.
//
// SQL is inlined here (rather than added to MobilePeopleRepository) because
// another agent is currently editing MobileRepositories.swift. If that
// restriction lifts, migrate `loadFaces` into MobilePeopleRepository as
// `fetchFacesForPhoto(photoId:)` returning (FaceEmbedding, String?) tuples.

struct PhotoFacesStrip: View {
    let photo: PhotoAsset
    @Binding var toast: ToastMessage?

    /// Invoked when a named face chip is tapped. Receives the person's
    /// display name. Optional so preview/test code can omit it.
    var onSelectPerson: ((String) -> Void)? = nil

    @Environment(\.appDatabase) private var appDatabase
    @EnvironmentObject private var syncService: PeerSyncService

    @State private var entries: [FaceEntry] = []
    @State private var cropsByFaceId: [String: UIImage] = [:]
    @State private var isLoading = true

    // Naming sheet state for unknown-chip taps.
    @State private var namingEntry: FaceEntry?
    @State private var namingInput: String = ""
    @State private var namingSuggestions: [MobilePeopleRepository.PersonSummary] = []
    @State private var isSavingName = false

    struct FaceEntry: Identifiable {
        let face: FaceEmbedding
        let personName: String?
        var id: String { face.id }
    }

    var body: some View {
        Group {
            if isLoading {
                loadingRow
                    .transition(.opacity)
            } else if entries.isEmpty {
                EmptyView()
            } else {
                facesRow
                    .transition(.opacity)
            }
        }
        .task(id: photo.id) { await loadFaces() }
        .sheet(item: $namingEntry) { entry in
            namingSheet(for: entry)
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
        }
    }

    // MARK: - Row

    private var facesRow: some View {
        VStack(alignment: .leading, spacing: HPSpacing.sm) {
            HStack {
                Text("People")
                    .font(HPFont.sectionHeader)
                Spacer()
                Text("\(entries.count)")
                    .font(HPFont.metaValue)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, HPSpacing.base)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HPSpacing.md) {
                    ForEach(entries) { entry in
                        FaceChip(
                            image: cropsByFaceId[entry.face.id],
                            name: entry.personName,
                            size: .medium
                        ) {
                            onTap(entry)
                        }
                    }
                }
                .padding(.horizontal, HPSpacing.base)
                .padding(.vertical, HPSpacing.xs)
            }
        }
    }

    private var loadingRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HPSpacing.md) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle()
                        .fill(HPColor.cardBackground)
                        .frame(width: 54, height: 54)
                        .overlay(
                            Circle()
                                .stroke(.white.opacity(0.08), lineWidth: 0.5)
                        )
                }
            }
            .padding(.horizontal, HPSpacing.base)
            .padding(.vertical, HPSpacing.xs)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Tap handling

    private func onTap(_ entry: FaceEntry) {
        HPHaptic.selection()
        if let name = entry.personName, !name.isEmpty {
            // Fallback log (previously this was "Filter by <name> coming
            // soon"). The real behaviour is the callback below.
            if let onSelectPerson {
                onSelectPerson(name)
            } else {
                toast = ToastMessage(.info, "Filter by \(name) coming soon")
            }
        } else {
            // Fallback log (previously this was "Naming coming soon").
            // Now opens an inline naming sheet.
            namingInput = ""
            namingEntry = entry
            Task { await loadSuggestions() }
        }
    }

    // MARK: - Naming Sheet

    @ViewBuilder
    private func namingSheet(for entry: FaceEntry) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: HPSpacing.base) {
                    // Preview the face crop so the user knows who they're
                    // naming. Falls back to the generic unknown chip art.
                    HStack {
                        Spacer()
                        FaceChip(
                            image: cropsByFaceId[entry.face.id],
                            name: nil,
                            size: .large
                        )
                        .allowsHitTesting(false)
                        Spacer()
                    }
                    .padding(.top, HPSpacing.base)

                    GlassPanel(tone: .card) {
                        VStack(alignment: .leading, spacing: HPSpacing.sm) {
                            Text("Name")
                                .font(HPFont.metaLabel)
                                .foregroundStyle(.secondary)
                            TextField("e.g. Taylor", text: $namingInput)
                                .textInputAutocapitalization(.words)
                                .disableAutocorrection(false)
                                .submitLabel(.done)
                                .font(HPFont.cardTitle)
                                .onSubmit { save(for: entry) }
                        }
                        .padding(HPSpacing.base)
                    }

                    if !namingSuggestions.isEmpty {
                        VStack(alignment: .leading, spacing: HPSpacing.sm) {
                            Text("Suggestions")
                                .font(HPFont.metaLabel)
                                .foregroundStyle(.secondary)
                            VStack(spacing: HPSpacing.xs) {
                                ForEach(namingSuggestions) { person in
                                    Button {
                                        Task { await assignTo(person: person, entry: entry) }
                                    } label: {
                                        HStack {
                                            Image(systemName: "person.crop.circle.fill")
                                                .font(.title3)
                                                .foregroundStyle(.secondary)
                                                .accessibilityHidden(true)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(person.name)
                                                    .font(HPFont.cardTitle)
                                                Text("\(person.faceCount) face\(person.faceCount == 1 ? "" : "s")")
                                                    .font(HPFont.metaValue)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                                .accessibilityHidden(true)
                                        }
                                        .padding(HPSpacing.md)
                                    }
                                    .buttonStyle(.plain)
                                    .background(HPColor.cardBackground,
                                                in: RoundedRectangle(cornerRadius: HPRadius.card, style: .continuous))
                                    .accessibilityElement(children: .combine)
                                    .accessibilityLabel("\(person.name), \(person.faceCount) face\(person.faceCount == 1 ? "" : "s")")
                                    .accessibilityHint("Assign face to this person")
                                }
                            }
                        }
                    }
                }
                .padding(HPSpacing.base)
            }
            .navigationTitle("Who is this?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { namingEntry = nil }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        save(for: entry)
                    } label: {
                        if isSavingName {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save").fontWeight(.semibold)
                        }
                    }
                    .disabled(isSavingName || namingInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save(for entry: FaceEntry) {
        let trimmed = namingInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { await performSave(typedName: trimmed, entry: entry) }
    }

    // MARK: - Name-flow actions

    private func loadSuggestions() async {
        guard let db = appDatabase else { return }
        let repo = MobilePeopleRepository(db: db)
        let people = (try? await repo.fetchPeople()) ?? []
        await MainActor.run {
            // Top 5 named people, ordered by faceCount DESC (repo default).
            namingSuggestions = Array(people.prefix(5))
        }
    }

    /// Tapping an existing person in the suggestions list. Assigns this
    /// face to that person and enqueues the sync delta.
    private func assignTo(person: MobilePeopleRepository.PersonSummary, entry: FaceEntry) async {
        guard let db = appDatabase else { return }
        let repo = MobilePeopleRepository(db: db)
        await MainActor.run { isSavingName = true }
        do {
            try await repo.assignFace(faceId: entry.face.id, personId: person.id)
            await MainActor.run {
                syncService.enqueuePeopleDelta(
                    .assignFace(faceId: entry.face.id, personId: person.id)
                )
                NotificationCenter.default.post(name: .cloudSyncPeopleChanged, object: nil)
                namingEntry = nil
                isSavingName = false
                toast = ToastMessage(.success, "Named as \(person.name)")
            }
            await loadFaces()
        } catch {
            await MainActor.run {
                isSavingName = false
                toast = ToastMessage(.error, "Couldn't save name", subtitle: error.localizedDescription)
            }
        }
    }

    /// Primary Save button flow: if the typed name matches an existing
    /// named person (case-insensitive) we assign to them; otherwise we
    /// create a new person + assign this face to it.
    private func performSave(typedName: String, entry: FaceEntry) async {
        guard let db = appDatabase else { return }
        let repo = MobilePeopleRepository(db: db)
        await MainActor.run { isSavingName = true }

        // Case 1: typed name matches an existing person.
        let allPeople = (try? await repo.fetchPeople()) ?? []
        if let existing = allPeople.first(where: {
            $0.name.localizedCaseInsensitiveCompare(typedName) == .orderedSame
        }) {
            do {
                try await repo.assignFace(faceId: entry.face.id, personId: existing.id)
                await MainActor.run {
                    syncService.enqueuePeopleDelta(
                        .assignFace(faceId: entry.face.id, personId: existing.id)
                    )
                    NotificationCenter.default.post(name: .cloudSyncPeopleChanged, object: nil)
                    namingEntry = nil
                    isSavingName = false
                    toast = ToastMessage(.success, "Named as \(existing.name)")
                }
                await loadFaces()
            } catch {
                await MainActor.run {
                    isSavingName = false
                    toast = ToastMessage(.error, "Couldn't save name", subtitle: error.localizedDescription)
                }
            }
            return
        }

        // Case 2: brand-new person. Use the PeopleSyncDelta convenience to
        // mint a UUID, then mirror that id into the local DB + enqueue the
        // creation + assignment deltas back-to-back.
        let createDelta = PeopleSyncDelta.createPerson(name: typedName, coverFaceId: entry.face.id)
        guard case let .createPerson(newId, name, coverFaceId, createdAt) = createDelta else {
            await MainActor.run {
                isSavingName = false
                toast = ToastMessage(.error, "Couldn't save name", subtitle: "Invalid delta shape")
            }
            return
        }

        do {
            try await repo.createPerson(
                id: newId,
                name: name,
                coverFaceId: coverFaceId,
                createdAt: createdAt
            )
            try await repo.assignFace(faceId: entry.face.id, personId: newId)
            await MainActor.run {
                syncService.enqueuePeopleDelta(createDelta)
                syncService.enqueuePeopleDelta(
                    .assignFace(faceId: entry.face.id, personId: newId)
                )
                NotificationCenter.default.post(name: .cloudSyncPeopleChanged, object: nil)
                namingEntry = nil
                isSavingName = false
                toast = ToastMessage(.success, "Named as \(typedName)")
            }
            await loadFaces()
        } catch {
            await MainActor.run {
                isSavingName = false
                toast = ToastMessage(.error, "Couldn't save name", subtitle: error.localizedDescription)
            }
        }
    }

    // MARK: - Data

    private func loadFaces() async {
        guard let db = appDatabase else {
            await MainActor.run { self.isLoading = false }
            return
        }
        let photoId = photo.id
        let rows: [FaceEntry]
        do {
            rows = try await db.dbPool.read { conn -> [FaceEntry] in
                // Fetch face rows via the GRDB model (handles column mapping).
                let faces = try FaceEmbedding.fetchAll(conn, sql: """
                    SELECT * FROM face_embeddings
                    WHERE photo_id = ?
                    ORDER BY face_index ASC
                """, arguments: [photoId])

                // Collect unique, non-nil personIds and look up their names.
                let personIds = Set(faces.compactMap { $0.personId })
                var nameById: [String: String] = [:]
                if !personIds.isEmpty {
                    let placeholders = Array(repeating: "?", count: personIds.count).joined(separator: ",")
                    let sql = "SELECT id, name FROM person_identities WHERE id IN (\(placeholders))"
                    let args = StatementArguments(Array(personIds))
                    let lookupRows = try Row.fetchAll(conn, sql: sql, arguments: args)
                    for row in lookupRows {
                        let id: String = row["id"]
                        let name: String? = row["name"]
                        if let name, !name.isEmpty { nameById[id] = name }
                    }
                }

                return faces.map { face -> FaceEntry in
                    let name = face.personId.flatMap { nameById[$0] }
                    return FaceEntry(face: face, personName: name)
                }
            }
        } catch {
            print("[PhotoFacesStrip] load error: \(error)")
            await MainActor.run { self.isLoading = false }
            return
        }

        await MainActor.run {
            self.entries = rows
            self.isLoading = false
        }

        // Kick off face-crop loads in the background.
        await loadCrops(for: rows)
    }

    private func loadCrops(for rows: [FaceEntry]) async {
        let baseName = (photo.canonicalName as NSString).deletingPathExtension
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let proxyURL = appSupport
            .appendingPathComponent("HoehnPhotos")
            .appendingPathComponent("proxies")
            .appendingPathComponent(baseName + ".jpg")

        for entry in rows {
            let bbox = CGRect(
                x: entry.face.bboxX,
                y: entry.face.bboxY,
                width: entry.face.bboxWidth,
                height: entry.face.bboxHeight
            )
            let crop = await FaceCropCache.shared.crop(
                id: entry.face.id,
                proxyURL: proxyURL,
                bbox: bbox
            )
            if let crop {
                await MainActor.run {
                    self.cropsByFaceId[entry.face.id] = crop
                }
            }
        }
    }
}
