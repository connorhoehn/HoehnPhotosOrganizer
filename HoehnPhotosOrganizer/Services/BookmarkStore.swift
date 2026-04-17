import Foundation

// MARK: - BookmarkStore

/// Persists security-scoped bookmarks so sandboxed file access survives app restarts.
///
/// Usage:
///   - Call `store(_:)` immediately after the user grants access (NSOpenPanel, drag-and-drop).
///   - Call `withAccess(to:body:)` wherever you need to read/write a file outside the sandbox.
///
/// Bookmarks are stored per-directory. When a file URL is requested, the store walks
/// up the path hierarchy until it finds a matching bookmark.
actor BookmarkStore {

    static let shared = BookmarkStore()

    private let defaultsKey = "HPN.SecurityScopedBookmarks.v1"

    // MARK: - Store

    /// Persist a security-scoped bookmark for `url`.
    /// Call this while sandbox access is still active (e.g. immediately after NSOpenPanel returns).
    func store(_ url: URL) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var map = loadMap()
            map[url.path] = data
            UserDefaults.standard.set(map, forKey: defaultsKey)
        } catch {
            print("[BookmarkStore] Failed to store bookmark for \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: - Access

    /// Execute `body` with security-scoped access to `url`.
    /// Automatically redeems the nearest stored bookmark (exact URL or a parent directory).
    /// Returns `nil` without calling `body` if no bookmark can be redeemed.
    @discardableResult
    func withAccess<T>(to url: URL, body: () throws -> T) throws -> T {
        let (scopeURL, didStart) = resolveAccess(for: url)
        defer { if didStart { scopeURL?.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    /// Begin security-scoped access for `url`.
    /// Returns the URL whose `stopAccessingSecurityScopedResource` must be called when done.
    /// Returns `nil` if no bookmark covers `url` (access may still succeed if within the same session).
    func startAccess(for url: URL) -> URL? {
        let (scopeURL, started) = resolveAccess(for: url)
        return started ? scopeURL : nil
    }

    // MARK: - Private

    private func resolveAccess(for url: URL) -> (URL?, Bool) {
        let map = loadMap()
        var candidate = url

        while candidate.pathComponents.count > 1 {
            if let data = map[candidate.path] {
                var stale = false
                if let resolved = try? URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                ) {
                    if stale {
                        // Refresh stale bookmark asynchronously
                        let refreshed = resolved
                        Task { await self.store(refreshed) }
                    }
                    if resolved.startAccessingSecurityScopedResource() {
                        return (resolved, true)
                    }
                }
            }
            candidate = candidate.deletingLastPathComponent()
        }

        return (nil, false)
    }

    private func loadMap() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }
}
