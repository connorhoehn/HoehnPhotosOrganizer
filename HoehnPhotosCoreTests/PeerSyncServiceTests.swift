//
//  PeerSyncServiceTests.swift
//  HoehnPhotosCoreTests
//
//  Tests for the people-delta queue plumbing on `PeerSyncService`:
//    - enqueuePeopleDelta appends + de-dups by delta.id
//    - pendingPeopleDeltas is persisted to UserDefaults under "pendingPeopleDeltas"
//    - A new PeerSyncService() hydrates via loadPendingPeopleDeltas()
//    - People-delta enqueues do not mutate the photo-curation `pendingDeltas`
//
//  NOTE ON PERSISTENCE ISOLATION
//  -----------------------------
//  `PeerSyncService` writes directly to `UserDefaults.standard` — it does not
//  accept a suite name injection. To keep these tests from polluting the real
//  app defaults (and to keep runs reproducible), each test:
//    1. Snapshots the live "pendingPeopleDeltas" and "pendingCurationDeltas"
//       values in setUp.
//    2. Clears them before the service under test is created.
//    3. Restores the snapshot in tearDown.
//  All work happens inside `UserDefaults.standard` because that's what the
//  production code reads/writes. Swap in a suite-backed injection later and
//  these tests can move to it trivially.
//

import XCTest
@testable import HoehnPhotosCore

@MainActor
final class PeerSyncServiceTests: XCTestCase {

    private let peopleKey = "pendingPeopleDeltas"
    private let curationKey = "pendingCurationDeltas"

    private var savedPeople: Any?
    private var savedCuration: Any?

    override func setUp() async throws {
        try await super.setUp()
        // Snapshot any pre-existing values so real app data isn't lost
        savedPeople = UserDefaults.standard.object(forKey: peopleKey)
        savedCuration = UserDefaults.standard.object(forKey: curationKey)
        UserDefaults.standard.removeObject(forKey: peopleKey)
        UserDefaults.standard.removeObject(forKey: curationKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: peopleKey)
        UserDefaults.standard.removeObject(forKey: curationKey)
        if let savedPeople { UserDefaults.standard.set(savedPeople, forKey: peopleKey) }
        if let savedCuration { UserDefaults.standard.set(savedCuration, forKey: curationKey) }
        savedPeople = nil
        savedCuration = nil
        try await super.tearDown()
    }

    // MARK: - enqueue / de-dup

    func testEnqueuePeopleDeltaAppendsToPendingQueue() {
        let service = PeerSyncService()
        XCTAssertTrue(service.pendingPeopleDeltas.isEmpty)

        let delta = PeopleSyncDelta.renamePerson(id: "p1", name: "Alice")
        service.enqueuePeopleDelta(delta)

        XCTAssertEqual(service.pendingPeopleDeltas.count, 1)
        XCTAssertEqual(service.pendingPeopleDeltas.first, delta)
    }

    func testEnqueueTwoDistinctDeltasKeepsBoth() {
        let service = PeerSyncService()
        let a = PeopleSyncDelta.renamePerson(id: "p1", name: "A")
        let b = PeopleSyncDelta.renamePerson(id: "p2", name: "B")
        service.enqueuePeopleDelta(a)
        service.enqueuePeopleDelta(b)
        XCTAssertEqual(service.pendingPeopleDeltas.count, 2)
    }

    func testEnqueueDeDupsByIdLatestWins() {
        let service = PeerSyncService()
        let first = PeopleSyncDelta.renamePerson(id: "p1", name: "First")
        let second = PeopleSyncDelta.renamePerson(id: "p1", name: "Second")
        XCTAssertEqual(first.id, second.id, "Pre-condition: both share the same de-dup id")

        service.enqueuePeopleDelta(first)
        service.enqueuePeopleDelta(second)

        XCTAssertEqual(service.pendingPeopleDeltas.count, 1, "Duplicate id must collapse")
        XCTAssertEqual(service.pendingPeopleDeltas.first, second, "Latest delta must win")
    }

    func testEnqueueDifferentOperationsOnSameTargetDoNotCollapse() {
        // Same person id but distinct ops (rename vs delete) → both should persist.
        let service = PeerSyncService()
        let rename = PeopleSyncDelta.renamePerson(id: "p1", name: "X")
        let delete = PeopleSyncDelta.deletePerson(id: "p1")
        service.enqueuePeopleDelta(rename)
        service.enqueuePeopleDelta(delete)
        XCTAssertEqual(service.pendingPeopleDeltas.count, 2)
    }

    // MARK: - Persistence to UserDefaults

    func testEnqueuePersistsToUserDefaults() throws {
        let service = PeerSyncService()
        let delta = PeopleSyncDelta.assignFace(faceId: "f1", personId: "p1")
        service.enqueuePeopleDelta(delta)

        guard let json = UserDefaults.standard.string(forKey: peopleKey) else {
            return XCTFail("Expected pendingPeopleDeltas in UserDefaults")
        }
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode([PeopleSyncDelta].self, from: data)
        XCTAssertEqual(decoded, [delta])
    }

    func testEnqueueOverwritesPersistedPayloadAfterDeDup() throws {
        let service = PeerSyncService()
        let first = PeopleSyncDelta.renamePerson(id: "p1", name: "First")
        let second = PeopleSyncDelta.renamePerson(id: "p1", name: "Second")
        service.enqueuePeopleDelta(first)
        service.enqueuePeopleDelta(second)

        let json = try XCTUnwrap(UserDefaults.standard.string(forKey: peopleKey))
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode([PeopleSyncDelta].self, from: data)
        XCTAssertEqual(decoded, [second])
    }

    // MARK: - Hydration across init

    func testNewServiceInstanceLoadsPersistedDeltas() throws {
        // Arrange: write deltas via instance 1
        let a = PeerSyncService()
        let d1 = PeopleSyncDelta.renamePerson(id: "p1", name: "A")
        let d2 = PeopleSyncDelta.assignFace(faceId: "f1", personId: "p1")
        a.enqueuePeopleDelta(d1)
        a.enqueuePeopleDelta(d2)
        XCTAssertEqual(a.pendingPeopleDeltas.count, 2)

        // Act: create a fresh service — init() should call loadPendingPeopleDeltas()
        let b = PeerSyncService()

        // Assert
        XCTAssertEqual(b.pendingPeopleDeltas.count, 2)
        XCTAssertEqual(Set(b.pendingPeopleDeltas.map(\.id)), Set([d1.id, d2.id]))
    }

    func testLoadPendingPeopleDeltasIsIdempotent() {
        let service = PeerSyncService()
        let d = PeopleSyncDelta.renamePerson(id: "p1", name: "A")
        service.enqueuePeopleDelta(d)
        XCTAssertEqual(service.pendingPeopleDeltas.count, 1)

        // Calling load again should not duplicate — it should overwrite from persistence.
        service.loadPendingPeopleDeltas()
        XCTAssertEqual(service.pendingPeopleDeltas.count, 1)
        XCTAssertEqual(service.pendingPeopleDeltas.first, d)
    }

    func testLoadPendingPeopleDeltasWithNoPersistedDataKeepsQueueEmpty() {
        // Nothing persisted — load should be a no-op on the empty queue.
        UserDefaults.standard.removeObject(forKey: peopleKey)
        let service = PeerSyncService()
        XCTAssertTrue(service.pendingPeopleDeltas.isEmpty)
        service.loadPendingPeopleDeltas()
        XCTAssertTrue(service.pendingPeopleDeltas.isEmpty)
    }

    func testCorruptPersistedJSONIsIgnored() {
        // If the persisted blob is garbage, load should leave the queue untouched.
        UserDefaults.standard.set("not valid json", forKey: peopleKey)
        let service = PeerSyncService()
        XCTAssertTrue(service.pendingPeopleDeltas.isEmpty)
    }

    // MARK: - Isolation from photo-curation queue

    func testEnqueuePeopleDeltaDoesNotTouchPhotoCurationQueue() {
        let service = PeerSyncService()
        XCTAssertTrue(service.pendingDeltas.isEmpty)

        let peopleDelta = PeopleSyncDelta.renamePerson(id: "p1", name: "A")
        service.enqueuePeopleDelta(peopleDelta)

        XCTAssertEqual(service.pendingPeopleDeltas.count, 1)
        XCTAssertTrue(service.pendingDeltas.isEmpty, "People deltas must not leak into photo curation queue")
    }

    func testEnqueuePhotoCurationDeltaDoesNotTouchPeopleQueue() {
        let service = PeerSyncService()
        XCTAssertTrue(service.pendingPeopleDeltas.isEmpty)

        let photoDelta = PhotoCurationDelta(photoId: "photo-1", curationState: "keeper")
        service.enqueueDelta(photoDelta)

        XCTAssertEqual(service.pendingDeltas.count, 1)
        XCTAssertTrue(service.pendingPeopleDeltas.isEmpty, "Photo curation deltas must not leak into people queue")
    }

    func testQueuesUseSeparateUserDefaultsKeys() throws {
        let service = PeerSyncService()
        let peopleDelta = PeopleSyncDelta.renamePerson(id: "p1", name: "A")
        let photoDelta = PhotoCurationDelta(photoId: "photo-1", curationState: "keeper")
        service.enqueuePeopleDelta(peopleDelta)
        service.enqueueDelta(photoDelta)

        XCTAssertNotNil(UserDefaults.standard.string(forKey: peopleKey))
        XCTAssertNotNil(UserDefaults.standard.string(forKey: curationKey))

        // Sanity: neither blob should contain the other's id shape.
        let peopleJSON = try XCTUnwrap(UserDefaults.standard.string(forKey: peopleKey))
        let curationJSON = try XCTUnwrap(UserDefaults.standard.string(forKey: curationKey))
        XCTAssertFalse(peopleJSON.contains("\"curationState\""), "People blob leaked into curation shape")
        XCTAssertFalse(curationJSON.contains("renamePerson"), "Curation blob leaked into people shape")
    }

    // MARK: - flushPeopleDeltas safety when disconnected

    func testFlushPeopleDeltasIsSafeWhenEmptyAndDisconnected() {
        // Should not crash / throw when there's nothing to flush and no coordinator.
        let service = PeerSyncService()
        XCTAssertTrue(service.pendingPeopleDeltas.isEmpty)
        service.flushPeopleDeltas()
        XCTAssertTrue(service.pendingPeopleDeltas.isEmpty)
    }

    func testFlushPeopleDeltasDoesNotClearQueueUntilAcked() {
        // flushPeopleDeltas only sends; it doesn't clear. Queue stays until PEOPLE_ACK.
        let service = PeerSyncService()
        service.enqueuePeopleDelta(.renamePerson(id: "p1", name: "A"))
        service.flushPeopleDeltas()
        XCTAssertEqual(service.pendingPeopleDeltas.count, 1, "Queue should survive a flush until server acks")
    }
}
