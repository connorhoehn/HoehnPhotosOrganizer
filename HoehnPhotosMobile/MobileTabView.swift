import SwiftUI
import HoehnPhotosCore

// MARK: - MobileTabView

struct MobileTabView: View {

    @EnvironmentObject private var syncService: PeerSyncService
    @EnvironmentObject private var cloudSync: CloudSyncEngine
    @Environment(\.appDatabase) private var appDatabase
    @State private var selectedTab: MobileTab = .library
    @State private var openJobCount: Int = 0
    @State private var showSettings: Bool = false

    /// Show the CloudKit bar when cloud sync is active (non-idle or has pending changes);
    /// fall back to the legacy Multipeer bar when peer sync is in progress.
    private var useCloudBar: Bool {
        switch cloudSync.syncState {
        case .pushing, .pulling, .error:
            return true
        case .idle:
            return cloudSync.pendingChangeCount > 0
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Cloud sync status bar (preferred)
            if useCloudBar {
                cloudSyncStatusBar
            } else {
                // Legacy Multipeer bar — shown when peer sync is actively doing something
                syncStatusBar
            }

            TabView(selection: $selectedTab) {
                MobileLibraryView(showSettings: $showSettings)
                    .tabItem {
                        Label("Library", systemImage: "photo.on.rectangle")
                    }
                    .tag(MobileTab.library)

                MobileJobsView()
                    .tabItem {
                        Label("Jobs", systemImage: "tray.full")
                    }
                    .tag(MobileTab.jobs)
                    .badge(openJobCount > 0 ? openJobCount : 0)

                MobileSearchView()
                    .tabItem {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .tag(MobileTab.search)

                MobilePeopleView()
                    .tabItem {
                        Label("People", systemImage: "person.2")
                    }
                    .tag(MobileTab.people)

                MobileCreativeView()
                    .tabItem {
                        Label("Creative", systemImage: "paintpalette")
                    }
                    .tag(MobileTab.creative)
            }
            .sheet(isPresented: $showSettings) {
                MobileSettingsView()
            }
            .task {
                await loadOpenJobCount()
            }
            .onChange(of: selectedTab) { _ in
                Task { await loadOpenJobCount() }
            }
        }
    }

    private func loadOpenJobCount() async {
        guard let db = appDatabase else { return }
        let jobs = (try? await MobileJobRepository(db: db).fetchAll()) ?? []
        openJobCount = jobs.filter { $0.status == .open }.count
    }

    @ViewBuilder
    private var syncStatusBar: some View {
        switch syncService.state {
        case .receiving(let progress, let fileName):
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Syncing: \(fileName)")
                        .font(.caption2)
                        .lineLimit(1)
                    ProgressView(value: progress)
                        .tint(.blue)
                }
                Text("\(Int(progress * 100))%")
                    .font(.caption2.monospaced().bold())
                    .foregroundStyle(.blue)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemBackground))

        case .connected(let name):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Connected to \(name)")
                    .font(.caption2)
                Spacer()
                if syncService.pendingDeltas.isEmpty {
                    Text("In sync")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(syncService.pendingDeltas.count) pending")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemBackground))

        case .completed(let count):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(count) files synced")
                    .font(.caption2.bold())
                Spacer()
                Button("Dismiss") {
                    syncService.stop()
                }
                .font(.caption2)
                .frame(minHeight: 44)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.green.opacity(0.2))

        case .searching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text("Looking for Mac...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemBackground))

        case .idle:
            if !syncService.pendingDeltas.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.circle")
                        .foregroundStyle(.orange)
                    Text("\(syncService.pendingDeltas.count) changes pending upload")
                        .font(.caption2)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.2))
            } else {
                EmptyView()
            }

        default:
            EmptyView()
        }
    }

    // MARK: - CloudKit Sync Status Bar

    @ViewBuilder
    private var cloudSyncStatusBar: some View {
        switch cloudSync.syncState {
        case .pushing(let progress):
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Uploading changes...")
                        .font(.caption2)
                        .lineLimit(1)
                    ProgressView(value: progress)
                        .tint(.blue)
                }
                Text("\(Int(progress * 100))%")
                    .font(.caption2.monospaced().bold())
                    .foregroundStyle(.blue)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemBackground))

        case .pulling(let progress):
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Downloading updates...")
                        .font(.caption2)
                        .lineLimit(1)
                    ProgressView(value: progress)
                        .tint(.blue)
                }
                Text("\(Int(progress * 100))%")
                    .font(.caption2.monospaced().bold())
                    .foregroundStyle(.blue)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemBackground))

        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.white)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Button("Retry") {
                    Task { await cloudSync.sync() }
                }
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .frame(minHeight: 44)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.red)

        case .idle:
            if cloudSync.pendingChangeCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "icloud.and.arrow.up")
                        .foregroundStyle(.orange)
                    Text("\(cloudSync.pendingChangeCount) changes pending upload")
                        .font(.caption2)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.2))
            } else {
                EmptyView()
            }
        }
    }
}

enum MobileTab: String {
    case library, jobs, search, people, creative
}
