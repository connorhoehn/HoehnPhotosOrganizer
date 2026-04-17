import CloudKit
import Foundation
import os
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Manages local proxy image cache with on-demand CloudKit download and LRU eviction (iOS).
public actor ProxyCacheManager {

    // MARK: - Configuration

    /// Maximum cached proxies before LRU eviction kicks in.
    /// On macOS the limit is effectively unlimited (disk is cheap); on iOS we cap at 2000.
    public let maxCacheCount: Int

    private let logger = Logger(subsystem: "com.connorhoehn.HoehnPhotos", category: "ProxyCacheManager")

    /// Plist file tracking last-access dates for LRU eviction.
    private var accessLog: [String: Date] // canonicalName → lastAccessDate

    private let accessLogURL: URL

    // MARK: - Init

    public init(maxCacheCount: Int? = nil) {
        #if os(iOS)
        let defaultMax = 2000
        #else
        let defaultMax = Int.max
        #endif
        self.maxCacheCount = maxCacheCount ?? defaultMax

        let dir = Self.resolveProxyDirectory()
        self.accessLogURL = dir.appendingPathComponent(".proxy_access_log.plist")

        // Load existing access log
        if let data = try? Data(contentsOf: self.accessLogURL),
           let dict = try? PropertyListDecoder().decode([String: Date].self, from: data) {
            self.accessLog = dict
        } else {
            self.accessLog = [:]
        }
    }

    // MARK: - Platform helpers

    /// Platform-specific proxy cache directory.
    public nonisolated var proxyDirectory: URL {
        Self.resolveProxyDirectory()
    }

    private static func resolveProxyDirectory() -> URL {
        let fm = FileManager.default

        #if os(iOS)
        let appName = "HoehnPhotos"
        #else
        let appName = "HoehnPhotosOrganizer"
        #endif

        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport
            .appendingPathComponent(appName, isDirectory: true)
            .appendingPathComponent("proxies", isDirectory: true)

        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - Local cache queries

    /// Returns the local file URL if a cached proxy exists for the given canonical name.
    public func localProxyURL(for canonicalName: String) -> URL? {
        let url = proxyDirectory.appendingPathComponent("\(canonicalName).jpg")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        recordAccess(canonicalName)
        return url
    }

    /// Whether a proxy is already cached locally.
    public func hasProxy(for canonicalName: String) -> Bool {
        let url = proxyDirectory.appendingPathComponent("\(canonicalName).jpg")
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - On-demand download

    /// Fetch a single proxy from CloudKit, cache it locally, and return the local URL.
    @discardableResult
    public func fetchProxy(
        recordName: String,
        canonicalName: String,
        database: CKDatabase,
        zoneID: CKRecordZone.ID
    ) async throws -> URL {
        // Check cache first
        let localURL = proxyDirectory.appendingPathComponent("\(canonicalName).jpg")
        if FileManager.default.fileExists(atPath: localURL.path) {
            recordAccess(canonicalName)
            return localURL
        }

        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        let record = try await database.record(for: recordID)

        guard let asset = record["proxyAsset"] as? CKAsset,
              let assetURL = asset.fileURL else {
            throw ProxyCacheError.missingAsset(recordName: recordName)
        }

        // Copy the CloudKit temp file into our cache directory
        let fm = FileManager.default
        if fm.fileExists(atPath: localURL.path) {
            try fm.removeItem(at: localURL)
        }
        try fm.copyItem(at: assetURL, to: localURL)

        recordAccess(canonicalName)
        logger.info("Cached proxy for \(canonicalName)")
        return localURL
    }

    // MARK: - Batch prefetch

    /// Download proxies concurrently (up to 50 at a time), skipping those already cached.
    /// `onProgress` is called with (completed, total) counts.
    public func prefetchProxies(
        recordNames: [(recordName: String, canonicalName: String)],
        database: CKDatabase,
        zoneID: CKRecordZone.ID,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async {
        // Filter out already-cached proxies
        let needed = recordNames.filter { !hasProxy(for: $0.canonicalName) }
        guard !needed.isEmpty else {
            onProgress?(recordNames.count, recordNames.count)
            return
        }

        let total = needed.count
        let completed = ManagedAtomic(0)

        await withTaskGroup(of: Void.self) { group in
            // Limit concurrency to 50
            var launched = 0
            for item in needed {
                if launched >= 50 {
                    // Wait for one to finish before launching another
                    await group.next()
                }
                launched += 1

                group.addTask { [self] in
                    do {
                        try await self.fetchProxy(
                            recordName: item.recordName,
                            canonicalName: item.canonicalName,
                            database: database,
                            zoneID: zoneID
                        )
                    } catch {
                        self.logger.warning("Failed to prefetch proxy \(item.canonicalName): \(error.localizedDescription)")
                    }
                    let done = completed.increment()
                    onProgress?(done, total)
                }
            }
            // Await remaining tasks
            for await _ in group {}
        }

        // Evict if over limit (iOS)
        #if os(iOS)
        evictOldest(keepCount: maxCacheCount)
        #endif

        persistAccessLog()
    }

    // MARK: - LRU eviction

    /// Delete oldest-accessed proxies beyond the keep limit.
    public func evictOldest(keepCount: Int) {
        let fm = FileManager.default
        let dir = proxyDirectory

        // Sort by last access time, oldest first
        let sorted = accessLog.sorted { $0.value < $1.value }
        let excess = sorted.count - keepCount
        guard excess > 0 else { return }

        let toEvict = sorted.prefix(excess)
        for (name, _) in toEvict {
            let url = dir.appendingPathComponent("\(name).jpg")
            try? fm.removeItem(at: url)
            accessLog.removeValue(forKey: name)
        }

        logger.info("Evicted \(excess) proxies, cache now at \(self.accessLog.count)")
        persistAccessLog()
    }

    // MARK: - Access tracking

    private func recordAccess(_ canonicalName: String) {
        accessLog[canonicalName] = Date()
    }

    private func persistAccessLog() {
        do {
            let data = try PropertyListEncoder().encode(accessLog)
            try data.write(to: accessLogURL, options: .atomic)
        } catch {
            logger.warning("Failed to persist access log: \(error.localizedDescription)")
        }
    }
}

// MARK: - Errors

public enum ProxyCacheError: LocalizedError {
    case missingAsset(recordName: String)

    public var errorDescription: String? {
        switch self {
        case .missingAsset(let name):
            return "No proxyAsset found on CloudKit record '\(name)'"
        }
    }
}

// MARK: - Simple atomic counter (no external dependencies)

/// Minimal lock-based atomic integer for progress tracking across concurrent tasks.
private final class ManagedAtomic: @unchecked Sendable {
    private var value: Int
    private let lock = NSLock()

    init(_ initial: Int) {
        self.value = initial
    }

    /// Increment and return the new value.
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
