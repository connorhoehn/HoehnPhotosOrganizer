// ConflictResolutionTests.swift
// HoehnPhotosOrganizerTests
//
// Tests for LastEditWinsConflictRule and ConflictResolver.
// SYNC-10: Conflict resolution when the same data is edited on two Macs.

import Testing
import Combine
@testable import HoehnPhotosOrganizer

struct ConflictResolutionTests {

    // MARK: - Helpers

    private func makeEntry(
        photoId: String = "IMG_001.CR3",
        entryId: String = UUID().uuidString,
        timestamp: Int64,
        content: String = "{}"
    ) -> SyncThreadEntry {
        SyncThreadEntry(
            threadRootId: photoId,
            entryId: entryId,
            timestamp: timestamp,
            type: .note,
            content: content,
            syncedAt: nil
        )
    }

    // MARK: - Tests

    @Test
    func test_conflictResolution_lastEditWins() async {
        // Remote (T=200) must beat local (T=100)
        let resolver = ConflictResolver()
        let local  = makeEntry(entryId: "local-id",  timestamp: 100)
        let remote = makeEntry(entryId: "remote-id", timestamp: 200)

        let resolution = await resolver.resolve(local: local, remote: remote)

        switch resolution {
        case .keep(let winner):
            #expect(winner.entryId == "remote-id")
        case .userChoice:
            Issue.record("Expected .keep(remote) but got .userChoice")
        }
    }

    @Test
    func test_conflictResolution_withNotification() async throws {
        // ConflictResolver must publish a notification on conflictNotifications
        let resolver = ConflictResolver()
        let local  = makeEntry(photoId: "IMG_005.DNG", entryId: "local-x",  timestamp: 300)
        let remote = makeEntry(photoId: "IMG_005.DNG", entryId: "remote-x", timestamp: 400)

        var received: ConflictResolver.ConflictNotification?
        var cancellable: AnyCancellable?

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            cancellable = resolver.conflictNotifications
                .first()
                .sink { notification in
                    received = notification
                    cont.resume()
                }
            Task { _ = await resolver.resolve(local: local, remote: remote) }
        }
        cancellable?.cancel()

        let n = try #require(received)
        #expect(n.photoId == "IMG_005.DNG")
        #expect(n.localTimestamp == 300)
        #expect(n.remoteTimestamp == 400)
        // Remote had higher timestamp so it wins
        switch n.resolution {
        case .keep(let winner): #expect(winner.entryId == "remote-x")
        case .userChoice: Issue.record("Expected .keep in notification resolution")
        }
    }

    @Test
    func test_conflictResolution_fieldLevelMerge() async {
        // Repurposed as the tie-break test: equal timestamps, higher lexicographic entryId wins.
        // LastEditWinsConflictRule.applyRule: "local.entryId >= remote.entryId ? local : remote"
        let resolver = ConflictResolver()
        let local  = makeEntry(entryId: "aaa-lower",  timestamp: 500)
        let remote = makeEntry(entryId: "zzz-higher", timestamp: 500)

        let resolution = await resolver.resolve(local: local, remote: remote)

        switch resolution {
        case .keep(let winner):
            #expect(winner.entryId == "zzz-higher",
                    "Higher lexicographic entryId must win the tie-break")
        case .userChoice:
            Issue.record("Expected .keep for tie-break but got .userChoice")
        }
    }

    @Test(.disabled("Tombstone not yet modelled in SyncThreadEntry — pending future phase"))
    func test_conflictResolution_tombstone() async {
        // Future: SyncThreadEntry gains a deletedAt or isTombstone field.
        // When local = tombstone and remote = edit, tombstone must win.
    }
}
