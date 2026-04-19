import SwiftUI
import HoehnPhotosCore
import GRDB

struct MobileSettingsView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDatabase) private var appDatabase

    // Library preferences
    @AppStorage("gridColumns") private var gridColumns: Int = HPGrid.defaultColumns
    @AppStorage("autoAdvanceAfterCuration") private var autoAdvance: Bool = true

    // Storage stats
    @State private var photoCount: Int = 0
    @State private var proxySizeBytes: Int64 = 0

    // Clear cache
    @State private var showClearCacheAlert = false
    @State private var cacheCleared = false

    var body: some View {
        NavigationStack {
            List {
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
                    Button("Done") { dismiss() }
                        .font(HPFont.bodyStrong)
                }
            }
            .task { await loadStorageStats() }
            .alert("Clear Proxy Cache?", isPresented: $showClearCacheAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Clear", role: .destructive) {
                    clearProxyCache()
                }
            } message: {
                Text("This will delete all cached proxy images. They will be regenerated as needed during sync.")
            }
        }
    }

    // MARK: - Sections

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
            HStack {
                Label("Proxy Cache", systemImage: "internaldrive")
                    .font(HPFont.body)
                Spacer()
                Text(formattedSize(proxySizeBytes))
                    .font(HPFont.metaValue)
                    .foregroundStyle(.secondary)
            }
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

            Toggle(isOn: $autoAdvance) {
                Label("Auto-advance after curation", systemImage: "arrow.right")
                    .font(HPFont.body)
            }
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

            NavigationLink {
                MobileSyncView()
            } label: {
                Label("Sync from Mac (Legacy)", systemImage: "desktopcomputer")
                    .font(HPFont.body)
            }
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
            HStack {
                Text("Build")
                    .font(HPFont.body)
                Spacer()
                Text(buildNumber)
                    .font(HPFont.metaValue)
                    .foregroundStyle(.secondary)
            }
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
}
