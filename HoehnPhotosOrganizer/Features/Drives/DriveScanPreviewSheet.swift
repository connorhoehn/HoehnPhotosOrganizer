import SwiftUI
import GRDB

// MARK: - DriveScanPreviewSheet

/// Pre-import drive scan preview: scans the drive for importable files, shows a summary
/// (photo count, total size, date range, folder breakdown, duplicate detection),
/// and lets the user name the job before starting import.
///
/// Three actions: "Import All", "Import New Only" (skip duplicates), "Cancel".
/// On confirm, the scan result is passed to the import flow so no double-scan occurs.
struct DriveScanPreviewSheet: View {

    @ObservedObject var drive: MountedDriveState
    let onImport: (DriveScanResult, String, ImportMode) -> Void
    let onDismiss: () -> Void

    @Environment(\.appDatabase) private var db

    @State private var phase: ScanPhase = .scanning
    @State private var scanResult: DriveScanResult?
    @State private var jobName: String = ""
    @State private var scanProgress: Double = 0
    @State private var scannedCount: Int = 0

    private let scanService = DriveScanPreviewService()
    private let cancelToken = DriveScanCancellationToken()

    enum ScanPhase {
        case scanning
        case ready
    }

    enum ImportMode {
        case all
        case newOnly
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch phase {
                    case .scanning:
                        scanningContent
                    case .ready:
                        if let result = scanResult {
                            resultContent(result)
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await runScan() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(phase == .scanning ? "Scanning Drive..." : "Drive Scan Preview")
                    .font(.headline)
                Text(drive.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if phase == .scanning {
                Button(action: {
                    cancelToken.cancel()
                    onDismiss()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
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

    // MARK: - Scanning phase

    private var scanningContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scanning for importable photos...")
                        .font(.system(size: 13, weight: .medium))
                    Text("\(scannedCount) files found")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            ProgressView(value: scanProgress)
                .tint(Color.accentColor)

            Text("Reading file metadata only -- no images are being opened or copied.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Result phase

    private func resultContent(_ result: DriveScanResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Summary stats
            summarySection(result)

            Divider()

            // Date range
            if let oldest = result.oldestDate, let newest = result.newestDate {
                dateRangeSection(oldest: oldest, newest: newest)
                Divider()
            }

            // Folder breakdown (if multiple folders)
            if result.folderBreakdown.count > 1 {
                folderBreakdownSection(result.folderBreakdown)
                Divider()
            }

            // Duplicate detection
            if result.duplicateCount > 0 {
                duplicateSection(result)
                Divider()
            }

            // Job naming
            jobNamingSection
        }
    }

    private func summarySection(_ result: DriveScanResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                statBadge(
                    icon: "photo.stack",
                    value: "\(result.photoCount)",
                    label: "Photos"
                )
                statBadge(
                    icon: "internaldrive",
                    value: formatBytes(result.totalBytes),
                    label: "Total Size"
                )
                if result.duplicateCount > 0 {
                    statBadge(
                        icon: "doc.on.doc",
                        value: "\(result.newPhotoCount)",
                        label: "New",
                        tint: .green
                    )
                }
            }
        }
    }

    private func statBadge(icon: String, value: String, label: String, tint: Color = .accentColor) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.06))
        )
    }

    private func dateRangeSection(oldest: Date, newest: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("DATE RANGE")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            } icon: {
                Image(systemName: "calendar")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                Text(DateFormatter.localizedString(from: oldest, dateStyle: .medium, timeStyle: .none))
                    .font(.system(size: 13))
                Image(systemName: "arrow.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(DateFormatter.localizedString(from: newest, dateStyle: .medium, timeStyle: .none))
                    .font(.system(size: 13))
            }
        }
    }

    private func folderBreakdownSection(_ folders: [FolderGroup]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("FOLDERS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            } icon: {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            // Show top 6 folders, collapse the rest
            let visible = Array(folders.prefix(6))
            let remaining = folders.count - visible.count

            ForEach(visible) { folder in
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(folder.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer()
                    Text("\(folder.photoCount) photos")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(formatBytes(folder.totalBytes))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                }
            }

            if remaining > 0 {
                Text("+ \(remaining) more folder\(remaining == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 24)
            }
        }
    }

    private func duplicateSection(_ result: DriveScanResult) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.doc.fill")
                .font(.system(size: 16))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(result.duplicateCount) photo\(result.duplicateCount == 1 ? "" : "s") already in library")
                    .font(.system(size: 13, weight: .medium))
                Text("Matched by filename and file size. Use \"Import New Only\" to skip these.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var jobNamingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("JOB NAME")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            } icon: {
                Image(systemName: "tray.full")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            TextField("Job name", text: $jobName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))

            Text("A triage job will be created in Jobs for this import batch.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            switch phase {
            case .scanning:
                Button("Cancel") {
                    cancelToken.cancel()
                    onDismiss()
                }
                .buttonStyle(.bordered)
                Spacer()

            case .ready:
                Button("Cancel") { onDismiss() }
                    .buttonStyle(.bordered)
                Spacer()

                if let result = scanResult {
                    if result.photoCount == 0 {
                        Text("No importable photos found")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        if result.duplicateCount > 0 && result.newPhotoCount > 0 {
                            Button("Import New Only (\(result.newPhotoCount))") {
                                let name = jobName.isEmpty ? (result.suggestedJobName) : jobName
                                onImport(result, name, .newOnly)
                            }
                            .buttonStyle(.bordered)
                        }

                        Button("Import All (\(result.photoCount))") {
                            let name = jobName.isEmpty ? (result.suggestedJobName) : jobName
                            onImport(result, name, .all)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(result.photoCount == 0)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Scan logic

    private func runScan() async {
        // Poll progress in background
        let token = cancelToken
        let service = scanService
        Task {
            while await service.isScanning {
                scanProgress = await service.progress
                scannedCount = await service.scannedCount
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            scanProgress = 1.0
            scannedCount = await service.scannedCount
        }

        let result = await scanService.scan(
            mountPoint: drive.mountPoint,
            appDatabase: db,
            cancelToken: token
        )

        guard !token.isCancelled else { return }

        scanResult = result
        jobName = result.suggestedJobName
        phase = .ready
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}
