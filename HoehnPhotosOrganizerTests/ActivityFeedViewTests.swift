import Testing
import Foundation
import GRDB
@testable import HoehnPhotosOrganizer

struct ActivityFeedViewTests {

    // MARK: - Helpers

    @MainActor
    private func makeVM(db: AppDatabase? = nil) throws -> ActivityFeedViewModel {
        let d = try db ?? AppDatabase.makeInMemory()
        let repo = ActivityEventRepository(db: d)
        let service = ActivityEventService(repo: repo)
        return ActivityFeedViewModel(repo: repo, service: service)
    }

    private func makeEvent(
        id: String = UUID().uuidString,
        kind: ActivityEventKind,
        metadata: String? = nil,
        detail: String? = nil,
        occurredAt: Date = Date()
    ) -> ActivityEvent {
        ActivityEvent(
            id: id,
            kind: kind,
            parentEventId: nil,
            photoAssetId: nil,
            title: kind.rawValue,
            detail: detail,
            metadata: metadata,
            occurredAt: occurredAt,
            createdAt: occurredAt
        )
    }

    // MARK: - Tests

    @MainActor @Test
    func testFeedDisplaysRootEventsAsCards() throws {
        // A single event produces exactly one .single display item
        let vm = try makeVM()
        let event = makeEvent(kind: .note)
        let items = vm.buildDisplayItems(from: [event])

        #expect(items.count == 1)
        guard case .single(let e) = items[0] else {
            Issue.record("Expected .single, got \(items[0])")
            return
        }
        #expect(e.id == event.id)
    }

    @MainActor @Test
    func testExpandCardRevealsChildEvents() throws {
        // Pre-seeding childrenCache bypasses the async DB load;
        // toggleExpand should then insert into expandedEventIds synchronously.
        let vm = try makeVM()
        vm.childrenCache["event-A"] = []
        vm.toggleExpand(eventId: "event-A")
        #expect(vm.expandedEventIds.contains("event-A"))
    }

    @MainActor @Test
    func testCollapseCardHidesChildEvents() throws {
        // Calling toggleExpand twice removes the eventId from expandedEventIds.
        let vm = try makeVM()
        vm.childrenCache["event-B"] = []
        vm.toggleExpand(eventId: "event-B")
        vm.toggleExpand(eventId: "event-B")
        #expect(!vm.expandedEventIds.contains("event-B"))
    }

    @MainActor @Test
    func testFeedScrollsToLatestEvent() throws {
        // Two consecutive studioRender events with the same medium within 30 min
        // must collapse into a single .group display item.
        let vm = try makeVM()
        let medium = #"{"medium":"Platinum-Palladium"}"#
        let base = Date()
        let e1 = makeEvent(kind: .studioRender, metadata: medium, occurredAt: base)
        let e2 = makeEvent(kind: .studioRender, metadata: medium, occurredAt: base.addingTimeInterval(-5 * 60))

        let items = vm.buildDisplayItems(from: [e1, e2])
        #expect(items.count == 1)
        guard case .group(let events, let m) = items[0] else {
            Issue.record("Expected .group, got \(items[0])")
            return
        }
        #expect(events.count == 2)
        #expect(m == "Platinum-Palladium")
    }

    @MainActor @Test
    func testEmptyFeedShowsPlaceholder() throws {
        // buildDisplayItems([]) must return an empty array (view shows placeholder)
        let vm = try makeVM()
        #expect(vm.buildDisplayItems(from: []).isEmpty)
    }
}
