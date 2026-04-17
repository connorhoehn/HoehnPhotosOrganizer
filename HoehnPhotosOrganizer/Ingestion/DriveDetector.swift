import Foundation
import AppKit
import Combine

// MARK: - DriveInfo

struct DriveInfo {
    let volumeLabel: String
    let mountPoint: URL
    let totalBytes: Int
    let freeBytes: Int
    let volumeUUID: String
}

// MARK: - DriveDetector

/// @MainActor ObservableObject that listens to NSWorkspace mount/unmount notifications
/// and publishes the current set of connected external volumes.
///
/// DriveDetector is instantiated in LibraryViewModel and does not access the DB directly.
/// IngestionActor receives a DriveInfo value and handles the DriveDB upsert.
@MainActor
final class DriveDetector: ObservableObject {
    @Published var mountedDrives: [DriveInfo] = []

    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        observers.append(nc.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
    }

    deinit {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }

    /// Re-enumerate all mounted volumes and update mountedDrives.
    /// Excludes the boot volume (path == "/") and hidden volumes.
    /// Filter out installer, recovery, and system utility volumes.
    private static func isInstallerVolume(name: String, path: String) -> Bool {
        let lower = name.lowercased()
        let installerKeywords = ["installer", "install", "recovery", "setup", "update", "firmware", "driver"]
        for kw in installerKeywords {
            if lower.contains(kw) { return true }
        }
        // Filter volumes with no useful photo content (very small or system-like)
        if lower.hasPrefix("preboot") || lower.hasPrefix("vm") || lower == "data" { return true }
        return false
    }

    func refresh() {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsRemovableKey,
            .volumeUUIDStringKey
        ]
        let vols = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: .skipHiddenVolumes
        ) ?? []
        mountedDrives = vols.compactMap { url in
            guard
                let vals  = try? url.resourceValues(forKeys: Set(keys)),
                let name  = vals.volumeName,
                let total = vals.volumeTotalCapacity,
                let free  = vals.volumeAvailableCapacity,
                url.path != "/",   // exclude boot volume
                !Self.isInstallerVolume(name: name, path: url.path)
            else { return nil }
            let uuid = vals.volumeUUIDString ?? String(abs(url.path.hashValue), radix: 16)
            return DriveInfo(
                volumeLabel: name,
                mountPoint: url,
                totalBytes: total,
                freeBytes: free,
                volumeUUID: uuid
            )
        }
    }
}
