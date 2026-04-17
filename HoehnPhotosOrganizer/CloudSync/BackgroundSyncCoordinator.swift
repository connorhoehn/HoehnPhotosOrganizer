// BackgroundSyncCoordinator.swift
// HoehnPhotosOrganizer
//
// Wifi-only periodic sync actor.
// Reads interval from UserDefaults key "syncIntervalMinutes" (default 15).
// Reads wifi-only flag from UserDefaults key "syncOnWifiOnly" (default true).
//
// Graceful degradation: if syncEnabled == false or syncAPIEndpoint is absent,
// startPeriodicSync() is never called and the app functions fully in local-only mode.

import Foundation
import Network

actor BackgroundSyncCoordinator {
    private let syncCoordinator: IncrementalSyncCoordinator
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.hoehnphotos.sync.network.monitor")

    private var isOnWifi: Bool = false
    private var syncTask: Task<Void, Never>?
    private var isEnabled: Bool = false

    init(syncCoordinator: IncrementalSyncCoordinator) {
        self.syncCoordinator = syncCoordinator
    }

    /// Start periodic sync. Reads interval from UserDefaults (key: "syncIntervalMinutes", default: 15).
    /// Only syncs when on wifi (UserDefaults key: "syncOnWifiOnly", default: true).
    /// Call only when credentials are confirmed present — otherwise app degrades to local-only.
    func startPeriodicSync() {
        isEnabled = true
        monitor.pathUpdateHandler = { [weak self] path in
            Task { await self?.handleNetworkChange(path) }
        }
        monitor.start(queue: monitorQueue)

        let intervalMinutes = UserDefaults.standard.integer(forKey: "syncIntervalMinutes")
        let interval = intervalMinutes > 0 ? intervalMinutes : 15
        scheduleSync(intervalMinutes: interval)
    }

    func stopSync() {
        isEnabled = false
        syncTask?.cancel()
        syncTask = nil
        monitor.cancel()
    }

    /// Manual trigger — bypasses interval timer.
    func syncNow() async throws {
        guard isOnWifi || !UserDefaults.standard.bool(forKey: "syncOnWifiOnly") else {
            return // Skip if wifi-only and not on wifi
        }
        try await syncCoordinator.syncIncremental()
    }

    private func handleNetworkChange(_ path: NWPath) {
        isOnWifi = path.usesInterfaceType(.wifi)
    }

    private func scheduleSync(intervalMinutes: Int) {
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }
                let wifiOnly = UserDefaults.standard.bool(forKey: "syncOnWifiOnly")
                let enabled = await self.isEnabled
                let onWifi = await self.isOnWifi
                if enabled && (!wifiOnly || onWifi) {
                    do {
                        try await self.syncCoordinator.syncIncremental()
                    } catch {
                        // Log error but don't crash — sync will retry next interval
                        print("[BackgroundSync] Error: \(error.localizedDescription)")
                    }
                }
                try? await Task.sleep(for: .seconds(intervalMinutes * 60))
            }
        }
    }
}
