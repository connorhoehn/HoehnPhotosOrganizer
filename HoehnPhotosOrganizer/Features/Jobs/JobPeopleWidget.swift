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
    /// Fired after a successful label/skip operation so the host (JobDetailView) can
    /// re-query its face counters and keep the background card's "X of N identified"
    /// progress in sync with what the modal is showing. Without this, the card stays
    /// frozen at the count from when the modal opened.
    var onLabelsChanged: (() -> Void)? = nil

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

    /// Records the most recent label/skip/stranger action so Undo can revert it.
    /// `clusterSnapshot` lets us put the cluster back in the carousel after a clearPerson
    /// since the loop normally removes processed clusters.
    @State private var lastAction: UndoableAction? = nil

    /// Set when the user taps "Mark Rest as Strangers" — wires a confirmation dialog
    /// before the destructive action so accidental clicks have a back-out.
    @State private var showBulkConfirm = false

    private struct UndoableAction {
        let faceIds: [String]
        let clusterSnapshot: [FaceGalleryRecord]   // the cluster that was labeled
        let insertAtIndex: Int                     // where to re-insert it on undo
        let label: String                          // human-readable for the toast
    }

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

                // Bulk-finish escape hatch: when the user has labeled the people they
                // care about and just wants to mark the rest off, one click marks
                // every remaining unlabeled face as Stranger and closes the modal.
                Button {
                    showBulkConfirm = true
                } label: {
                    Label("Mark Rest as Strangers", systemImage: "person.crop.circle.badge.xmark")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Mark every remaining unlabeled face as Stranger and close")
                .disabled(isSaving || unlabeledCount == 0)
                .confirmationDialog(
                    "Mark \(unlabeledCount) face\(unlabeledCount == 1 ? "" : "s") as Stranger?",
                    isPresented: $showBulkConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Mark \(unlabeledCount) as Stranger", role: .destructive) {
                        markAllRemainingAsStranger()
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("You can still undo individual faces from the People gallery, but this closes the wizard.")
                }
            }

            // Undo the most recent label/skip/bulk operation. Visible whenever there's
            // an action on the stack — clearing it restores the cluster to the carousel.
            if let last = lastAction {
                Button {
                    undoLastAction()
                } label: {
                    Label("Undo \(last.label)", systemImage: "arrow.uturn.backward")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Restore the most recently labeled cluster to unlabeled")
                .disabled(isSaving)
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
                    let removedIndex = currentIndex
                    let removedCluster = clusters[removedIndex]
                    clusters.remove(at: currentIndex)
                    currentIndex = min(currentIndex, max(0, clusters.count - 1))
                    existingPeople = updatedPeople.filter { $0.name != "Stranger" }
                    // Recompute the modal's own visible counts so headerBar's
                    // "X of Y faces to identify" stays in sync as clusters drain.
                    unlabeledCount = max(0, unlabeledCount - ids.count)
                    assignName = ""
                    isSaving = false
                    inputFocused = true
                    showConfirmationAndAdvance("Assigned as \(name)")
                    lastAction = UndoableAction(
                        faceIds: ids,
                        clusterSnapshot: removedCluster,
                        insertAtIndex: removedIndex,
                        label: "Assign"
                    )
                    onLabelsChanged?()
                }
            } catch {
                await MainActor.run { statusMsg = "Error: \(error.localizedDescription)"; isSaving = false }
            }
        }
    }

    /// Reverts the most recent label/stranger/bulk action — calls `clearPerson` on each
    /// of the affected face IDs, then re-inserts the cluster snapshot back into the
    /// carousel at its original position. For bulk operations, `clusterSnapshot` holds
    /// the merged set of all faces that were stranger'd in a single pseudo-cluster.
    private func undoLastAction() {
        guard !isSaving, let db, let last = lastAction else { return }
        isSaving = true
        Task {
            let faceRepo = FaceEmbeddingRepository(db: db)
            for id in last.faceIds {
                try? await faceRepo.clearPerson(faceId: id)
            }
            await MainActor.run {
                let insertAt = min(last.insertAtIndex, clusters.count)
                clusters.insert(last.clusterSnapshot, at: insertAt)
                currentIndex = insertAt
                unlabeledCount += last.faceIds.count
                lastAction = nil
                isSaving = false
                inputFocused = true
                showConfirmationAndAdvance("Undone")
                onLabelsChanged?()
            }
        }
    }

    /// Bulk-finish path: marks every face across every remaining cluster as Stranger
    /// in a single batched DB write, then dismisses. Lets the user escape the
    /// one-cluster-at-a-time pace when they've labeled everyone they care about.
    private func markAllRemainingAsStranger() {
        guard !isSaving, let db else { return }
        // Flatten every cluster's face IDs — clusters[currentIndex] included.
        let allIds = clusters.flatMap { $0.map(\.id) }
        guard !allIds.isEmpty else { onDone?(); dismiss(); return }
        // Snapshot the entire flat cluster set so an Undo can restore them all.
        let flatSnapshot = clusters.flatMap { $0 }
        let originalIndex = currentIndex
        isSaving = true
        Task {
            do {
                try await FaceLabelingService.label(
                    faceIds: allIds, as: "Stranger",
                    personRepo: PersonRepository(db: db),
                    faceRepo: FaceEmbeddingRepository(db: db)
                )
                await MainActor.run {
                    clusters.removeAll()
                    currentIndex = 0
                    unlabeledCount = 0
                    isSaving = false
                    // Don't auto-dismiss — leave the user with the empty state plus the
                    // Undo button in the header. They can click Undo to revert, or Done
                    // to close. This is the post-action undo window the user asked for.
                    lastAction = UndoableAction(
                        faceIds: allIds,
                        clusterSnapshot: flatSnapshot,
                        insertAtIndex: originalIndex,
                        label: "Mark Rest"
                    )
                    showConfirmationAndAdvance("Marked \(allIds.count) as Stranger")
                    onLabelsChanged?()
                }
            } catch {
                await MainActor.run {
                    statusMsg = "Error: \(error.localizedDescription)"
                    isSaving = false
                }
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
                    let removedIndex = currentIndex
                    let removedCluster = clusters[removedIndex]
                    clusters.remove(at: currentIndex)
                    currentIndex = min(currentIndex, max(0, clusters.count - 1))
                    unlabeledCount = max(0, unlabeledCount - ids.count)
                    assignName = ""
                    isSaving = false
                    inputFocused = true
                    showConfirmationAndAdvance("Marked as Stranger")
                    lastAction = UndoableAction(
                        faceIds: ids,
                        clusterSnapshot: removedCluster,
                        insertAtIndex: removedIndex,
                        label: "Stranger"
                    )
                    onLabelsChanged?()
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
