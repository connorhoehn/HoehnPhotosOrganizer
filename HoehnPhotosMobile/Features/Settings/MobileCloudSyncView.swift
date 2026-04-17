import SwiftUI
import CloudKit
import HoehnPhotosCore

// MARK: - MobileCloudSyncView

/// CloudKit sync settings — replaces the Multipeer-based MobileSyncView.
///
/// Expects `CloudSyncEngine` (defined in HoehnPhotosCore) to expose:
///   - `@Published var syncState: CloudSyncState`
///   - `@Published var lastSyncDate: Date?`
///   - `@Published var pendingChangeCount: Int`
///   - `@Published var recentSyncEvents: [SyncEvent]`
///   - `func sync() async`
struct MobileCloudSyncView: View {

    @EnvironmentObject private var cloudSync: CloudSyncEngine
    @State private var accountStatus: CKAccountStatus = .couldNotDetermine
    @State private var autoSyncEnabled = true
    @State private var checkingAccount = true

    var body: some View {
        List {
            accountSection

            if accountStatus == .available {
                syncStateSection
                controlsSection
                historySection
            }
        }
        .navigationTitle("Cloud Sync")
        .task {
            await checkAccountStatus()
        }
    }

    // MARK: - Account Section

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if checkingAccount {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Checking iCloud account...")
                        .foregroundStyle(.secondary)
                }
            } else {
                switch accountStatus {
                case .available:
                    Label("iCloud connected", systemImage: "checkmark.icloud.fill")
                        .foregroundStyle(.green)
                case .noAccount:
                    noAccountRow
                case .restricted:
                    Label("iCloud restricted on this device", systemImage: "lock.icloud")
                        .foregroundStyle(.orange)
                case .temporarilyUnavailable:
                    Label("iCloud temporarily unavailable", systemImage: "exclamationmark.icloud")
                        .foregroundStyle(.orange)
                case .couldNotDetermine:
                    Label("Unable to determine iCloud status", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                @unknown default:
                    Label("Unknown iCloud status", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Account")
        }
    }

    private var noAccountRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Not signed in to iCloud", systemImage: "xmark.icloud")
                .foregroundStyle(.red)
            Text("Sign in to iCloud in Settings to enable cloud sync.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.caption)
        }
    }

    // MARK: - Sync State Section

    @ViewBuilder
    private var syncStateSection: some View {
        Section {
            // Current state
            syncStateRow

            // Last sync date
            if let lastSync = cloudSync.lastSyncDate {
                HStack {
                    Text("Last sync")
                    Spacer()
                    Text(lastSync, style: .relative)
                        .foregroundStyle(.secondary)
                }
            }

            // Pending changes
            if cloudSync.pendingChangeCount > 0 {
                HStack {
                    Text("Pending changes")
                    Spacer()
                    Text("\(cloudSync.pendingChangeCount)")
                        .foregroundStyle(.orange)
                        .fontWeight(.medium)
                }
            }
        } header: {
            Text("Status")
        }
    }

    @ViewBuilder
    private var syncStateRow: some View {
        switch cloudSync.syncState {
        case .idle:
            if cloudSync.pendingChangeCount == 0 {
                Label("In sync", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                Label("Changes waiting to sync", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
            }

        case .pushing(let progress):
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Uploading changes...")
                        .font(.subheadline)
                    ProgressView(value: progress)
                        .tint(.blue)
                }
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(.blue)
            }

        case .pulling(let progress):
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Downloading updates...")
                        .font(.subheadline)
                    ProgressView(value: progress)
                        .tint(.blue)
                }
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(.blue)
            }

        case .error(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Sync error", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Controls Section

    @ViewBuilder
    private var controlsSection: some View {
        Section {
            Toggle("Auto-sync", isOn: $autoSyncEnabled)

            Button {
                Task { await cloudSync.sync() }
            } label: {
                HStack {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if case .pushing = cloudSync.syncState {
                        ProgressView().controlSize(.small)
                    } else if case .pulling = cloudSync.syncState {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(isSyncing)
        } header: {
            Text("Controls")
        } footer: {
            if autoSyncEnabled {
                Text("Changes sync automatically in the background.")
            } else {
                Text("Tap Sync Now to manually push and pull changes.")
            }
        }
    }

    // MARK: - History Section

    @ViewBuilder
    private var historySection: some View {
        Section("Recent Sync Events") {
            if cloudSync.recentSyncEvents.isEmpty {
                Text("No sync events yet")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            } else {
                ForEach(Array(cloudSync.recentSyncEvents.prefix(10))) { event in
                    HStack {
                        Image(systemName: event.succeeded ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(event.succeeded ? .green : .red)
                            .font(.caption)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.summary)
                                .font(.caption)
                            Text(event.date, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var isSyncing: Bool {
        switch cloudSync.syncState {
        case .pushing, .pulling: return true
        default: return false
        }
    }

    private func checkAccountStatus() async {
        do {
            let container = CKContainer(identifier: "iCloud.com.connorhoehn.HoehnPhotos")
            accountStatus = try await container.accountStatus()
        } catch {
            accountStatus = .couldNotDetermine
        }
        checkingAccount = false
    }
}
