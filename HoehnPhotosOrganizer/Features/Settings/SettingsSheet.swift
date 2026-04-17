import SwiftUI
import UniformTypeIdentifiers

// MARK: - Section enum

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case appearance = "Appearance"
    case anthropicAPI = "Anthropic API"
    case apiUsage = "API Usage"
    case machineLearning = "Machine Learning"
    case mobileSync = "Mobile Sync"
    case cloudSync = "Cloud Sync"
    case libraryTools = "Library Tools"
    case exportBackup = "Export & Backup"
    case developer = "Developer"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .appearance: "paintbrush"
        case .anthropicAPI: "key"
        case .apiUsage: "chart.bar.fill"
        case .machineLearning: "brain"
        case .mobileSync: "iphone"
        case .cloudSync: "icloud"
        case .libraryTools: "folder.badge.gearshape"
        case .exportBackup: "arrow.up.doc"
        case .developer: "wrench.and.screwdriver"
        }
    }
}

// MARK: - SettingsSheet

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.eventOutboxProcessor) private var outboxProcessor: EventOutboxProcessor?
    @Binding var gridColumns: Double
    var db: AppDatabase?
    var photoRepo: PhotoRepository?
    @ObservedObject var peerSync: MacPeerSyncAdvertiser
    var onClearLibrary: (() -> Void)? = nil

    @State private var selectedSection: SettingsSection = .general

    @State private var anthropicKey: String = ""
    @State private var showClearConfirmation = false
    @State private var anthropicKeyMasked: Bool = true
    @State private var anthropicStatus: AnthropicKeyStatus = .unknown
    @State private var anthropicTestMessage: String = ""
    @State private var isTesting: Bool = false
    @State private var showDuplicateReview = false
    @State private var showStorageReport = false

    // Export & Backup state
    @State private var isExporting = false
    @State private var exportSuccess = false
    @State private var exportErrorMessage: String? = nil

    // Face re-index state
    @State private var isFaceIndexing = false
    @State private var faceIndexMessage: String = ""
    @AppStorage("face.distanceThreshold") private var faceThreshold: Double = 0.65
    @AppStorage("appearance.mode") private var appearanceMode: String = "system"
    @AppStorage("appearance.fontSize") private var fontSize: Double = 13

    private let authManager = AnthropicAuthManager()

    private var visibleSections: [SettingsSection] {
        SettingsSection.allCases.filter { section in
            if section == .developer { return onClearLibrary != nil }
            return true
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // MARK: Sidebar
            VStack(spacing: 0) {
                List(visibleSections, selection: $selectedSection) { section in
                    Label(section.rawValue, systemImage: section.icon)
                        .tag(section)
                }
                .listStyle(.sidebar)
                .frame(width: 180)
            }

            Divider()

            // MARK: Content
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(selectedSection.rawValue)
                        .font(.largeTitle.bold())
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(24)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        contentView(for: selectedSection)
                    }
                    .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 720, minHeight: 520)
        .confirmationDialog("Clear Library?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button("Clear Library", role: .destructive) {
                onClearLibrary?()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all photos, drives, metadata, and thread entries from the catalog. Original files on disk are not affected.")
        }
        .sheet(isPresented: $showDuplicateReview) {
            if let db, let photoRepo {
                NavigationView {
                    DuplicateGroupView(db: db, photoRepo: photoRepo)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { showDuplicateReview = false }
                            }
                        }
                }
                .frame(minWidth: 700, minHeight: 500)
            }
        }
        .sheet(isPresented: $showStorageReport) {
            if let db {
                NavigationView {
                    StorageReportView(db: db)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { showStorageReport = false }
                            }
                        }
                }
                .frame(minWidth: 700, minHeight: 550)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await loadKeyStatus() }
        .alert("Export Complete", isPresented: $exportSuccess) {
            Button("OK") {}
        } message: {
            Text("Catalog exported successfully.")
        }
        .alert("Export Failed", isPresented: .constant(exportErrorMessage != nil)) {
            Button("OK") { exportErrorMessage = nil }
        } message: {
            Text(exportErrorMessage ?? "")
        }
    }

    // MARK: - Section router

    @ViewBuilder
    private func contentView(for section: SettingsSection) -> some View {
        switch section {
        case .general:          generalContent
        case .appearance:       appearanceContent
        case .mobileSync:       mobileSyncContent
        case .anthropicAPI:     anthropicContent
        case .apiUsage:         APIUsageView(db: db)
        case .machineLearning:  mlContent
        case .cloudSync:        cloudSyncContent
        case .libraryTools:     libraryToolsContent
        case .exportBackup:     exportBackupContent
        case .developer:        developerContent
        }
    }

    // MARK: - General

    private var generalContent: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return VStack(alignment: .leading, spacing: 12) {
            SettingsRow(title: "Version", value: "\(version) (\(build))")
            SettingsRow(title: "Proxy longest edge", value: "1600 px")
            SettingsRow(title: "Storage policy", value: "Originals remain on external drives")

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Photo grid columns")
                        .font(.headline)
                    Text("Number of columns in the photo grid")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 10) {
                    Text("\(Int(gridColumns.rounded())) col")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Slider(value: $gridColumns, in: 2...8, step: 1)
                        .frame(width: 130)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }

    // MARK: - Appearance

    private var appearanceContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Dark / Light / System
            VStack(alignment: .leading, spacing: 8) {
                Text("Mode")
                    .font(.headline)
                Text("Control whether the app uses light mode, dark mode, or follows the system setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    appearanceModeButton(mode: "system", label: "System", icon: "circle.lefthalf.filled")
                    appearanceModeButton(mode: "light", label: "Light", icon: "sun.max")
                    appearanceModeButton(mode: "dark", label: "Dark", icon: "moon.fill")
                }
                .padding(.top, 4)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            // Font size
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Interface Font Size")
                        .font(.headline)
                    Text("Adjust the base font size across the app. Default is 13 pt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 10) {
                    Text("\(Int(fontSize.rounded())) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Slider(value: $fontSize, in: 11...18, step: 1)
                        .frame(width: 160)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            // Preview
            VStack(alignment: .leading, spacing: 8) {
                Text("Preview")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("The quick brown fox jumps over the lazy dog.")
                        .font(.system(size: fontSize))
                    Text("Secondary text at the current size.")
                        .font(.system(size: fontSize - 2))
                        .foregroundStyle(.secondary)
                    Text("Caption text.")
                        .font(.system(size: fontSize - 4))
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }

    private func appearanceModeButton(mode: String, label: String, icon: String) -> some View {
        let isSelected = appearanceMode == mode
        return Button {
            appearanceMode = mode
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(width: 80, height: 64)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Mobile Sync

    @State private var isSyncAdvertising = false
    @State private var pinEntry = ""
    @State private var pinError = false

    private var mobileSyncContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Send catalog to iPhone")
                    .font(.headline)
                Text("Start advertising to let the HoehnPhotos iOS app discover this Mac and receive the catalog database and proxy thumbnails over WiFi or Bluetooth.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            if isSyncAdvertising {
                VStack(alignment: .leading, spacing: 8) {
                    switch peerSync.state {
                    case .idle, .advertising:
                        Label("Waiting for iPhone...", systemImage: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.orange)
                    case .pinConfirmation(_, let peerName):
                        VStack(alignment: .leading, spacing: 12) {
                            Label("\(peerName) wants to connect", systemImage: "iphone")
                            Text("Enter the PIN shown on your iPhone to confirm:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                TextField("PIN", text: $pinEntry)
                                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 100)
                                    .multilineTextAlignment(.center)
                                    .onSubmit { verifyPin() }
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 4)

                            if pinError {
                                Text("PIN does not match. Try again.")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }

                            HStack(spacing: 12) {
                                Button("Connect") { verifyPin() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(pinEntry.count != 4)
                                Button("Reject") {
                                    peerSync.rejectPin()
                                    pinEntry = ""
                                    pinError = false
                                }
                                .buttonStyle(.bordered)
                                .foregroundStyle(.red)
                            }
                        }
                    case .connecting(let name):
                        Label("Connecting to \(name)...", systemImage: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.orange)
                    case .connected(let name):
                        Label("Connected to \(name) (encrypted)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Send Catalog Now") {
                            sendCatalogToPhone()
                        }
                        .buttonStyle(.borderedProminent)
                    case .sending(let progress, let file):
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Sending: \(file)", systemImage: "lock.shield")
                            ProgressView(value: progress)
                                .tint(.accentColor)
                            Text("\(Int(progress * 100))%")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    case .completed(let count):
                        Label("\(count) files sent", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failed(let err):
                        Label(err, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )

                Button("Stop Advertising") {
                    peerSync.stop()
                    isSyncAdvertising = false
                }
                .buttonStyle(.bordered)
            } else {
                Button("Start Advertising") {
                    peerSync.start()
                    isSyncAdvertising = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func verifyPin() {
        if case .pinConfirmation(let correctPin, _) = peerSync.state {
            if pinEntry == correctPin {
                pinError = false
                pinEntry = ""
                peerSync.confirmPin()
            } else {
                pinError = true
            }
        }
    }

    private func sendCatalogToPhone() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let baseDir = appSupport.appendingPathComponent("HoehnPhotosOrganizer")
        let dbURL = baseDir.appendingPathComponent("Catalog.db")

        // Proxies live in the proxies/ subdirectory
        let proxyDir = baseDir.appendingPathComponent("proxies")
        let proxyURL = fm.fileExists(atPath: proxyDir.path) ? proxyDir : nil

        peerSync.sendCatalog(dbURL: dbURL, proxyDirectory: proxyURL)
    }

    // MARK: - Anthropic API

    private var anthropicContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("API Key")
                        .font(.headline)
                    Text("Used for Claude AI (vision, editorial critique, gear notes, and more)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
            }

            HStack(spacing: 8) {
                if anthropicKeyMasked && anthropicStatus == .configured {
                    HStack {
                        Text("sk-ant-\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Edit") {
                            anthropicKeyMasked = false
                            anthropicKey = ""
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                } else {
                    SecureField("sk-ant-...", text: $anthropicKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit { saveKey() }
                }

                Button("Save") { saveKey() }
                    .buttonStyle(.bordered)
                    .disabled(anthropicKey.isEmpty)

                Button {
                    testKey()
                } label: {
                    if isTesting {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Testing...")
                        }
                        .frame(minWidth: 80)
                    } else {
                        Text("Test Key")
                            .frame(minWidth: 80)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(anthropicStatus == .unknown || isTesting)
            }

            if !anthropicTestMessage.isEmpty {
                HStack(spacing: 6) {
                    if anthropicStatus == .valid {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if anthropicStatus == .invalid {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    Text(anthropicTestMessage)
                        .foregroundStyle(anthropicStatus == .valid ? .green : (anthropicStatus == .invalid ? .red : .secondary))
                }
                .font(.caption)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - Machine Learning

    private var mlContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LOCAL").settingsLabel()
            MLModelRow(name: "Ollama", detail: "Local LLM host process", status: .running, statusLabel: "Running")
            MLModelRow(name: "llama3.2", detail: "Text queries · NL search · summarisation", status: .available, statusLabel: "Available")
            MLModelRow(name: "llava:13b", detail: "Vision · image understanding · captioning", status: .available, statusLabel: "Available")
            MLModelRow(name: "Apple Vision", detail: "Scene classification · text recognition · face detection", status: .builtin, statusLabel: "Built-in")
            MLModelRow(name: "Core ML", detail: "Custom model inference on-device", status: .builtin, statusLabel: "Built-in")

            Divider().padding(.vertical, 4)

            Text("FACE INDEXING").settingsLabel()

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Re-index Faces")
                        .font(.headline)
                    Text("Detects and indexes faces in all proxy images. Clears existing embeddings first. Run after importing new photos.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !faceIndexMessage.isEmpty {
                        Text(faceIndexMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isFaceIndexing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 120)
                } else {
                    Button("Re-index Faces") {
                        Task { await reindexFaces() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(db == nil)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            // Threshold tuning — no rebuild needed
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Match Threshold")
                        .font(.headline)
                    Spacer()
                    Text(String(format: "%.2f", faceThreshold))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $faceThreshold, in: 0.30...1.00, step: 0.01)
                    .tint(.accentColor)
                Text("Lower = stricter (fewer matches). Current distances in console start ~0.55. Try 0.60–0.75 to find the sweet spot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            Divider().padding(.vertical, 4)

            Text("REMOTE").settingsLabel()
            MLModelRow(
                name: "Claude Vision",
                detail: anthropicStatus == .configured || anthropicStatus == .valid
                    ? "Image classification · vision analysis"
                    : "Configure API key in Anthropic API",
                status: anthropicStatus == .valid ? .available : (anthropicStatus == .configured ? .available : .notConfigured),
                statusLabel: anthropicStatus == .valid ? "Verified" : (anthropicStatus == .configured ? "Key saved" : "Not configured")
            )
            MLModelRow(
                name: "Claude Editorial Feedback",
                detail: anthropicStatus == .configured || anthropicStatus == .valid
                    ? "Composition critique · print readiness"
                    : "Uses same Anthropic key as Claude Vision",
                status: anthropicStatus == .valid ? .available : (anthropicStatus == .configured ? .available : .notConfigured),
                statusLabel: anthropicStatus == .valid ? "Verified" : (anthropicStatus == .configured ? "Key saved" : "Not configured")
            )
            MLModelRow(name: "AWS Rekognition", detail: "AWS credentials not configured", status: .notConfigured, statusLabel: "Not configured")
            MLModelRow(name: "AWS Bedrock", detail: "AWS credentials not configured", status: .notConfigured, statusLabel: "Not configured")
        }
    }

    // MARK: - Cloud Sync

    private var cloudSyncContent: some View {
        SyncSettingsView(db: db)
    }

    // MARK: - Library Tools

    private var libraryToolsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Scan for Duplicates")
                        .font(.headline)
                    Text("Find near-identical shots using Vision feature prints. No photos are auto-deleted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Scan for Duplicates") {
                    showDuplicateReview = true
                }
                .buttonStyle(.bordered)
                .disabled(db == nil)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Storage Report")
                        .font(.headline)
                    Text("View byte totals by category (originals, proxies, derivatives) and simulate drive consolidation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Storage Report") {
                    showStorageReport = true
                }
                .buttonStyle(.bordered)
                .disabled(db == nil)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }

    // MARK: - Export & Backup

    private var exportBackupContent: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Export Full Catalog")
                    .font(.headline)
                Text("Exports all catalog data as a portable JSON Lines file. Each domain object (photos, drives, threads, pipelines) is one line. Use for backup or migration to a new machine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isExporting {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 120)
            } else {
                Button("Export Full Catalog") {
                    triggerCatalogExport()
                }
                .buttonStyle(.bordered)
                .disabled(db == nil)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - Developer

    private var developerContent: some View {
        VStack(alignment: .leading, spacing: 12) {

            // MARK: Event Outbox Status
            if let processor = outboxProcessor {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Event Outbox")
                        .font(.headline)

                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(processor.queueDepth)")
                                .font(.system(size: 28, weight: .bold, design: .monospaced))
                                .foregroundStyle(processor.queueDepth > 0 ? .orange : .primary)
                            Text("Pending")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(processor.failedCount)")
                                .font(.system(size: 28, weight: .bold, design: .monospaced))
                                .foregroundStyle(processor.failedCount > 0 ? .red : .primary)
                            Text("Failed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            if processor.isProcessing {
                                Label("Processing…", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                            } else if let lastDrained = processor.lastDrainedAt {
                                Text("Last drained \(lastDrained.relativeShort)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            HStack(spacing: 8) {
                                Button("Drain Now") {
                                    Task { await processor.drainNow() }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                if processor.failedCount > 0 {
                                    Button("Retry Failed") {
                                        Task { await processor.resetFailed() }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .foregroundStyle(.orange)
                                }
                            }
                        }
                    }

                    if let err = processor.lastError {
                        Text("⚠ \(err)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }

            // MARK: Clear Library
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Clear Library")
                        .font(.headline)
                    Text("Delete all photos, drives, and metadata from the catalog")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear Library") {
                    showClearConfirmation = true
                }
                .buttonStyle(.bordered)
                .foregroundStyle(.red)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }


    // MARK: - Status badge

    @ViewBuilder
    private var statusBadge: some View {
        switch anthropicStatus {
        case .unknown:
            Label("Not configured", systemImage: "circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        case .configured:
            Label("Key saved", systemImage: "checkmark.circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.blue)
        case .valid:
            Label("Verified", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        case .invalid:
            Label("Invalid", systemImage: "xmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
        }
    }

    // MARK: - Key management

    private func loadKeyStatus() async {
        let configured = await authManager.isConfigured()
        anthropicStatus = configured ? .configured : .unknown
        anthropicKeyMasked = configured
    }

    private func saveKey() {
        guard !anthropicKey.isEmpty else { return }
        Task {
            do {
                try await authManager.setAPIKey(anthropicKey)
                anthropicStatus = .configured
                anthropicKeyMasked = true
                anthropicTestMessage = "Key saved to Keychain."
            } catch {
                anthropicStatus = .invalid
                anthropicTestMessage = error.localizedDescription
            }
        }
    }

    private func testKey() {
        isTesting = true
        anthropicTestMessage = ""
        Task {
            do {
                let provider = ClaudeVisionProvider(authManager: authManager)
                let prompt = VisionPrompt(
                    systemMessage: nil,
                    userMessage: "Reply with exactly: OK",
                    imageData: minimalTestImage(),
                    imageMediaType: "image/jpeg",
                    maxTokens: 16
                )
                let response = try await provider.analyze(prompt)
                anthropicStatus = .valid
                anthropicTestMessage = "Connection successful: \"\(response.prefix(40))\""
            } catch let error as VisionModelError {
                anthropicStatus = .invalid
                anthropicTestMessage = "Test failed: \(error.localizedDescription)"
            } catch {
                anthropicStatus = .invalid
                anthropicTestMessage = "Test failed: \(error.localizedDescription)"
            }
            isTesting = false
        }
    }

    private func minimalTestImage() -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = ctx.makeImage() else {
            return Data()
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.5]) ?? Data()
    }

    private func reindexFaces() async {
        guard let db, let photoRepo else { return }
        isFaceIndexing = true
        faceIndexMessage = "Clearing existing embeddings…"

        let faceRepo = FaceEmbeddingRepository(db: db)
        do {
            try await faceRepo.deleteAll()
            // Clear faceIndexedAt so all photos are re-scanned
            try await photoRepo.clearAllFaceIndexed()
        } catch {
            faceIndexMessage = "Failed: \(error.localizedDescription)"
            isFaceIndexing = false
            return
        }

        let photos: [PhotoAsset]
        do {
            photos = try await photoRepo.fetchAll()
        } catch {
            faceIndexMessage = "Failed to load photos: \(error.localizedDescription)"
            isFaceIndexing = false
            return
        }

        var indexed = 0
        let total = photos.count
        for photo in photos {
            let baseName = (photo.canonicalName as NSString).deletingPathExtension
            let proxyURL = ProxyGenerationActor.proxiesDirectory()
                .appendingPathComponent(baseName + ".jpg")
            guard FileManager.default.fileExists(atPath: proxyURL.path) else { continue }

            let crops = await Task.detached(priority: .utility) {
                FaceChipGrid.detectAndCropWithBounds(from: proxyURL)
            }.value

            let now = ISO8601DateFormatter().string(from: Date())
            for (index, pair) in crops.enumerated() {
                let (cropImage, bbox) = pair
                guard let cgImage = cropImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let featureData = FaceEmbeddingService.generateFeaturePrint(for: cgImage) else { continue }
                let record = FaceEmbedding(
                    id: UUID().uuidString,
                    photoId: photo.id,
                    faceIndex: index,
                    bboxX: bbox.minX, bboxY: bbox.minY, bboxWidth: bbox.width, bboxHeight: bbox.height,
                    featureData: featureData,
                    createdAt: now,
                    personId: nil,
                    labeledBy: nil,
                    needsReview: false
                )
                try? await faceRepo.upsert(record)
            }

            // Stamp faceIndexedAt
            try? await photoRepo.markFaceIndexed(id: photo.id)

            indexed += 1
            faceIndexMessage = "Indexing… \(indexed)/\(total)"
        }

        faceIndexMessage = "Done — \(indexed) photos indexed."
        print("[FaceIndex] Reindexing complete — \(indexed)/\(total) photos indexed.")
        isFaceIndexing = false
    }

    private func triggerCatalogExport() {
        guard let db else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = CatalogExportAuditService.defaultOutputURL().lastPathComponent
        panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .json]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            isExporting = true
            do {
                try await CatalogExportAuditService(db: db).exportAll(to: url)
                exportSuccess = true
            } catch {
                exportErrorMessage = error.localizedDescription
            }
            isExporting = false
        }
    }
}

// MARK: - Supporting types

private enum AnthropicKeyStatus {
    case unknown, configured, valid, invalid
}

private enum MLStatus {
    case running, available, builtin, notConfigured
}

private struct MLModelRow: View {
    let name: String
    let detail: String
    let status: MLStatus
    let statusLabel: String

    private var statusColor: Color {
        switch status {
        case .running: .green
        case .available: .blue
        case .builtin: Color.accentColor
        case .notConfigured: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(statusLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private extension Text {
    func settingsLabel() -> some View {
        self.font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.leading, 4)
            .padding(.top, 4)
    }
}

// MARK: - Helpers

private extension Date {
    var relativeShort: String {
        let s = Date().timeIntervalSince(self)
        if s < 60    { return "just now" }
        if s < 3600  { return "\(Int(s / 60))m ago" }
        return "\(Int(s / 3600))h ago"
    }
}
