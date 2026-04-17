import SwiftUI
import MultipeerConnectivity
import HoehnPhotosCore

// MARK: - MobileSyncView

/// iPhone sync screen — discovers nearby Mac, receives catalog + proxies.
struct MobileSyncView: View {

    @EnvironmentObject private var syncService: PeerSyncService
    @Environment(\.appDatabase) private var appDatabase
    @State private var dbReloaded = false
    @State private var isLoading = false
    @State private var showCopiedBadge = false

    var body: some View {
        List {
            Section {
                statusRow
            }

            if case .searching = syncService.state {
                Section("Nearby Macs") {
                    if syncService.discoveredPeers.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking for your Mac...")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(syncService.discoveredPeers, id: \.displayName) { peer in
                            Button {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                syncService.connect(to: peer)
                            } label: {
                                HStack {
                                    Image(systemName: "desktopcomputer")
                                    VStack(alignment: .leading) {
                                        Text(peer.displayName)
                                        if let pin = syncService.peerPINs[peer.displayName] {
                                            pinCopyButton(pin: pin)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "lock.shield")
                                        .foregroundStyle(.green)
                                        .accessibilityLabel("Encrypted connection")
                                }
                            }
                            .buttonStyle(.bordered)
                            .accessibilityHint("Double tap to start syncing with this Mac")
                        }
                    }
                }
            }

            if case .connected(let name) = syncService.state {
                Section {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Connected to \(name)")
                    }
                    Text("Waiting for Mac to send catalog...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if case .receiving(let progress, let fileName) = syncService.state {
                Section("Receiving") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(fileName)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        ProgressView(value: progress)
                            .tint(.accentColor)
                        Text("\(Int(progress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if case .completed(let count) = syncService.state {
                Section {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.title2)
                        VStack(alignment: .leading) {
                            Text("Sync Complete")
                                .font(.headline)
                            Text("\(count) files received")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        isLoading = true
                        if let db = appDatabase {
                            try? db.reload()
                            dbReloaded = true
                        }
                        isLoading = false
                    } label: {
                        HStack(spacing: 8) {
                            Text("Load Synced Library")
                            if isLoading {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading)

                    if dbReloaded {
                        Label("Library loaded — go to Library tab to browse.", systemImage: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }

            if case .failed(let error) = syncService.state {
                Section {
                    ErrorBanner(message: error) {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        syncService.stop()
                        syncService.start()
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            Section {
                if case .idle = syncService.state {
                    Button("Start Searching") {
                        syncService.start()
                    }
                    .foregroundStyle(Color.accentColor)
                } else if case .completed = syncService.state {
                    Button("Search Again") {
                        syncService.stop()
                        syncService.start()
                    }
                } else {
                    Button("Stop") {
                        syncService.stop()
                    }
                    .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Sync from Mac")
        .onAppear {
            if case .idle = syncService.state {
                syncService.start()
            }
        }
        // Don't stop on disappear — let sync continue in background
        // Only stop if user explicitly taps Stop
    }

    // MARK: - PIN copy button

    @ViewBuilder
    private func pinCopyButton(pin: String) -> some View {
        ZStack(alignment: .trailing) {
            Button {
                UIPasteboard.general.string = pin
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                showCopiedBadge = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    showCopiedBadge = false
                }
            } label: {
                HStack(spacing: 4) {
                    Text("PIN: \(pin)")
                        .font(.caption.monospaced().bold())
                        .foregroundStyle(Color.accentColor)
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy PIN \(pin) to clipboard")

            if showCopiedBadge {
                Text("Copied!")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green, in: Capsule())
                    .transition(.opacity.combined(with: .scale))
                    .offset(x: 60)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showCopiedBadge)
    }

    // MARK: - Status row

    @ViewBuilder
    private var statusRow: some View {
        switch syncService.state {
        case .idle:
            Label("Not connected", systemImage: "wifi.slash")
                .foregroundStyle(.secondary)
        case .searching:
            Label("Searching nearby...", systemImage: "wifi")
                .foregroundStyle(.orange)
        case .connecting(let name):
            Label("Connecting to \(name)...", systemImage: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.orange)
        case .connected(let name):
            Label("Connected to \(name)", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .receiving(_, let file):
            Label("Receiving \(file)", systemImage: "arrow.down")
                .foregroundStyle(.blue)
        case .completed(let count):
            Label("\(count) files synced", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let err):
            Label(err, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }
}
