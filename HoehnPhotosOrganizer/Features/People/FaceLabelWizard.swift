import SwiftUI
import AppKit
import ImageIO

// MARK: - FaceLabelWizard
//
// Full-width sheet for rapid face labeling.  Shows unlabeled face clusters
// one at a time with keyboard number shortcuts (1-9) for the top known people,
// a text field for new/fuzzy-matched names, and per-face deselection so mixed
// clusters can be cleaned up before assignment.
//
// Layout: left sidebar with all known people (sorted by face count desc,
// searchable) + main area with face crop preview, text field, and action buttons.

struct FaceLabelWizard: View {

    @Environment(\.appDatabase) private var db
    @Environment(\.dismiss) private var dismiss

    var onDismiss: (() -> Void)? = nil

    // MARK: - State

    @State private var clusters: [[FaceGalleryRecord]] = []
    @State private var currentIndex = 0
    @State private var existingPeople: [PersonIdentity] = []
    /// Face counts per person ID for sorting the number-shortcut pills.
    @State private var faceCounts: [String: Int] = [:]
    /// Sample face record per person ID for the mini chip in number pills.
    @State private var personSampleRecord: [String: FaceGalleryRecord] = [:]
    @State private var assignName = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var autoAdvance = true
    @State private var confirmationFlash: String? = nil
    /// IDs of faces the user has tapped to deselect within the current cluster.
    @State private var deselectedFaceIds: Set<String> = []
    /// Search text for filtering the sidebar people list.
    @State private var sidebarSearch = ""
    /// Person ID selected in the sidebar (for highlighting).
    @State private var selectedPersonId: String? = nil
    /// Whether the "+N more" faces are expanded in a 5+ cluster.
    @State private var showAllFaces = false
    /// Face record currently being previewed (click-to-preview modal).
    @State private var previewRecord: FaceGalleryRecord? = nil
    @FocusState private var inputFocused: Bool

    private var currentCluster: [FaceGalleryRecord] {
        clusters.indices.contains(currentIndex) ? clusters[currentIndex] : []
    }

    /// All people sorted by face count descending.
    private var sortedPeople: [PersonIdentity] {
        existingPeople
            .sorted { (faceCounts[$0.id] ?? 0) > (faceCounts[$1.id] ?? 0) }
    }

    /// Sidebar people filtered by search text.
    private var filteredPeople: [PersonIdentity] {
        if sidebarSearch.isEmpty { return sortedPeople }
        let q = sidebarSearch.lowercased()
        return sortedPeople.filter { $0.name.lowercased().contains(q) }
    }

    /// Top 9 people sorted by face count descending (for 1-9 shortcuts).
    private var topPeople: [PersonIdentity] {
        Array(sortedPeople.prefix(9))
    }

    // MARK: - Non-Face Filter

    /// Maximum aspect ratio deviation from square for a face crop.
    /// Bounding boxes wider or taller than this ratio are likely hands/body parts.
    private static let maxAspectRatio: Double = 2.0

    /// Filter out clusters whose representative face bbox is far from square
    /// (likely a hand, body part, or other non-face detection).
    private static func isLikelyFace(_ record: FaceGalleryRecord) -> Bool {
        let w = record.embedding.bboxWidth
        let h = record.embedding.bboxHeight
        guard w > 0, h > 0 else { return false }
        let ratio = max(w, h) / min(w, h)
        return ratio <= maxAspectRatio
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if isLoading {
                Spacer()
                ProgressView("Clustering faces...").padding(40)
                Spacer()
            } else if clusters.isEmpty {
                emptyState
            } else {
                HSplitView {
                    peopleSidebar
                        .frame(minWidth: 180, idealWidth: 200, maxWidth: 260)
                    mainContent
                }
            }
        }
        .frame(minWidth: 800, minHeight: 550)
        .task { await loadData() }
        .onKeyPress(.leftArrow)  { navigate(-1); return .handled }
        .onKeyPress(.rightArrow) { navigate( 1); return .handled }
        .onKeyPress(.delete)     { removeSelected(); return .handled }
        .onKeyPress(.init("1")) { assignByNumber(0); return .handled }
        .onKeyPress(.init("2")) { assignByNumber(1); return .handled }
        .onKeyPress(.init("3")) { assignByNumber(2); return .handled }
        .onKeyPress(.init("4")) { assignByNumber(3); return .handled }
        .onKeyPress(.init("5")) { assignByNumber(4); return .handled }
        .onKeyPress(.init("6")) { assignByNumber(5); return .handled }
        .onKeyPress(.init("7")) { assignByNumber(6); return .handled }
        .onKeyPress(.init("8")) { assignByNumber(7); return .handled }
        .onKeyPress(.init("9")) { assignByNumber(8); return .handled }
        .onKeyPress(.init("s")) { markStranger(); return .handled }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Label Faces")
                    .font(.headline)
                Text(clusters.isEmpty
                    ? "All faces labeled"
                    : "\(clusters.count) cluster\(clusters.count == 1 ? "" : "s") remaining")
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
                        .frame(minWidth: 50, alignment: .center)

                    Button { navigate(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(currentIndex >= clusters.count - 1)
                }
            }

            Button("Done") {
                onDismiss?()
                dismiss()
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - People Sidebar

    private var peopleSidebar: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary).font(.system(size: 11))
                TextField("Filter people", text: $sidebarSearch)
                    .textFieldStyle(.plain).font(.system(size: 12))
                if !sidebarSearch.isEmpty {
                    Button { sidebarSearch = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain).controlSize(.small)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)

            Divider()

            // People list
            ScrollViewReader { proxy in
                List(selection: $selectedPersonId) {
                    ForEach(Array(filteredPeople.enumerated()), id: \.element.id) { idx, person in
                        let shortcutNumber = sidebarSearch.isEmpty ? topPeople.firstIndex(where: { $0.id == person.id }).map({ $0 + 1 }) : nil
                        SidebarPersonRow(
                            person: person,
                            faceCount: faceCounts[person.id] ?? 0,
                            sampleRecord: personSampleRecord[person.id],
                            shortcutNumber: shortcutNumber
                        )
                        .tag(person.id)
                        .onTapGesture {
                            selectedPersonId = person.id
                            assignName = person.name
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ZStack {
            VStack(spacing: 0) {
                // Face chips — center area with adaptive layout
                VStack(spacing: 8) {
                    Spacer(minLength: 8)

                    adaptiveFaceGrid

                    Text("Cluster of \(currentCluster.count) face\(currentCluster.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)

                    if !deselectedFaceIds.isEmpty {
                        Text("\(deselectedFaceIds.count) deselected — will be removed on assign")
                            .font(.caption2).foregroundStyle(.orange)
                    }

                    Spacer(minLength: 8)
                }

                Divider()

                // Assignment controls — bottom area
                VStack(spacing: 12) {
                    // Confirmation flash
                    if let flash = confirmationFlash {
                        Text(flash)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }

                    // Name input
                    HStack(spacing: 10) {
                        Image(systemName: "person.fill")
                            .foregroundStyle(.secondary).font(.system(size: 14))

                        TextField("Type a name or select from sidebar...", text: $assignName)
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

                    // Fuzzy-match dropdown
                    let suggestions = assignName.isEmpty ? [] : fuzzyMatch(assignName)
                    if !suggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(suggestions) { person in
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

                    // Action buttons
                    HStack(spacing: 8) {
                        Button("Assign") { assignCurrentCluster() }
                            .buttonStyle(.borderedProminent).controlSize(.regular)
                            .disabled(assignName.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)

                        Button("Stranger") { markStranger() }
                            .buttonStyle(.bordered).controlSize(.regular).disabled(isSaving)

                        if !deselectedFaceIds.isEmpty {
                            Button("Remove Selected") { removeSelected() }
                                .buttonStyle(.bordered).controlSize(.regular)
                                .tint(.orange)
                                .disabled(isSaving)
                        }

                        Button("Skip") { skipCluster() }
                            .buttonStyle(.plain).foregroundStyle(.secondary).disabled(isSaving)

                        Spacer()
                        if isSaving { ProgressView().controlSize(.small) }
                    }

                    // Keyboard hints
                    HStack(spacing: 16) {
                        Text("1-9 assign top people")
                        Text("S stranger")
                        Text("\u{2190}\u{2192} navigate")
                        Text("Click face to preview")
                        if currentCluster.count > 1 {
                            Text("Double-click to deselect")
                        }
                    }
                    .font(.system(size: 10)).foregroundStyle(.quaternary)
                }
                .padding(20)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { inputFocused = true }

            // Click-to-preview modal overlay
            if let record = previewRecord {
                FacePreviewOverlay(record: record) {
                    previewRecord = nil
                }
            }
        }
    }

    // MARK: - Adaptive Face Grid

    @ViewBuilder
    private var adaptiveFaceGrid: some View {
        let activeFaces = currentCluster
        let count = activeFaces.count

        if count == 1, let face = activeFaces.first {
            // Single face: large circle with photo name
            VStack(spacing: 10) {
                WizardFaceChip(
                    record: face,
                    isDeselected: deselectedFaceIds.contains(face.id),
                    size: 200
                )
                .onTapGesture { previewRecord = face }

                Text(face.canonicalName)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        } else if count <= 4 {
            // 2-4 faces: row of ~120pt circles
            HStack(spacing: 14) {
                ForEach(activeFaces) { record in
                    WizardFaceChip(
                        record: record,
                        isDeselected: deselectedFaceIds.contains(record.id),
                        size: 120
                    )
                    .onTapGesture(count: 2) { toggleDeselect(record.id) }
                    .onTapGesture { previewRecord = record }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        } else {
            // 5+ faces: 2x2 grid of first 4 + "+N more"
            VStack(spacing: 10) {
                if showAllFaces {
                    // Expanded: scrollable grid of all faces
                    ScrollView {
                        LazyVGrid(columns: [
                            GridItem(.adaptive(minimum: 80, maximum: 90), spacing: 10)
                        ], spacing: 10) {
                            ForEach(activeFaces) { record in
                                WizardFaceChip(
                                    record: record,
                                    isDeselected: deselectedFaceIds.contains(record.id),
                                    size: 80
                                )
                                .onTapGesture { previewRecord = record }
                                .simultaneousGesture(
                                    TapGesture(count: 2).onEnded { toggleDeselect(record.id) }
                                )
                            }
                        }
                        .padding(.horizontal, 20).padding(.vertical, 8)
                    }
                    .frame(maxHeight: 240)

                    Button("Show less") { withAnimation { showAllFaces = false } }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
                } else {
                    // Collapsed: 2x2 grid of first 4
                    let preview = Array(activeFaces.prefix(4))
                    LazyVGrid(columns: [
                        GridItem(.fixed(80), spacing: 10),
                        GridItem(.fixed(80), spacing: 10)
                    ], spacing: 10) {
                        ForEach(preview) { record in
                            WizardFaceChip(
                                record: record,
                                isDeselected: deselectedFaceIds.contains(record.id),
                                size: 80
                            )
                            .onTapGesture { previewRecord = record }
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded { toggleDeselect(record.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 8)

                    let remaining = count - 4
                    Button("+\(remaining) more") { withAnimation { showAllFaces = true } }
                        .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 48)).foregroundStyle(.green)
            Text("All faces labeled").font(.title3.bold())
            Text("Every detected face has been assigned to a person or marked as stranger.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 280)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Fuzzy Match

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
        selectedPersonId = nil
        deselectedFaceIds = []
        showAllFaces = false
        withAnimation { confirmationFlash = nil }
        inputFocused = true
    }

    private func skipCluster() { navigate(1) }

    private func toggleDeselect(_ faceId: String) {
        if deselectedFaceIds.contains(faceId) {
            deselectedFaceIds.remove(faceId)
        } else {
            // Don't allow deselecting ALL faces
            if deselectedFaceIds.count < currentCluster.count - 1 {
                deselectedFaceIds.insert(faceId)
            }
        }
    }

    // MARK: - Confirmation + Auto-Advance

    private func showConfirmationAndAdvance(_ message: String) {
        withAnimation { confirmationFlash = message }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            withAnimation { confirmationFlash = nil }
            if autoAdvance && !clusters.isEmpty {
                assignName = ""
                selectedPersonId = nil
                deselectedFaceIds = []
                showAllFaces = false
                inputFocused = true
            }
        }
    }

    // MARK: - Assign by Number

    private func assignByNumber(_ index: Int) {
        guard topPeople.indices.contains(index), !isSaving else { return }
        let name = topPeople[index].name
        assignName = name
        selectedPersonId = topPeople[index].id
        assignCurrentCluster()
    }

    // MARK: - Assign

    private func assignCurrentCluster() {
        let name = assignName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !isSaving, let db else { return }

        // Get IDs of faces that are NOT deselected
        let keepIds = currentCluster.filter { !deselectedFaceIds.contains($0.id) }.map(\.id)
        guard !keepIds.isEmpty else { return }

        isSaving = true
        Task {
            do {
                // Assign the kept faces
                try await FaceLabelingService.label(
                    faceIds: keepIds, as: name,
                    personRepo: PersonRepository(db: db),
                    faceRepo: FaceEmbeddingRepository(db: db)
                )

                // If there were deselected faces, put them back as individual clusters
                let removedRecords = currentCluster.filter { deselectedFaceIds.contains($0.id) }
                let newSingletons = removedRecords.map { [$0] }

                let updatedPeople = (try? await PersonRepository(db: db).fetchAll()) ?? []
                let updatedStats = await computePersonStats(db: db)

                await MainActor.run {
                    clusters.remove(at: currentIndex)
                    // Insert singletons from deselected faces back into the list
                    for singleton in newSingletons.reversed() {
                        clusters.insert(singleton, at: min(currentIndex, clusters.count))
                    }
                    currentIndex = min(currentIndex, max(0, clusters.count - 1))
                    existingPeople = updatedPeople.filter { $0.name != "Stranger" }
                    faceCounts = updatedStats.counts
                    personSampleRecord = updatedStats.samples
                    assignName = ""
                    selectedPersonId = nil
                    deselectedFaceIds = []
                    isSaving = false
                    inputFocused = true
                    showConfirmationAndAdvance("Assigned to \(name)")
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    confirmationFlash = nil
                }
                print("[FaceLabelWizard] assign error: \(error)")
            }
        }
    }

    // MARK: - Stranger

    private func markStranger() {
        guard !isSaving, let db else { return }
        let keepIds = currentCluster.filter { !deselectedFaceIds.contains($0.id) }.map(\.id)
        guard !keepIds.isEmpty else { return }

        let removedRecords = currentCluster.filter { deselectedFaceIds.contains($0.id) }
        let newSingletons = removedRecords.map { [$0] }

        isSaving = true
        Task {
            do {
                try await FaceLabelingService.label(
                    faceIds: keepIds, as: "Stranger",
                    personRepo: PersonRepository(db: db),
                    faceRepo: FaceEmbeddingRepository(db: db)
                )
                await MainActor.run {
                    clusters.remove(at: currentIndex)
                    for singleton in newSingletons.reversed() {
                        clusters.insert(singleton, at: min(currentIndex, clusters.count))
                    }
                    currentIndex = min(currentIndex, max(0, clusters.count - 1))
                    assignName = ""
                    selectedPersonId = nil
                    deselectedFaceIds = []
                    isSaving = false
                    inputFocused = true
                    showConfirmationAndAdvance("Marked as Stranger")
                }
            } catch {
                await MainActor.run { isSaving = false }
                print("[FaceLabelWizard] stranger error: \(error)")
            }
        }
    }

    // MARK: - Remove Selected (deselected faces become singletons)

    private func removeSelected() {
        guard !deselectedFaceIds.isEmpty else { return }
        let remaining = currentCluster.filter { !deselectedFaceIds.contains($0.id) }
        let removed = currentCluster.filter { deselectedFaceIds.contains($0.id) }

        // Replace current cluster with just the remaining faces
        if remaining.isEmpty {
            // Shouldn't happen (we prevent deselecting all), but guard anyway
            return
        }

        clusters[currentIndex] = remaining
        // Add removed faces as individual clusters at the end
        for face in removed {
            clusters.append([face])
        }
        deselectedFaceIds = []
    }

    // MARK: - Load Data

    private func loadData() async {
        guard let db else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let faceRepo = FaceEmbeddingRepository(db: db)
            let personRepo = PersonRepository(db: db)

            // Gallery records for display
            let allRecords = try await faceRepo.fetchGalleryRecords()
            let unlabeledRec = allRecords.filter { !$0.isLabeled }

            // Embeddings with feature vectors for clustering
            let unlabeledEmb = try await faceRepo.fetchUnlabeled()
            let faceClusters = FaceLabelingService.clusterUnlabeled(embeddings: unlabeledEmb)

            // Map cluster IDs to display records
            let byId = Dictionary(uniqueKeysWithValues: unlabeledRec.map { ($0.id, $0) })
            let clusterRecords = faceClusters
                .map { c in c.faceIds.compactMap { byId[$0] } }
                .filter { !$0.isEmpty }
                // Filter out clusters where ALL faces have non-face-like aspect ratios
                .filter { cluster in cluster.contains(where: Self.isLikelyFace) }
                // Within each cluster, drop individual non-face detections
                .map { cluster in cluster.filter(Self.isLikelyFace) }
                .filter { !$0.isEmpty }

            let people = try await personRepo.fetchAll()
            let stats = await computePersonStats(db: db)

            let filteredCount = faceClusters.count - clusterRecords.count
            if filteredCount > 0 {
                print("[FaceLabelWizard] Filtered out \(filteredCount) non-face cluster(s) by aspect ratio")
            }

            await MainActor.run {
                clusters = clusterRecords.sorted { $0.count > $1.count }
                existingPeople = people.filter { $0.name != "Stranger" }
                faceCounts = stats.counts
                personSampleRecord = stats.samples
            }
        } catch {
            print("[FaceLabelWizard] load error: \(error)")
        }
    }

    /// Compute face counts and sample records per person from gallery records.
    private func computePersonStats(db: AppDatabase) async -> (counts: [String: Int], samples: [String: FaceGalleryRecord]) {
        let faceRepo = FaceEmbeddingRepository(db: db)
        guard let records = try? await faceRepo.fetchGalleryRecords() else { return ([:], [:]) }
        var counts: [String: Int] = [:]
        var samples: [String: FaceGalleryRecord] = [:]
        for r in records {
            if let pid = r.embedding.personId, r.personName != "Stranger" {
                counts[pid, default: 0] += 1
                if samples[pid] == nil { samples[pid] = r }
            }
        }
        return (counts, samples)
    }
}

// MARK: - SidebarPersonRow

private struct SidebarPersonRow: View {
    let person: PersonIdentity
    let faceCount: Int
    let sampleRecord: FaceGalleryRecord?
    let shortcutNumber: Int?

    @State private var image: NSImage? = nil

    var body: some View {
        HStack(spacing: 8) {
            // Shortcut number badge
            if let num = shortcutNumber {
                Text("\(num)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Color.accentColor))
            }

            // Face thumbnail
            Group {
                if let img = image {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 24, height: 24)
                        .clipShape(Circle())
                } else {
                    Circle().fill(Color.primary.opacity(0.08))
                        .frame(width: 24, height: 24)
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                }
            }

            // Name
            Text(person.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            // Face count badge
            Text("\(faceCount)")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(
                    Capsule().fill(Color.primary.opacity(0.06))
                )
        }
        .contentShape(Rectangle())
        .task { await loadCrop() }
    }

    private func loadCrop() async {
        guard let record = sampleRecord else { return }
        image = await FaceCropCache.shared.crop(
            id: record.id,
            proxyURL: record.proxyURL,
            bbox: record.bbox
        )
    }
}

// MARK: - WizardFaceChip

private struct WizardFaceChip: View {
    let record: FaceGalleryRecord
    let isDeselected: Bool
    var size: CGFloat = 80
    @State private var image: NSImage? = nil

    var body: some View {
        ZStack {
            if let img = image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(
                        isDeselected ? Color.red : Color.primary.opacity(0.12),
                        lineWidth: isDeselected ? 2 : 1
                    ))
                    .opacity(isDeselected ? 0.4 : 1.0)
            } else {
                Circle().fill(Color.primary.opacity(0.06))
                    .frame(width: size, height: size)
                    .overlay { ProgressView().controlSize(.small) }
            }

            if isDeselected {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: min(size * 0.25, 20)))
                    .foregroundStyle(.red)
            }
        }
        .contentShape(Circle())
        .task { await loadCrop() }
    }

    private func loadCrop() async {
        image = await FaceCropCache.shared.crop(
            id: record.id,
            proxyURL: record.proxyURL,
            bbox: record.bbox
        )
    }
}

// MARK: - PersonMiniChip

/// Small circular face chip for a person's representative face in the number pills.
/// Uses a preloaded gallery record for the person's cover face.
private struct PersonMiniChip: View {
    let record: FaceGalleryRecord?
    @State private var image: NSImage? = nil

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 20, height: 20)
                    .clipShape(Circle())
            } else {
                Circle().fill(Color.primary.opacity(0.08))
                    .frame(width: 20, height: 20)
            }
        }
        .task { await loadCrop() }
    }

    private func loadCrop() async {
        guard let record else { return }
        image = await FaceCropCache.shared.crop(
            id: record.id,
            proxyURL: record.proxyURL,
            bbox: record.bbox
        )
    }
}

// MARK: - FacePreviewOverlay

/// Modal overlay showing a larger face crop and the full source photo with
/// the face bounding box highlighted.  Dismissed by clicking outside or pressing Escape.
private struct FacePreviewOverlay: View {
    let record: FaceGalleryRecord
    let onDismiss: () -> Void

    @State private var faceCrop: NSImage? = nil
    @State private var fullPhoto: NSImage? = nil

    var body: some View {
        ZStack {
            // Dimmed backdrop — click to dismiss
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 20) {
                // Large face crop
                Group {
                    if let crop = faceCrop {
                        Image(nsImage: crop).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 300, height: 300)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.primary.opacity(0.06))
                            .frame(width: 300, height: 300)
                            .overlay { ProgressView() }
                    }
                }

                // Full source photo with face bbox highlighted
                if let photo = fullPhoto {
                    ZStack {
                        Image(nsImage: photo).resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 500, maxHeight: 350)
                            .overlay(alignment: .topLeading) {
                                GeometryReader { geo in
                                    let r = record.bbox
                                    let x = r.origin.x * geo.size.width
                                    let y = r.origin.y * geo.size.height
                                    let w = r.width * geo.size.width
                                    let h = r.height * geo.size.height
                                    Rectangle()
                                        .strokeBorder(Color.yellow, lineWidth: 2)
                                        .frame(width: w, height: h)
                                        .offset(x: x, y: y)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                Text(record.canonicalName)
                    .font(.caption).foregroundStyle(.white.opacity(0.7))

                Text("Click outside or press Esc to close")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }
            .padding(30)
        }
        .onKeyPress(.escape) { onDismiss(); return .handled }
        .task { await loadImages() }
    }

    private func loadImages() async {
        // Load face crop
        faceCrop = await FaceCropCache.shared.crop(
            id: record.id,
            proxyURL: record.proxyURL,
            bbox: record.bbox
        )

        // Load full proxy photo
        fullPhoto = await Task.detached(priority: .utility) {
            guard let src = CGImageSourceCreateWithURL(record.proxyURL as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                return nil as NSImage?
            }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value
    }
}
