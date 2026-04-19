import SwiftUI
import GRDB
import HoehnPhotosCore

// MARK: - PhotoFacesStrip
//
// Horizontal row of FaceChips, one per detected face in the photo.
// - Named chip -> toast "Filter by <name> coming soon"
// - Unknown chip -> toast "Naming coming soon"
// Actions are placeholders. Hooked up in Phase 2 face-naming feature.
//
// SQL is inlined here (rather than added to MobilePeopleRepository) because
// another agent is currently editing MobileRepositories.swift. If that
// restriction lifts, migrate `loadFaces` into MobilePeopleRepository as
// `fetchFacesForPhoto(photoId:)` returning (FaceEmbedding, String?) tuples.

struct PhotoFacesStrip: View {
    let photo: PhotoAsset
    @Binding var toast: ToastMessage?

    @Environment(\.appDatabase) private var appDatabase

    @State private var entries: [FaceEntry] = []
    @State private var cropsByFaceId: [String: UIImage] = [:]
    @State private var isLoading = true

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

    // MARK: - Tap handling (placeholders)

    private func onTap(_ entry: FaceEntry) {
        HPHaptic.selection()
        if let name = entry.personName, !name.isEmpty {
            toast = ToastMessage(.info, "Filter by \(name) coming soon")
        } else {
            toast = ToastMessage(.info, "Naming coming soon")
        }
        // Hooked up in Phase 2 face-naming feature.
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
