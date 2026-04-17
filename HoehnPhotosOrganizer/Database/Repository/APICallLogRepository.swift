import Foundation
import GRDB

actor APICallLogRepository {
    private let db: AppDatabase

    init(db: AppDatabase) {
        self.db = db
    }

    func insert(_ log: APICallLog) async throws {
        try await db.dbPool.write { db in
            try log.insert(db)
        }
    }

    func fetchRecent(limit: Int = 100) async throws -> [APICallLog] {
        try await db.dbPool.read { db in
            try APICallLog
                .order(Column("called_at").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Summary stats: total cost, total calls, total tokens.
    func summary() async throws -> (totalCost: Double, totalCalls: Int, totalInputTokens: Int, totalOutputTokens: Int) {
        try await db.dbPool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT
                    COALESCE(SUM(estimated_cost_usd), 0) as total_cost,
                    COUNT(*) as total_calls,
                    COALESCE(SUM(input_tokens), 0) as total_input,
                    COALESCE(SUM(output_tokens), 0) as total_output
                FROM api_call_logs
                """)
            let cost: Double = row?["total_cost"] ?? 0
            let calls: Int = row?["total_calls"] ?? 0
            let input: Int = row?["total_input"] ?? 0
            let output: Int = row?["total_output"] ?? 0
            return (cost, calls, input, output)
        }
    }

    /// Per-day cost breakdown for the last 30 days.
    func dailyCosts(days: Int = 30) async throws -> [(date: String, cost: Double, calls: Int)] {
        try await db.dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    DATE(called_at) as day,
                    SUM(estimated_cost_usd) as cost,
                    COUNT(*) as calls
                FROM api_call_logs
                WHERE called_at >= DATE('now', '-\(days) days')
                GROUP BY DATE(called_at)
                ORDER BY day DESC
                """)
            return rows.map { row in
                let day: String = row["day"]
                let cost: Double = row["cost"]
                let calls: Int = row["calls"]
                return (day, cost, calls)
            }
        }
    }
}
