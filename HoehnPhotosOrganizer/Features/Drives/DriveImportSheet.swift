import SwiftUI
import GRDB

// MARK: - DriveImportSheet

/// Two-phase import sheet: (1) adds photos to the library, (2) runs analysis workflows.
/// Progress for each phase is shown inline; workflows run on MountedDriveState and
/// continue in the background even if the sheet is dismissed.
struct DriveImportSheet: View {

    @ObservedObject var drive: MountedDriveState
    /// IDs of photos the user had selected in the grid.
    let selectedPhotoIDs: Set<String>
    let onDismiss: () -> Void

    @Environment(\.appDatabase) private var db
    @Environment(\.libraryViewModel) private var libraryViewModel
    @Environment(\.activityEventService) private var activityService

    // Workflow selection — Orientation + Faces on by default
    @State private var selectedWorkflows: Set<DriveWorkflow> = [.orientation, .faces]

    // Phase tracking
    @State private var phase: ImportPhase = .idle
    @State private var importCurrent = 0
    @State private var importTotal   = 0

    // Job proposal state
    @State private var proposedJobs: [ProposedJob] = []
    @State private var approvedJobs: [ProposedJob] = []
    @State private var showJobProposal = false
    private let proposalService = JobProposalService()

    // Library presence check (queried on appear)
    @State private var alreadyInLibraryIDs: Set<String> = []
    @State private var isCheckingLibrary = true

    enum ImportPhase: Equatable {
        case idle
        case proposingJobs          // generating AI proposals
        case importing
        case runningWorkflows
        case done(Int)              // associated value = number of photos imported
    }

    // MARK: - Helpers

    private var allSelected: [DrivePhotoRecord] {
        selectedPhotoIDs.compactMap { id in drive.photos.first { $0.id == id } }
    }

    /// Photos whose file path is not already in the main library DB.
    private var newPhotos: [DrivePhotoRecord] {
        allSelected.filter { !alreadyInLibraryIDs.contains($0.id) }
    }

    private var alreadyImportedCount: Int {
        alreadyInLibraryIDs.count
    }

    private var allAlreadyImported: Bool {
        !isCheckingLibrary && !allSelected.isEmpty && newPhotos.isEmpty
    }

    private var isRunning: Bool {
        phase == .proposingJobs || phase == .importing || phase == .runningWorkflows
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch phase {
                    case .idle:
                        if isCheckingLibrary {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("Checking library…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else if allAlreadyImported {
                            alreadyImportedBanner
                        } else {
                            workflowPicker
                            photoSummary
                        }
                    case .proposingJobs:
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Asking Claude to propose job buckets…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    case .importing, .runningWorkflows, .done:
                        progressSteps
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await checkAlreadyImported() }
        // Advance from runningWorkflows → done when drive finishes
        .onChange(of: drive.isRunningWorkflows) { _, running in
            if !running, phase == .runningWorkflows {
                phase = .done(importCurrent)
            }
        }
        .sheet(isPresented: $showJobProposal) {
            JobProposalView(
                proposals: proposedJobs,
                approvedJobs: $approvedJobs,
                onConfirm: {
                    showJobProposal = false
                    Task { await runImport() }
                },
                onCancel: {
                    // User skipped proposals — import without creating jobs from proposals
                    approvedJobs = []
                    showJobProposal = false
                    Task { await runImport() }
                }
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle)
                    .font(.headline)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !isRunning || phase == .runningWorkflows {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var headerTitle: String {
        switch phase {
        case .idle:             return "Import to Library"
        case .proposingJobs:    return "Organizing Jobs…"
        case .importing:        return "Importing…"
        case .runningWorkflows: return "Analyzing Photos…"
        case .done:             return "Import Complete"
        }
    }

    private var headerSubtitle: String {
        switch phase {
        case .idle:
            if allAlreadyImported {
                return "\(allSelected.count) photo\(allSelected.count == 1 ? "" : "s") already in library"
            }
            let n = newPhotos.count
            return "\(n) photo\(n == 1 ? "" : "s") to import"
        case .proposingJobs:
            return "Claude is proposing job buckets for this batch"
        case .importing:
            return "Adding photos to your library"
        case .runningWorkflows:
            return "Running selected workflows"
        case .done(let n):
            return "\(n) photo\(n == 1 ? "" : "s") added to library"
        }
    }

    // MARK: - Idle: Workflow picker

    private var workflowPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WORKFLOWS TO RUN AFTER IMPORT")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)

            ForEach(importableWorkflows, id: \.self) { workflow in
                workflowRow(workflow)
            }
        }
    }

    /// Only non-interactive, metadata-style workflows make sense at import time.
    private var importableWorkflows: [DriveWorkflow] {
        [.orientation, .faces, .scene, .filmStrip]
    }

    private func workflowRow(_ workflow: DriveWorkflow) -> some View {
        Button {
            if selectedWorkflows.contains(workflow) {
                selectedWorkflows.remove(workflow)
            } else {
                selectedWorkflows.insert(workflow)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedWorkflows.contains(workflow)
                    ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(selectedWorkflows.contains(workflow)
                        ? Color.accentColor : .secondary)

                Image(systemName: workflow.systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(workflow.displayLabel)
                        .font(.system(size: 13, weight: .medium))
                    Text(workflow.shortDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedWorkflows.contains(workflow)
                        ? Color.accentColor.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var alreadyImportedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Already in Library")
                    .font(.system(size: 13, weight: .medium))
                Text("All \(allSelected.count) selected photo\(allSelected.count == 1 ? " has" : "s have") been imported. No new triage job will be created.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var photoSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                let n = newPhotos.count
                Text("\(n) photo\(n == 1 ? "" : "s") will be imported")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if alreadyImportedCount > 0 {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(alreadyImportedCount) already imported")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !selectedWorkflows.isEmpty {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(selectedWorkflows.count) workflow\(selectedWorkflows.count == 1 ? "" : "s") queued")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "tray.full")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("A triage job will be created in Jobs for this batch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Progress steps

    private var progressSteps: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Step 1: Import
            stepRow(
                step: 1,
                label: "Import to Library",
                detail: importStepDetail,
                state: importStepState,
                progress: importTotal > 0 ? Double(importCurrent) / Double(importTotal) : 0
            )

            // Step 2: Workflows (only if any selected)
            if !selectedWorkflows.isEmpty {
                Divider()
                stepRow(
                    step: 2,
                    label: workflowStepLabel,
                    detail: workflowStepDetail,
                    state: workflowStepState,
                    progress: drive.workflowProgress
                )
            }
        }
    }

    private var importStepDetail: String {
        switch phase {
        case .importing:
            return "Photo \(importCurrent) of \(importTotal)"
        case .runningWorkflows, .done:
            return "\(importCurrent) photo\(importCurrent == 1 ? "" : "s") added"
        default:
            return ""
        }
    }

    private var importStepState: StepState {
        switch phase {
        case .idle, .proposingJobs: return .pending
        case .importing:            return .running
        case .runningWorkflows,
             .done:                 return .complete
        }
    }

    private var workflowStepLabel: String {
        let names = selectedWorkflows.map(\.displayLabel).sorted().joined(separator: ", ")
        return names.isEmpty ? "Analysis Workflows" : names
    }

    private var workflowStepDetail: String {
        switch phase {
        case .runningWorkflows:
            if drive.workflowTotal > 0 {
                return "Photo \(drive.workflowProcessed) of \(drive.workflowTotal)"
            }
            return "Starting…"
        case .done:
            return "Complete"
        default:
            return "Queued"
        }
    }

    private var workflowStepState: StepState {
        switch phase {
        case .idle, .proposingJobs, .importing: return .pending
        case .runningWorkflows:                 return .running
        case .done:                             return .complete
        }
    }

    // MARK: - Step row

    enum StepState { case pending, running, complete }

    private func stepRow(
        step: Int,
        label: String,
        detail: String,
        state: StepState,
        progress: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // Step indicator
                ZStack {
                    Circle()
                        .fill(stepCircleColor(state))
                        .frame(width: 24, height: 24)
                    switch state {
                    case .pending:
                        Text("\(step)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    case .running:
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white)
                    case .complete:
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 13, weight: state == .pending ? .regular : .medium))
                        .foregroundStyle(state == .pending ? .secondary : .primary)
                        .lineLimit(2)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Spacer()
            }

            if state == .running {
                ProgressView(value: max(0.02, progress))
                    .tint(Color.accentColor)
                    .padding(.leading, 34)
                if state == .running && phase == .runningWorkflows, !drive.workflowCurrentFile.isEmpty {
                    Text(drive.workflowCurrentFile)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.leading, 34)
                }
            }
        }
    }

    private func stepCircleColor(_ state: StepState) -> Color {
        switch state {
        case .pending:  return Color(nsColor: .separatorColor)
        case .running:  return Color.accentColor
        case .complete: return Color.green
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            switch phase {
            case .idle:
                Button("Cancel") { onDismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                if isCheckingLibrary {
                    ProgressView().controlSize(.small)
                } else if allAlreadyImported {
                    Button("Close") { onDismiss() }
                        .buttonStyle(.borderedProminent)
                } else {
                    let n = newPhotos.count
                    Button("Import \(n) Photo\(n == 1 ? "" : "s")") {
                        Task { await startImport() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newPhotos.isEmpty)
                }

            case .proposingJobs:
                Spacer()
                Text("Preparing job proposals…")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .importing:
                Spacer()
                Text("Please wait…")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .runningWorkflows:
                Button("Close") { onDismiss() }
                    .buttonStyle(.bordered)
                    .help("Workflows continue in the background")
                Spacer()
                Text("Analyzing in background…")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .done:
                Spacer()
                Button("Done") { onDismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Import logic

    /// Query the main library DB to find which selected photos already have a matching file_path.
    private func checkAlreadyImported() async {
        guard let database = db else {
            isCheckingLibrary = false
            return
        }
        let photos = allSelected
        let mountPoint = drive.mountPoint
        var found: Set<String> = []
        for photo in photos {
            let path = photo.absoluteURL(mountPoint: mountPoint).path
            let filename = photo.filename
            let fileSize = photo.fileSize
            // Match by exact file path OR by filename+fileSize (handles remounted drives
            // where the mount point path differs from when the photo was originally imported).
            let exists = (try? await database.dbPool.read { db in
                try PhotoAsset
                    .filter(
                        Column("file_path") == path ||
                        (Column("canonical_name") == filename && Column("file_size") == fileSize)
                    )
                    .fetchCount(db) > 0
            }) ?? false
            if exists { found.insert(photo.id) }
        }
        alreadyInLibraryIDs = found
        isCheckingLibrary = false
    }

    /// Step 1: generate job proposals then show the review sheet.
    private func startImport() async {
        let photos = newPhotos
        guard !photos.isEmpty else { return }

        // Generate AI proposals before showing import sheet
        phase = .proposingJobs
        proposedJobs  = (try? await proposalService.proposeJobs(for: photos)) ?? []
        approvedJobs  = proposedJobs

        if proposedJobs.isEmpty {
            // Nothing to review — go straight to import
            await runImport()
        } else {
            // Show review sheet; onConfirm/onCancel call runImport()
            showJobProposal = true
            phase = .idle   // reset so the background sheet doesn't show progress
        }
    }

    /// Step 2: run the actual import after proposals are reviewed (or skipped).
    private func runImport() async {
        guard let vm = libraryViewModel, let database = db else { return }
        let photos = newPhotos
        guard !photos.isEmpty else { return }

        let urls = photos.map { $0.absoluteURL(mountPoint: drive.mountPoint) }
        importTotal   = urls.count
        importCurrent = 0
        phase         = .importing

        // Phase 1: import to library
        await vm.importDigitalPhotos(urls, db: database) { completed in
            importCurrent = completed
        }

        // Stamp importedAt in drive DB and update local tracking set
        let now = ISO8601DateFormatter().string(from: Date())
        if let driveDB = drive.database {
            for var photo in photos {
                photo.importedAt = now
                let snap = photo
                try? await driveDB.dbPool.write { db in try snap.upsert(db) }
            }
        }
        alreadyInLibraryIDs.formUnion(photos.map(\.id))

        // Create TriageJob records from approved proposals (if any)
        let jobRepo = TriageJobRepository(db: database)
        let importedIds = photos.map(\.id)
        if !approvedJobs.isEmpty {
            // Create a parent job for this import batch
            let parentTitle = approvedJobs.count == 1
                ? approvedJobs[0].title
                : "Import — \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none))"
            if let parentJob = try? await jobRepo.createImportJob(title: parentTitle, photoIds: importedIds, activityService: activityService) {
                // Create child jobs for each approved proposal (skip if only one proposal)
                if approvedJobs.count > 1 {
                    for proposal in approvedJobs {
                        let child = TriageJob.newChildJob(
                            parentId: parentJob.id,
                            title: proposal.title,
                            photoCount: proposal.photoCount,
                            source: .split
                        )
                        try? await jobRepo.insert(child)
                    }
                }
            }
        } else {
            // No proposals approved — create a single generic job
            let title = "Import — \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none))"
            _ = try? await jobRepo.createImportJob(title: title, photoIds: importedIds, activityService: activityService)
        }

        // Phase 2: workflows (if any selected)
        if !selectedWorkflows.isEmpty {
            phase = .runningWorkflows
            drive.startWorkflows(photos: photos, workflows: selectedWorkflows)
            // onChange(of: drive.isRunningWorkflows) advances to .done when complete
        } else {
            phase = .done(importCurrent)
        }
    }
}
