import Foundation

/// Centralized API usage logger. Persists every Anthropic API call to the database
/// for cost tracking in Settings > API Usage.
actor APIUsageLogger {
    static let shared = APIUsageLogger()

    private var db: AppDatabase?

    func configure(db: AppDatabase) {
        self.db = db
        print("[APIUsageLogger] configured with database")
    }

    /// Log a completed API call. Call this after every successful Anthropic API response.
    func log(
        model: String,
        label: String,
        inputTokens: Int,
        outputTokens: Int,
        durationMs: Int
    ) {
        guard let db else {
            print("[APIUsageLogger] db not configured — dropping log for \(label)")
            return
        }
        let cost = Self.estimateCost(model: model, input: inputTokens, output: outputTokens)
        let entry = APICallLog(
            id: UUID().uuidString,
            model: model,
            label: label,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            estimatedCostUSD: cost,
            durationMs: durationMs,
            calledAt: Date()
        )
        Task {
            do {
                let repo = APICallLogRepository(db: db)
                try await repo.insert(entry)
                print("[APIUsageLogger] logged \(label) — $\(String(format: "%.4f", cost))")
            } catch {
                print("[APIUsageLogger] insert failed: \(error)")
            }
        }
    }

    /// Estimate USD cost based on model pricing.
    static func estimateCost(model: String, input: Int, output: Int) -> Double {
        // Pricing per 1M tokens (as of 2025)
        let (inputRate, outputRate): (Double, Double) = {
            if model.contains("haiku") {
                return (1.0, 5.0)
            } else if model.contains("sonnet") {
                return (3.0, 15.0)
            } else if model.contains("opus") {
                return (15.0, 75.0)
            } else {
                return (1.0, 5.0) // default to haiku pricing
            }
        }()
        return (Double(input) / 1_000_000 * inputRate) + (Double(output) / 1_000_000 * outputRate)
    }
}
