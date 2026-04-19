import SwiftUI
import HoehnPhotosCore
import GRDB

struct MobileSettingsView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDatabase) private var appDatabase
    @EnvironmentObject private var auth: AuthEnvironment
    @EnvironmentObject private var syncService: PeerSyncService

    // Library preferences
    @AppStorage("gridColumns") private var gridColumns: Int = HPGrid.defaultColumns
    @AppStorage("autoAdvanceAfterCuration") private var autoAdvance: Bool = true

    // Storage stats
    @State private var photoCount: Int = 0
    @State private var proxySizeBytes: Int64 = 0

    // Clear cache
    @State private var showClearCacheAlert = false
    @State private var cacheCleared = false

    // Sign-out
    @State private var showSignOutAlert = false

    // Cloud sync status
    @State private var pendingChangeCount: Int = 0
    @State private var lastPulledAt: Date?
    @State private var isPolling: Bool = false

    private static let lastPulledAtKey = "com.hoehn-photos.aws.lastPulledAt"
    private static let pollInterval: UInt64 = 5 * 1_000_000_000 // 5s

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    var body: some View {
        NavigationStack {
            List {
                accountSection
                cloudSyncStatusSection
                storageSection
                librarySection
                syncSection
                activitySection
                aboutSection
                cacheSection
                #if DEBUG
                debugSection
                #endif
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        HPHaptic.light()
                        dismiss()
                    }
                        .font(HPFont.bodyStrong)
                }
            }
            .task { await loadStorageStats() }
            .task {
                await refreshCloudSyncStatus()
                isPolling = true
                while isPolling && !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: Self.pollInterval)
                    } catch {
                        break
                    }
                    guard isPolling else { break }
                    await refreshCloudSyncStatus()
                }
            }
            .onDisappear {
                isPolling = false
            }
            .alert("Clear Proxy Cache?", isPresented: $showClearCacheAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Clear", role: .destructive) {
                    HPHaptic.heavy()
                    clearProxyCache()
                }
            } message: {
                Text("This will delete all cached proxy images. They will be regenerated as needed during sync.")
            }
            .alert("Sign Out?", isPresented: $showSignOutAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Sign Out", role: .destructive) {
                    HPHaptic.heavy()
                    auth.signOut()
                }
            } message: {
                Text("Signing out will remove your library from this device. You can sign back in to resync.")
            }
        }
    }

    // MARK: - Sections

    private var accountSection: some View {
        Section {
            HStack(spacing: HPSpacing.sm) {
                Label {
                    Text("Signed in as")
                        .font(HPFont.body)
                } icon: {
                    Image(systemName: "person.crop.circle")
                }
                Spacer()
                Text(accountDisplayName)
                    .font(HPFont.metaValue)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)

            Button(role: .destructive) {
                HPHaptic.medium()
                showSignOutAlert = true
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(HPFont.bodyStrong)
            }
            .disabled(!auth.isAuthenticated)
        } header: {
            Text("Account")
        }
    }

    private var cloudSyncStatusSection: some View {
        Section {
            HStack {
                Label {
                    Text("Pending changes")
                        .font(HPFont.body)
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                Spacer()
                Text(pendingChangesText)
                    .font(HPFont.metaValue)
                    .foregroundStyle(pendingChangeCount == 0 ? .secondary : Color.accentColor)
            }
            .accessibilityElement(children: .combine)

            HStack {
                Label {
                    Text("Last synced")
                        .font(HPFont.body)
                } icon: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                Spacer()
                Text(lastSyncedText)
                    .font(HPFont.metaValue)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            HStack {
                Label {
                    Text("Connection")
                        .font(HPFont.body)
                } icon: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                }
                Spacer()
                Text(connectionText)
                    .font(HPFont.metaValue)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .accessibilityElement(children: .combine)

            Button {
                triggerSyncNow()
            } label: {
                Label("Sync Now", systemImage: "arrow.clockwise")
                    .font(HPFont.bodyStrong)
            }
        } header: {
            Text("Cloud Sync")
        }
    }

    private var storageSection: some View {
        Section {
            HStack {
                Label("Photos", systemImage: "photo")
                    .font(HPFont.body)
                Spacer()
                Text("\(photoCount)")
                    .font(HPFont.metaValue)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            HStack {
                Label("Proxy Cache", systemImage: "internaldrive")
                    .font(HPFont.body)
                Spacer()
                Text(formattedSize(proxySizeBytes))
                    .font(HPFont.metaValue)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text("Storage")
        }
    }

    private var librarySection: some View {
        Section {
            Picker(selection: $gridColumns) {
                Text("3 Columns").tag(3)
                Text("4 Columns").tag(4)
            } label: {
                Label("Grid Columns", systemImage: "square.grid.3x3")
                    .font(HPFont.body)
            }
            .sensoryFeedback(.selection, trigger: gridColumns)

            Toggle(isOn: $autoAdvance) {
                Label("Auto-advance after curation", systemImage: "arrow.right")
                    .font(HPFont.body)
            }
            .sensoryFeedback(.selection, trigger: autoAdvance)
        } header: {
            Text("Library")
        }
    }

    private var syncSection: some View {
        Section {
            NavigationLink {
                MobileCloudSyncView()
            } label: {
                Label("Cloud Sync", systemImage: "icloud")
                    .font(HPFont.body)
            }
            .simultaneousGesture(TapGesture().onEnded { HPHaptic.light() })

            NavigationLink {
                MobileSyncView()
            } label: {
                Label("Sync from Mac (Legacy)", systemImage: "desktopcomputer")
                    .font(HPFont.body)
            }
            .simultaneousGesture(TapGesture().onEnded { HPHaptic.light() })
        } header: {
            Text("Sync")
        }
    }

    private var activitySection: some View {
        Section {
            NavigationLink {
                MobileActivityView(isEmbedded: true)
            } label: {
                Label("Activity", systemImage: "clock")
                    .font(HPFont.body)
            }
            .simultaneousGesture(TapGesture().onEnded { HPHaptic.light() })
        } header: {
            Text("History")
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Version")
                    .font(HPFont.body)
                Spacer()
                Text(appVersion)
                    .font(HPFont.metaValue)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            HStack {
                Text("Build")
                    .font(HPFont.body)
                Spacer()
                Text(buildNumber)
                    .font(HPFont.metaValue)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            HStack {
                Spacer()
                Text("Made by Connor Hoehn")
                    .font(HPFont.metaLabel)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .listRowBackground(Color.clear)
        } header: {
            Text("About")
        }
    }

    #if DEBUG
    private var debugSection: some View {
        Section("Debug") {
            NavigationLink {
                DesignSystemGallery()
            } label: {
                Label("Design System Gallery", systemImage: "paintpalette")
            }
        }
    }
    #endif

    private var cacheSection: some View {
        Section {
            Button(role: .destructive) {
                HPHaptic.medium()
                showClearCacheAlert = true
            } label: {
                HStack {
                    Spacer()
                    if cacheCleared {
                        Label("Cache Cleared", systemImage: "checkmark.circle")
                            .font(HPFont.bodyStrong)
                            .foregroundStyle(.green)
                    } else {
                        Label("Clear Proxy Cache", systemImage: "trash")
                            .font(HPFont.bodyStrong)
                    }
                    Spacer()
                }
            }
            .disabled(cacheCleared)
        }
    }

    // MARK: - Helpers

    private func loadStorageStats() async {
        // Photo count from database
        if let db = appDatabase {
            let count = try? await db.dbPool.read { conn in
                try PhotoAsset.fetchCount(conn)
            }
            await MainActor.run { photoCount = count ?? 0 }
        }

        // Proxy directory size
        let fileManager = FileManager.default
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let proxyDir = docs.appendingPathComponent("Proxies")
        let bytes = directorySize(at: proxyDir)
        await MainActor.run { proxySizeBytes = bytes }
    }

    private func clearProxyCache() {
        let fileManager = FileManager.default
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let proxyDir = docs.appendingPathComponent("Proxies")
        try? fileManager.removeItem(at: proxyDir)
        try? fileManager.createDirectory(at: proxyDir, withIntermediateDirectories: true)
        proxySizeBytes = 0
        withAnimation { cacheCleared = true }
    }

    private func directorySize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    // MARK: - Account / Cloud Sync helpers

    private var accountDisplayName: String {
        if let u = auth.username, !u.isEmpty { return u }
        return auth.isAuthenticated ? "Signed in" : "Not signed in"
    }

    private var pendingChangesText: String {
        if pendingChangeCount == 0 {
            return "All synced"
        }
        return "\(pendingChangeCount) change\(pendingChangeCount == 1 ? "" : "s") waiting to sync"
    }

    private var lastSyncedText: String {
        guard let d = lastPulledAt else { return "Never" }
        return Self.relativeFormatter.localizedString(for: d, relativeTo: Date())
    }

    private var connectionText: String {
        switch syncService.state {
        case .idle:
            return "Peer: idle"
        case .searching:
            return "Peer: searching"
        case .connecting(let peerName):
            return "Peer: connecting to \(peerName)"
        case .connected(let peerName):
            return "Peer: connected to \(peerName)"
        case .receiving(_, let fileName):
            return "Peer: receiving \(fileName)"
        case .completed(let count):
            return "Peer: completed \(count) file\(count == 1 ? "" : "s")"
        case .failed(let message):
            return "Peer: failed — \(message)"
        }
    }

    private func refreshCloudSyncStatus() async {
        // Last-pulled timestamp from UserDefaults
        if let raw = UserDefaults.standard.string(forKey: Self.lastPulledAtKey) {
            let parsed = Self.iso8601Formatter.date(from: raw)
                ?? ISO8601DateFormatter().date(from: raw)
            await MainActor.run { self.lastPulledAt = parsed }
        } else {
            await MainActor.run { self.lastPulledAt = nil }
        }

        // Dirty row counts — skip if DB not available yet
        guard let db = appDatabase else {
            await MainActor.run { self.pendingChangeCount = 0 }
            return
        }

        let photoRepo = MobilePhotoRepository(db: db)
        let peopleRepo = MobilePeopleRepository(db: db)

        let photos = (try? await photoRepo.fetchDirtyPhotosForAWS(limit: 200))?.count ?? 0
        let people = (try? await peopleRepo.fetchDirtyPeopleForAWS(limit: 200))?.count ?? 0
        let faces = (try? await peopleRepo.fetchDirtyFacesForAWS(limit: 500))?.count ?? 0

        let total = photos + people + faces
        await MainActor.run { self.pendingChangeCount = total }
    }

    private func triggerSyncNow() {
        HPHaptic.light()
        NotificationCenter.default.post(
            name: .cloudSyncCurationChanged,
            object: nil
        )
        // Optimistically refresh status shortly after kicking the drain.
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await refreshCloudSyncStatus()
        }
    }
}
