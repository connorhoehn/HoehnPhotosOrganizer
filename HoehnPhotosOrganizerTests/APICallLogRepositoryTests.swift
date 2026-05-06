import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

final class APICallLogRepositoryTests: XCTestCase {

    var db: AppDatabase!
    var repo: APICallLogRepository!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        repo = APICallLogRepository(db: db)
    }

    private func makeLog(
        id: String,
        label: String,
        inputTokens: Int = 100,
        outputTokens: Int = 50,
        costUSD: Double = 0.01,
        calledAt: Date = .now
    ) -> APICallLog {
        APICallLog(
            id: id,
            model: "claude-haiku-4-5-20251001",
            label: label,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            estimatedCostUSD: costUSD,
            durationMs: 250,
            calledAt: calledAt
        )
    }

    // MARK: - insert + fetchRecent order

    func testInsertAndFetchRecentReturnsNewestFirst() async throws {
        let base = Date(timeIntervalSinceNow: -3600)
        try await repo.insert(makeLog(id: "a", label: "first",  calledAt: base.addingTimeInterval(0)))
        try await repo.insert(makeLog(id: "b", label: "second", calledAt: base.addingTimeInterval(60)))
        try await repo.insert(makeLog(id: "c", label: "third",  calledAt: base.addingTimeInterval(120)))

        let results = try await repo.fetchRecent(limit: 10)
        XCTAssertEqual(results.map(\.id), ["c", "b", "a"],
                       "fetchRecent must return logs ordered newest-first by called_at")
    }

    // MARK: - fetchRecent limit

    func testFetchRecentRespectsLimit() async throws {
        for i in 1...5 {
            try await repo.insert(makeLog(id: "log-\(i)", label: "call-\(i)"))
        }
        let results = try await repo.fetchRecent(limit: 2)
        XCTAssertEqual(results.count, 2, "fetchRecent must return at most `limit` records")
    }

    // MARK: - summary on empty table

    func testSummaryReturnsZeroTotalsForEmptyTable() async throws {
        let (cost, calls, input, output) = try await repo.summary()
        XCTAssertEqual(cost, 0.0)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(input, 0)
        XCTAssertEqual(output, 0)
    }

    // MARK: - summary aggregates correctly

    func testSummaryAggregatesAllLogs() async throws {
        try await repo.insert(makeLog(id: "s1", label: "A", inputTokens: 200, outputTokens: 100, costUSD: 0.02))
        try await repo.insert(makeLog(id: "s2", label: "B", inputTokens: 300, outputTokens: 150, costUSD: 0.03))

        let (cost, calls, input, output) = try await repo.summary()
        XCTAssertEqual(calls, 2, "summary must count both inserted logs")
        XCTAssertEqual(input, 500, "summary must sum input_tokens across all logs")
        XCTAssertEqual(output, 250, "summary must sum output_tokens across all logs")
        XCTAssertEqual(cost, 0.05, accuracy: 1e-9, "summary must sum estimated_cost_usd across all logs")
    }

    // MARK: - dailyCosts groups by date

    func testDailyCostsGroupsCallsByDay() async throws {
        // Insert two calls for today
        try await repo.insert(makeLog(id: "d1", label: "X", costUSD: 0.01, calledAt: .now))
        try await repo.insert(makeLog(id: "d2", label: "Y", costUSD: 0.02, calledAt: .now))

        let breakdown = try await repo.dailyCosts(days: 30)
        XCTAssertEqual(breakdown.count, 1, "Two calls on the same day must produce one daily bucket")
        XCTAssertEqual(breakdown.first?.calls, 2)
        XCTAssertEqual(breakdown.first?.cost ?? 0, 0.03, accuracy: 1e-9)
    }
}
