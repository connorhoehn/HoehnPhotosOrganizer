import SwiftUI
import AppKit

// MARK: - JobPeopleWidget
//
// Inline face-identification carousel scoped to a single job.
// Shows unlabeled face clusters one at a time. ← → keys navigate clusters,
// Return assigns, and the name field fuzzy-matches against known people.
// No navigation away from the job view.

struct JobPeopleWidget: View {
    let photoIds: [String]
    var onDone: (() -> Void)? = nil

    @Environment(\.appDatabase) private var db
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var clusters: [[FaceGalleryRecord]] = []
    @State private var unlabeledCount = 0
    @State private var totalFaceCount = 0
    @State private var currentIndex = 0
    @State private var existingPeople: [PersonIdentity] = []
    @State private var assignName = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var statusMsg: String? = nil
    @State private var autoAdvance = true
    @State private var confirmationFlash: String? = nil
    @FocusState private var inputFocused: Bool

    private var currentCluster: [FaceGalleryRecord] { clusters[safe: currentIndex] ?? [] }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if isLoading {
                Spacer()
                ProgressView("Loading faces…").padding(40)
                Spacer()
            } else if unlabeledCount == 0 {
                emptyState
            } else {
                clusterCarousel
            }
        }
        .frame(minWidth: 580, minHeight: 400)
        .task { await loadData() }
        .onKeyPress(.leftArrow)  { navigate(-1); return .handled }
        .onKeyPress(.rightArrow) { navigate( 1); return .handled }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Identify People")
                    .font(.headline)
                Text(unlabeledCount == 0
                    ? "All faces identified"
                    : "\(unlabeledCount) of \(totalFaceCount) faces to identify")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()

            if !clusters.isEmpty {
                Toggle("Auto-advance", isOn: $autoAdvance)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    Button { navigate(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(currentIndex == 0)

                    Text("\(currentIndex + 1) / \(clusters.count)")
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .frame(minWidth: 44, alignment: .center)

                    Button { navigate(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(currentIndex >= clusters.count - 1)
                }
            }
            Button("Done") { onDone?(); dismiss() }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    // MARK: - Cluster Carousel

    private var clusterCarousel: some View {
        VStack(spacing: 0) {
            // Face chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(currentCluster) { record in
                        JobFaceChip(record: record)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 20)
            }
            .frame(minHeight: 130)

            Divider()

            // Assignment controls
            VStack(spacing: 12) {
                if let flash = confirmationFlash {
                    Text(flash)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .transition(.opacity)
                } else if let msg = statusMsg {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                        .transition(.opacity)
                }

                // Name input
                HStack(spacing: 10) {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary).font(.system(size: 14))

                    TextField("Type a name…", text: $assignName)
                        .textFieldStyle(.plain).font(.system(size: 14))
                        .focused($inputFocused)
                        .onSubmit { assignCurrentCluster() }

                    if !assignName.isEmpty {
                        Button { assignName = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(inputFocused ? Color.accentColor : Color.secondary.opacity(0.25),
                                    lineWidth: 1))
                )

                // People quick-chips (suggestions when typing, full list when empty)
                let chips = assignName.isEmpty ? existingPeople : fuzzyMatch(assignName)
                if !chips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(chips) { person in
                                Button(person.name) {
                                    assignName = person.name
                                    assignCurrentCluster()
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }
                    .frame(height: 30)
                }

                // Actions
                HStack(spacing: 8) {
                    Button("Assign") { assignCurrentCluster() }
                        .buttonStyle(.borderedProminent).controlSize(.regular)
                        .disabled(assignName.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)

                    Button("Stranger") { markStranger() }
                        .buttonStyle(.bordered).controlSize(.regular).disabled(isSaving)

                    Button("Skip →") { skipCluster() }
                        .buttonStyle(.plain).foregroundStyle(.secondary).disabled(isSaving)

                    Spacer()
                    if isSaving { ProgressView().controlSize(.small) }
                }
            }
            .padding(20)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        }
        .frame(maxHeight: .infinity)
        .onAppear { inputFocused = true }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 48)).foregroundStyle(.green)
            Text("All faces identified").font(.title3.bold())
            Text("Every detected face in this job has been assigned.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 260)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Fuzzy match

    private func fuzzyMatch(_ query: String) -> [PersonIdentity] {
        let q = query.lowercased()
        let prefix  = existingPeople.filter { $0.name.lowercased().hasPrefix(q) }
        let contain = existingPeople.filter { !$0.name.lowercased().hasPrefix(q) && $0.name.lowercased().contains(q) }
        return prefix + contain
    }

    // MARK: - Navigation

    private func navigate(_ delta: Int) {
        let next = currentIndex + delta
        guard clusters.indices.contains(next) else { return }
        currentIndex = next
        assignName = ""
        withAnimation { statusMsg = nil; confirmationFlash = nil }
        inputFocused = true
    }

    private func skipCluster() { navigate(1) }

    // MARK: - Auto-advance helpers

    /// Show a brief confirmation flash, then auto-advance to the next cluster if enabled.
    /// Called after a cluster is removed from the array following a successful assign/stranger.
    private func showConfirmationAndAdvance(_ message: String) {
        withAnimation { confirmationFlash = message }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            withAnimation { confirmationFlash = nil }

            if autoAdvance && !clusters.isEmpty {
                // After removal, currentIndex already points at the next cluster
                // (or was clamped to the last one). Just reset the input.
                assignName = ""
                inputFocused = true
            }
        }
    }

    // MARK: - Assign

    private func assignCurrentCluster() {
        let name = assignName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !isSaving, let db else { return }
        let ids = currentCluster.map(\.id)
        isSaving = true
        Task {
            do {
                try await FaceLabelingService.label(
                    faceIds: ids, as: name,
                    personRepo: PersonRepository(db: db),
                    faceRepo: FaceEmbeddingRepository(db: db)
                )
                let updatedPeople = (try? await PersonRepository(db: db).fetchAll()) ?? []
                await MainActor.run {
                    clusters.remove(at: currentIndex)
                    currentIndex = min(currentIndex, max(0, clusters.count - 1))
                    existingPeople = updatedPeople.filter { $0.name != "Stranger" }
                    assignName = ""
                    isSaving = false
                    inputFocused = true
                    showConfirmationAndAdvance("Assigned as \(name)")
                }
            } catch {
                await MainActor.run { statusMsg = "Error: \(error.localizedDescription)"; isSaving = false }
            }
        }
    }

    private func markStranger() {
        guard !isSaving, let db else { return }
        let ids = currentCluster.map(\.id)
        isSaving = true
        Task {
            do {
                try await FaceLabelingService.label(
                    faceIds: ids, as: "Stranger",
                    personRepo: PersonRepository(db: db),
                    faceRepo: FaceEmbeddingRepository(db: db)
                )
                await MainActor.run {
                    clusters.remove(at: currentIndex)
                    currentIndex = min(currentIndex, max(0, clusters.count - 1))
                    assignName = ""
                    isSaving = false
                    inputFocused = true
                    showConfirmationAndAdvance("Marked as Stranger")
                }
            } catch {
                await MainActor.run { statusMsg = "Error: \(error.localizedDescription)"; isSaving = false }
            }
        }
    }

    // MARK: - Load

    private func loadData() async {
        guard let db else { return }
        guard !photoIds.isEmpty else {
            print("[JobPeopleWidget] Warning: photoIds is empty — no faces to load")
            isLoading = false
            return
        }
        isLoading = true; defer { isLoading = false }
        do {
            let faceRepo   = FaceEmbeddingRepository(db: db)
            let personRepo = PersonRepository(db: db)

            // Gallery records for display (no feature vectors needed)
            let allRecords   = try await faceRepo.fetchGalleryRecords(photoIds: photoIds)
            let unlabeledRec = allRecords.filter { !$0.isLabeled }

            // Embeddings with feature vectors for clustering
            let unlabeledEmb = try await faceRepo.fetchUnlabeled(photoIds: photoIds)
            let faceClusters = FaceLabelingService.clusterUnlabeled(embeddings: unlabeledEmb)

            // Map cluster IDs → display records
            let byId = Dictionary(uniqueKeysWithValues: unlabeledRec.map { ($0.id, $0) })
            let clusterRecords = faceClusters
                .map { c in c.faceIds.compactMap { byId[$0] } }
                .filter { !$0.isEmpty }

            let people = try await personRepo.fetchAll()

            await MainActor.run {
                clusters       = clusterRecords
                unlabeledCount = unlabeledRec.count
                totalFaceCount = allRecords.count
                existingPeople = people.filter { $0.name != "Stranger" }
            }
        } catch {
            print("[JobPeopleWidget] load error: \(error)")
        }
    }
}

// MARK: - JobFaceChip

private struct JobFaceChip: View {
    let record: FaceGalleryRecord
    @State private var image: NSImage? = nil

    var body: some View {
        ZStack {
            if let img = image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 88, height: 88)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            } else {
                Circle().fill(Color.primary.opacity(0.06))
                    .frame(width: 88, height: 88)
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .task { await loadCrop() }
    }

    private func loadCrop() async {
        let url = record.proxyURL; let bbox = record.bbox
        let img = await Task.detached(priority: .utility) {
            guard let cg   = FaceEmbeddingService.loadCGImage(from: url),
                  let crop = FaceEmbeddingService.cropFace(from: cg, bbox: bbox)
            else { return nil as NSImage? }
            return NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))
        }.value
        await MainActor.run { image = img }
    }
}

// MARK: - Array safe subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
