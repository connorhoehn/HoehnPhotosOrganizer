import Foundation
import AppKit
import Combine
import GRDB

extension Notification.Name {
    static let didClearLibrary = Notification.Name("didClearLibrary")
}

// MARK: - DrivesOverviewViewModel

/// Top-level view model for the Drives section.
/// Detects mounted removable volumes via NSWorkspace notifications and manages
/// one `MountedDriveState` per detected volume.
@MainActor
final class DrivesOverviewViewModel: ObservableObject {

    @Published var mountedDrives: [MountedDriveState] = []

    private var observerTokens: [Any] = []

    init() {
        subscribeToMountNotifications()
        subscribeToClearLibrary()
        refreshMountedVolumes()
    }

    deinit {
        let wsNC = NSWorkspace.shared.notificationCenter
        let defaultNC = NotificationCenter.default
        observerTokens.forEach {
            wsNC.removeObserver($0)
            defaultNC.removeObserver($0)
        }
    }

    // MARK: - Volume detection

    private func subscribeToClearLibrary() {
        observerTokens.append(
            NotificationCenter.default.addObserver(
                forName: .didClearLibrary, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for drive in self.mountedDrives {
                        drive.forgetIndex()
                    }
                }
            }
        )
    }

    private func subscribeToMountNotifications() {
        let nc = NSWorkspace.shared.notificationCenter
        observerTokens.append(
            nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil,
                           queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshMountedVolumes() }
            }
        )
        observerTokens.append(
            nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil,
                           queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshMountedVolumes() }
            }
        )
    }

    func refreshMountedVolumes() {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeUUIDStringKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeIsRemovableKey, .volumeIsInternalKey,
            .volumeIsEjectableKey, .volumeIsReadOnlyKey,
        ]
        guard let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else { return }

        var newStates: [MountedDriveState] = []
        for volURL in volumes {
            guard let res = try? volURL.resourceValues(forKeys: Set(keys)) else { continue }

            // Skip internal non-removable volumes (boot drive etc.)
            let isInternal  = res.volumeIsInternal  ?? true
            let isRemovable = res.volumeIsRemovable ?? false
            let isEjectable = res.volumeIsEjectable ?? false
            guard !isInternal || isRemovable || isEjectable else { continue }

            guard let name = res.volumeName, !name.isEmpty else { continue }

            // Skip installer/DMG/recovery volumes
            let total = Int64(res.volumeTotalCapacity ?? 0)
            let isReadOnly = res.volumeIsReadOnly ?? false
            guard !Self.isInstallerVolume(name: name, path: volURL.path),
                  total > 0,           // DMG installers report 0 total capacity
                  !isReadOnly          // Read-only disc images aren't photo drives
            else { continue }

            let uuid = res.volumeUUIDString ?? fallbackID(for: volURL)
            let free = Int64(res.volumeAvailableCapacity ?? 0)

            // Reuse existing state if same UUID (avoids resetting progress/stream)
            if let existing = mountedDrives.first(where: { $0.volumeUUID == uuid }) {
                newStates.append(existing)
            } else {
                let db = try? DrivePreviewDatabase(volumeUUID: uuid)
                let state = MountedDriveState(
                    volumeUUID: uuid, label: name,
                    mountPoint: volURL, totalBytes: total,
                    freeBytes: free, database: db
                )
                newStates.append(state)
            }
        }
        mountedDrives = newStates
    }

    private func fallbackID(for url: URL) -> String {
        String(abs(url.path.hashValue), radix: 16)
    }

    private static func isInstallerVolume(name: String, path: String) -> Bool {
        let lower = name.lowercased()
        let keywords = ["installer", "install", "recovery", "setup", "update",
                        "firmware", "driver", "uninstall"]
        for kw in keywords where lower.contains(kw) { return true }
        if lower.hasPrefix("preboot") || lower.hasPrefix("vm") || lower == "data" { return true }
        return false
    }
}

// MARK: - MountedDriveState

/// Observable state for a single mounted drive — photo list, indexing progress, etc.
@MainActor
final class MountedDriveState: ObservableObject, Identifiable {

    let volumeUUID:  String
    let label:       String
    let mountPoint:  URL
    let totalBytes:  Int64
    let freeBytes:   Int64
    var database:    DrivePreviewDatabase?

    @Published var photos:         [DrivePhotoRecord] = []
    @Published var hasThumbnails:  Bool = false      // true once any photo has a thumbnail_path
    @Published var isIndexing:     Bool = false
    @Published var indexProgress:  Double = 0        // 0…1
    @Published var indexedCount:   Int = 0
    @Published var totalFileCount: Int = 0
    @Published var indexingError:  String? = nil
    @Published var hasBeenIndexed: Bool = false      // true once index.db has any rows
    @Published var duplicateCount: Int = 0           // photos whose duplicate_group_id is non-nil

    // Detailed indexing state (shown in inspector panel)
    @Published var currentStage: IndexingStage = .idle
    @Published var currentFilename: String = ""
    @Published var folderCount: Int = 0
    @Published var rawCount: Int = 0
    @Published var jpegCount: Int = 0
    @Published var otherCount: Int = 0
    @Published var skippedCount: Int = 0
    @Published var logLines: [String] = []

    // Thumbnail-phase counters
    @Published var thumbnailsDone:  Int = 0
    @Published var thumbnailsTotal: Int = 0
    @Published var isGeneratingThumbnails: Bool = false

    // Workflow runner state
    @Published var isRunningWorkflows:    Bool   = false
    @Published var workflowProgress:      Double = 0
    @Published var workflowCurrentFile:   String = ""
    @Published var workflowProcessed:     Int    = 0
    @Published var workflowTotal:         Int    = 0

    var id: String { volumeUUID }
    var usedBytes:  Int64  { totalBytes - freeBytes }
    var capacityRatio: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }

    private let service              = DrivePreviewService()
    private let workflowRunner       = DriveWorkflowRunner()
    private var cancelToken          = DriveScanCancellationToken()
    private var thumbCancelToken     = DriveScanCancellationToken()
    private var workflowCancelToken  = DriveScanCancellationToken()
    private var streamTask:          Task<Void, Never>?
    private var thumbTask:           Task<Void, Never>?
    private var securityScopedURL:   URL? = nil   // restored from bookmark or granted via panel

    init(volumeUUID: String, label: String, mountPoint: URL,
         totalBytes: Int64, freeBytes: Int64, database: DrivePreviewDatabase?) {
        self.volumeUUID = volumeUUID
        self.label      = label
        self.mountPoint = mountPoint
        self.totalBytes = totalBytes
        self.freeBytes  = freeBytes
        self.database   = database
        startPhotoStream()
        Task { await restoreBookmark() }
        Task { await reloadPhotos() }   // populate immediately; don't wait for stream
    }

    // MARK: - Sandbox access

    private func restoreBookmark() async {
        guard let db = database,
              let data = await db.loadBookmarkData() else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withSecurityScope,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return }
        if url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        }
    }

    /// Presents NSOpenPanel to ask the user to confirm the drive root, then saves a
    /// security-scoped bookmark so future runs don't need to ask again.
    /// Returns the granted URL, or nil if the user cancelled.
    private func requestAccessViaPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title         = "Grant Access to \"\(label)\""
        panel.message       = "Look in the Locations sidebar and select \"\(label)\" — don't navigate into any subfolder, just select the drive root and click Grant Access."
        panel.prompt        = "Grant Access"
        panel.canChooseFiles             = false
        panel.canChooseDirectories       = true
        panel.canCreateDirectories       = false
        panel.allowsMultipleSelection    = false
        panel.showsHiddenFiles           = false
        panel.directoryURL               = mountPoint
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        // Validate: the selected path must be the drive root (or a subdirectory of it)
        let selectedPath  = url.resolvingSymlinksInPath().path
        let expectedPath  = mountPoint.resolvingSymlinksInPath().path
        if !selectedPath.hasPrefix(expectedPath) {
            let alert = NSAlert()
            alert.messageText     = "Wrong Folder Selected"
            alert.informativeText = "You selected \(url.lastPathComponent). Please select \"\(label)\" from the Locations sidebar — it should be the drive root at \(mountPoint.path)."
            alert.alertStyle      = .warning
            alert.addButton(withTitle: "Try Again")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            return requestAccessViaPanel()   // retry
        }

        guard url.startAccessingSecurityScopedResource() else { return nil }
        if let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            Task { try? await database?.saveBookmarkData(data) }
        }
        securityScopedURL = url
        return url
    }

    /// Call this to clear a stale or incorrect bookmark and force re-prompting on next index.
    func resetAccessBookmark() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        Task { try? await database?.setMeta(key: "security_bookmark", value: "") }
    }

    // MARK: - Live photo stream

    private func startPhotoStream() {
        streamTask?.cancel()
        guard let db = database else { return }
        streamTask = Task { [weak self] in
            do {
                for try await batch in db.allPhotosStream() {
                    guard let self else { return }
                    self.photos = batch
                    self.hasBeenIndexed = !batch.isEmpty
                    self.hasThumbnails  = batch.contains { $0.thumbnailPath != nil }
                    self.duplicateCount = batch.filter { $0.duplicateGroupId != nil }.count
                }
            } catch {
                // Observation ended (e.g. db closed). Non-fatal in normal operation.
            }
        }
    }

    // MARK: - Indexing

    func startIndexing() {
        guard !isIndexing, let db = database else { return }

        // Ensure we have sandbox access to the volume's file system
        let accessURL: URL
        if let existing = securityScopedURL {
            accessURL = existing
        } else if let granted = requestAccessViaPanel() {
            accessURL = granted
        } else {
            indexingError = "Access to drive was denied."
            return
        }

        cancelToken = DriveScanCancellationToken()
        isIndexing    = true
        indexProgress = 0
        indexingError = nil

        let token = cancelToken
        let mp    = accessURL          // use the security-scoped URL, not the raw mountPoint
        let uuid  = volumeUUID

        // Run the scan, then auto-start thumbnail generation if it completed.
        // All awaits happen BEFORE the flag changes so that isIndexing→isGeneratingThumbnails
        // transition is atomic from SwiftUI's perspective (no banner flash).
        Task {
            await service.indexDrive(
                mountPoint: mp, volumeUUID: uuid,
                database: db, cancelToken: token,
                usedBytes: usedBytes
            )
            // Gather async state before touching any @Published flags
            await self.reloadPhotos()
            let completedStage = await service.currentStage

            // Now flip flags synchronously — no await between them
            self.isIndexing = false
            if completedStage == .complete {
                self.startThumbnailGeneration()
            }
        }

        // Poll progress on the actor every 300 ms
        Task {
            while isIndexing {
                async let p  = service.scanProgress
                async let sc = service.scannedCount
                async let tc = service.totalCount
                async let st = service.currentStage
                async let fn = service.currentFilename
                async let fc = service.folderCount
                async let rc = service.rawCount
                async let jc = service.jpegCount
                async let oc = service.otherCount
                async let sk = service.skippedCount
                async let ll = service.logLines
                async let td = service.thumbnailsDone
                async let tt = service.thumbnailsTotal
                (indexProgress, indexedCount, totalFileCount,
                 currentStage, currentFilename,
                 folderCount, rawCount, jpegCount, otherCount,
                 skippedCount, logLines, thumbnailsDone, thumbnailsTotal) =
                    await (p, sc, tc, st, fn, fc, rc, jc, oc, sk, ll, td, tt)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            // Final snapshot after scan completes — skip if thumbnail generation
            // already started (its own poll now owns these properties).
            guard !isGeneratingThumbnails else { return }
            indexProgress     = 1.0
            indexedCount      = await service.scannedCount
            totalFileCount    = await service.totalCount
            currentStage      = await service.currentStage
            currentFilename   = ""
            folderCount       = await service.folderCount
            rawCount          = await service.rawCount
            jpegCount         = await service.jpegCount
            otherCount        = await service.otherCount
            skippedCount      = await service.skippedCount
            logLines          = await service.logLines
            thumbnailsDone    = await service.thumbnailsDone
            thumbnailsTotal   = await service.thumbnailsTotal
            if indexedCount > 0 { hasBeenIndexed = true }
        }
    }

    /// Direct one-shot DB read — used after indexing completes and on init to bypass
    /// ValueObservation latency with large record counts.
    private func reloadPhotos() async {
        guard let db = database else { return }
        guard let batch = try? await db.dbPool.read({ conn in
            try DrivePhotoRecord
                .order(Column("capture_date").desc, Column("modified_at").desc)
                .fetchAll(conn)
        }) else { return }
        photos         = batch
        hasBeenIndexed = !batch.isEmpty
        hasThumbnails  = batch.contains { $0.thumbnailPath != nil }
        duplicateCount = batch.filter { $0.duplicateGroupId != nil }.count
    }

    func stopIndexing() {
        cancelToken.cancel()
        isIndexing = false
    }

    // MARK: - Thumbnail generation (on-demand)

    /// Deletes all cached thumbnail files, clears `thumbnail_path` in the DB,
    /// then immediately starts a fresh generation pass.
    func clearAndRegenerateThumbnails() {
        guard !isIndexing, !isGeneratingThumbnails, let db = database else { return }
        let thumbsDir = DrivePreviewDatabase.thumbsURL(for: volumeUUID)
        Task {
            try? await db.dbPool.write { conn in
                try conn.execute(sql: "UPDATE drive_photos SET thumbnail_path = NULL")
            }
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: thumbsDir, includingPropertiesForKeys: nil
            ) {
                for file in contents { try? FileManager.default.removeItem(at: file) }
            }
            await self.reloadPhotos()
            self.startThumbnailGeneration()
        }
    }

    func startThumbnailGeneration() {
        guard !isIndexing, !isGeneratingThumbnails, let db = database else { return }

        let accessURL: URL
        if let existing = securityScopedURL {
            accessURL = existing
        } else if let granted = requestAccessViaPanel() {
            accessURL = granted
        } else {
            return
        }

        thumbCancelToken = DriveScanCancellationToken()
        isGeneratingThumbnails = true
        thumbnailsDone  = 0
        thumbnailsTotal = 0

        let token = thumbCancelToken
        let mp    = accessURL
        let uuid  = volumeUUID

        thumbTask = Task {
            await service.startThumbnailGeneration(
                mountPoint: mp, volumeUUID: uuid,
                database: db, cancelToken: token
            )
            self.isGeneratingThumbnails = false
            // Capture final state
            self.currentStage    = await service.currentStage
            self.thumbnailsDone  = await service.thumbnailsDone
            self.thumbnailsTotal = await service.thumbnailsTotal
            self.logLines        = await service.logLines
            self.currentFilename = ""
            // Direct read — bypass ValueObservation latency so thumbnailPath
            // updates appear in the grid immediately.
            await self.reloadPhotos()
        }

        Task {
            while isGeneratingThumbnails {
                async let p  = service.scanProgress
                async let st = service.currentStage
                async let fn = service.currentFilename
                async let td = service.thumbnailsDone
                async let tt = service.thumbnailsTotal
                async let ll = service.logLines
                (indexProgress, currentStage, currentFilename,
                 thumbnailsDone, thumbnailsTotal, logLines) =
                    await (p, st, fn, td, tt, ll)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    func stopThumbnailGeneration() {
        thumbCancelToken.cancel()
        isGeneratingThumbnails = false
    }

    // MARK: - Workflow runner

    func startWorkflows(photos: [DrivePhotoRecord], workflows: Set<DriveWorkflow>) {
        guard !isRunningWorkflows, let db = database else { return }
        workflowCancelToken = DriveScanCancellationToken()
        isRunningWorkflows = true
        workflowProgress   = 0
        workflowProcessed  = 0
        workflowTotal      = 0

        let token = workflowCancelToken
        let mp    = securityScopedURL ?? mountPoint

        Task {
            await workflowRunner.run(
                photos: photos, workflows: workflows,
                mountPoint: mp, database: db, cancelToken: token
            )
            self.isRunningWorkflows = false
            self.workflowProgress   = 1.0
            self.workflowCurrentFile = ""
        }

        Task {
            while isRunningWorkflows {
                async let p  = workflowRunner.progress
                async let fn = workflowRunner.currentFilename
                async let pc = workflowRunner.processedCount
                async let tc = workflowRunner.totalCount
                (workflowProgress, workflowCurrentFile, workflowProcessed, workflowTotal) =
                    await (p, fn, pc, tc)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    func stopWorkflows() {
        workflowCancelToken.cancel()
        isRunningWorkflows = false
    }

    func forgetIndex() {
        // Cancel all in-flight operations
        stopIndexing()
        stopThumbnailGeneration()
        stopWorkflows()
        streamTask?.cancel()

        // Reset UI state immediately
        photos = []
        hasBeenIndexed = false; hasThumbnails = false
        duplicateCount = 0; indexProgress = 0; indexedCount = 0
        currentStage = .idle; currentFilename = ""
        folderCount = 0; rawCount = 0; jpegCount = 0; otherCount = 0; skippedCount = 0
        thumbnailsDone = 0; thumbnailsTotal = 0; logLines = []
        isRunningWorkflows = false; workflowProgress = 0
        workflowCurrentFile = ""; workflowProcessed = 0; workflowTotal = 0

        // Defer directory deletion until the thumb task has fully drained.
        // Deleting the DB file while a DatabasePool is still open causes SQLite
        // WAL corruption ("vnode unlinked while in use").
        let uuidToDelete = volumeUUID   // volumeUUID is a let — always available even if database is nil
        database = nil          // release our reference; task's local `db` keeps pool alive briefly
        let drain = thumbTask   // capture so we can await it
        thumbTask = nil

        Task {
            await drain?.value  // wait for last DB write to finish
            let uuid = uuidToDelete
            let dir = DrivePreviewDatabase.indexURL(for: uuid).deletingLastPathComponent()
            try? FileManager.default.removeItem(at: dir)
            // Recreate the DB so the next index run has a clean store with observations wired up
            if let db = try? DrivePreviewDatabase(volumeUUID: uuid) {
                self.database = db
                self.startPhotoStream()
            }
        }
    }
}
