import SwiftUI

/// Settings section showing API call history and cost tracking.
/// Displays 2-3 summary cards at top + a scrollable table ledger of all calls.
struct APIUsageView: View {
    let db: AppDatabase?

    @State private var logs: [APICallLog] = []
    @State private var totalCost: Double = 0
    @State private var totalCalls: Int = 0
    @State private var totalInputTokens: Int = 0
    @State private var totalOutputTokens: Int = 0
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Summary cards
            summaryCards

            Divider()

            // Log table
            logTable
        }
        .task {
            guard !loaded, let db else { return }
            loaded = true
            await loadData(db: db)
        }
    }

    // MARK: - Summary Cards

    private var summaryCards: some View {
        HStack(spacing: 12) {
            summaryCard(
                title: "Total Spend",
                value: String(format: "$%.4f", totalCost),
                subtitle: "\(totalCalls) API calls",
                icon: "dollarsign.circle.fill",
                color: .green
            )

            summaryCard(
                title: "Tokens Used",
                value: formatTokenCount(totalInputTokens + totalOutputTokens),
                subtitle: "\(formatTokenCount(totalInputTokens)) in · \(formatTokenCount(totalOutputTokens)) out",
                icon: "arrow.left.arrow.right.circle.fill",
                color: .blue
            )

            if let avgCost = totalCalls > 0 ? totalCost / Double(totalCalls) : nil {
                summaryCard(
                    title: "Avg per Call",
                    value: String(format: "$%.4f", avgCost),
                    subtitle: "across \(totalCalls) calls",
                    icon: "chart.bar.fill",
                    color: .purple
                )
            }
        }
    }

    private func summaryCard(title: String, value: String, subtitle: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(.primary)

            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(color.opacity(0.15), lineWidth: 1)
                )
        )
    }

    // MARK: - Log Table

    private var logTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Call Log")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            if logs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No API calls logged yet")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                // Table header
                HStack(spacing: 0) {
                    Text("Time")
                        .frame(width: 70, alignment: .leading)
                    Text("Label")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Model")
                        .frame(width: 80, alignment: .leading)
                    Text("Tokens")
                        .frame(width: 80, alignment: .trailing)
                    Text("Latency")
                        .frame(width: 60, alignment: .trailing)
                    Text("Cost")
                        .frame(width: 70, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(logs) { log in
                            logRow(log)
                            Divider().padding(.leading, 10)
                        }
                    }
                }
            }
        }
    }

    private func logRow(_ log: APICallLog) -> some View {
        HStack(spacing: 0) {
            Text(log.calledAt, format: .dateTime.hour().minute())
                .frame(width: 70, alignment: .leading)

            Text(log.label)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(shortModelName(log.model))
                .frame(width: 80, alignment: .leading)
                .foregroundStyle(.secondary)

            Text("\(log.inputTokens + log.outputTokens)")
                .frame(width: 80, alignment: .trailing)
                .foregroundStyle(.secondary)

            Text("\(log.durationMs)ms")
                .frame(width: 60, alignment: .trailing)
                .foregroundStyle(.tertiary)

            Text(String(format: "$%.4f", log.estimatedCostUSD))
                .frame(width: 70, alignment: .trailing)
                .foregroundStyle(log.estimatedCostUSD > 0.01 ? .orange : .secondary)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    private func loadData(db: AppDatabase) async {
        let repo = APICallLogRepository(db: db)
        logs = (try? await repo.fetchRecent(limit: 200)) ?? []
        let summary = (try? await repo.summary()) ?? (0.0, 0, 0, 0)
        totalCost = summary.0
        totalCalls = summary.1
        totalInputTokens = summary.2
        totalOutputTokens = summary.3
    }

    private func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    private func shortModelName(_ model: String) -> String {
        if model.contains("haiku") { return "Haiku" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("opus") { return "Opus" }
        return model.prefix(12).description
    }
}
