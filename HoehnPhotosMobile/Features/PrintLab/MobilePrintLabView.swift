import SwiftUI
import HoehnPhotosCore
import GRDB

// MARK: - PrintTypeInfo

struct PrintTypeInfo {
    let rawValue: String
    let displayName: String
    let icon: String

    static let all: [PrintTypeInfo] = [
        PrintTypeInfo(rawValue: "inkjet_color", displayName: "Inkjet (Color)", icon: "printer"),
        PrintTypeInfo(rawValue: "inkjet_bw", displayName: "Inkjet (B&W)", icon: "printer"),
        PrintTypeInfo(rawValue: "silver_gelatin_darkroom", displayName: "Silver Gelatin", icon: "moon.stars"),
        PrintTypeInfo(rawValue: "platinum_palladium", displayName: "Pt/Pd", icon: "sparkles"),
        PrintTypeInfo(rawValue: "cyanotype", displayName: "Cyanotype", icon: "drop"),
        PrintTypeInfo(rawValue: "digital_negative", displayName: "Digital Neg", icon: "film"),
    ]

    static func displayName(for rawValue: String) -> String {
        all.first { $0.rawValue == rawValue }?.displayName ?? rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func icon(for rawValue: String) -> String {
        all.first { $0.rawValue == rawValue }?.icon ?? "printer"
    }
}

// MARK: - MobilePrintLabView

struct MobilePrintLabView: View {

    @Environment(\.appDatabase) private var appDatabase
    @State private var allAttempts: [MobilePrintRepository.PrintAttemptSummary] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selectedType: String?
    @State private var selectedAttempt: MobilePrintRepository.PrintAttemptSummary?

    private var filteredAttempts: [MobilePrintRepository.PrintAttemptSummary] {
        guard let type = selectedType else { return allAttempts }
        return allAttempts.filter { $0.printType == type }
    }

    private var groupedByDate: [(key: String, label: String, attempts: [MobilePrintRepository.PrintAttemptSummary])] {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none

        let isoFormatter = ISO8601DateFormatter()

        var groups: [(key: String, label: String, attempts: [MobilePrintRepository.PrintAttemptSummary])] = []
        var currentKey: String?
        var currentLabel: String?
        var currentAttempts: [MobilePrintRepository.PrintAttemptSummary] = []

        let keyFormatter = DateFormatter()
        keyFormatter.dateFormat = "yyyy-MM-dd"

        for attempt in filteredAttempts {
            let date = isoFormatter.date(from: attempt.createdAt) ?? Date()
            let key = keyFormatter.string(from: date)
            let label = Self.relativeLabel(for: date, formatter: dateFormatter)

            if key != currentKey {
                if let k = currentKey, let l = currentLabel {
                    groups.append((key: k, label: l, attempts: currentAttempts))
                }
                currentKey = key
                currentLabel = label
                currentAttempts = [attempt]
            } else {
                currentAttempts.append(attempt)
            }
        }
        if let k = currentKey, let l = currentLabel {
            groups.append((key: k, label: l, attempts: currentAttempts))
        }
        return groups
    }

    private var availableTypes: [String] {
        Array(Set(allAttempts.map(\.printType))).sorted()
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = loadError {
                VStack(spacing: HPSpacing.base) {
                    ErrorBanner(message: err) {
                        Task { await loadAttempts() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if allAttempts.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    typeFilterChips
                    attemptList
                }
            }
        }
        .task { await loadAttempts() }
        .sheet(item: $selectedAttempt) { attempt in
            MobilePrintDetailView(attempt: attempt)
        }
    }

    // MARK: - Filter Chips

    private var typeFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HPSpacing.sm) {
                filterChip(
                    label: "All",
                    icon: "printer",
                    isSelected: selectedType == nil,
                    count: allAttempts.count
                ) {
                    withAnimation(HPAnimation.chipSpring) {
                        selectedType = nil
                    }
                }

                ForEach(availableTypes, id: \.self) { type in
                    let count = allAttempts.filter { $0.printType == type }.count
                    filterChip(
                        label: PrintTypeInfo.displayName(for: type),
                        icon: PrintTypeInfo.icon(for: type),
                        isSelected: selectedType == type,
                        count: count
                    ) {
                        withAnimation(HPAnimation.chipSpring) {
                            selectedType = (selectedType == type) ? nil : type
                        }
                    }
                }
            }
            .padding(.horizontal, HPSpacing.base)
            .padding(.vertical, HPSpacing.sm)
        }
    }

    private func filterChip(
        label: String,
        icon: String,
        isSelected: Bool,
        count: Int,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: HPSpacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(HPFont.cardSubtitle)
                Text("\(count)")
                    .font(HPFont.metaLabel)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
            .padding(.horizontal, HPSpacing.md - 2)
            .padding(.vertical, HPSpacing.md - 2)
            .background(isSelected ? HPColor.chipActive : HPColor.chipInactive)
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
            .animation(HPAnimation.chipSpring, value: isSelected)
        }
        .buttonStyle(.plain)
    }

    // MARK: - List

    private var attemptList: some View {
        List {
            ForEach(groupedByDate, id: \.key) { group in
                Section(group.label) {
                    ForEach(group.attempts) { attempt in
                        PrintAttemptRow(attempt: attempt)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedAttempt = attempt
                            }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await loadAttempts()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        EmptyStateView(
            icon: "printer",
            title: "No Print Attempts",
            message: "Log print attempts on your Mac, then sync to see them here."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private static func relativeLabel(for date: Date, formatter: DateFormatter) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return formatter.string(from: date)
    }

    private func loadAttempts() async {
        guard let db = appDatabase else {
            isLoading = false
            return
        }
        do {
            allAttempts = try await MobilePrintRepository(db: db).fetchAll()
        } catch {
            loadError = error.localizedDescription
            print("[PrintLab] Load error: \(error)")
        }
        isLoading = false
    }
}

// MARK: - PrintAttemptRow

struct PrintAttemptRow: View {
    let attempt: MobilePrintRepository.PrintAttemptSummary

    /// Subtitle combining paper and optional template / ICC info.
    private var subtitle: String {
        var parts = [attempt.paper]
        if let template = attempt.calibrationTemplate, !template.isEmpty {
            parts.append(template)
        } else if let icc = attempt.iccProfileName, !icc.isEmpty {
            parts.append(icc)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: HPSpacing.md) {
            Image(systemName: PrintTypeInfo.icon(for: attempt.printType))
                .font(.system(size: 16))
                .frame(width: 36, height: 36)
                .background(HPColor.elevatedBackground)
                .clipShape(RoundedRectangle(cornerRadius: HPRadius.small))

            VStack(alignment: .leading, spacing: HPSpacing.xxs) {
                Text(PrintTypeInfo.displayName(for: attempt.printType))
                    .font(HPFont.bodyStrong)
                Text(subtitle)
                    .font(HPFont.cardSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            outcomeBadge(attempt.outcome)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(PrintTypeInfo.displayName(for: attempt.printType)), \(subtitle), \(outcomeDisplay(attempt.outcome).0)")
        .accessibilityAddTraits(.isButton)
    }

    private func outcomeBadge(_ outcome: String) -> some View {
        let (label, color) = outcomeDisplay(outcome)
        return Text(label)
            .font(HPFont.badgeLabel)
            .padding(.horizontal, HPSpacing.sm)
            .padding(.vertical, HPSpacing.xs - 1)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private func outcomeDisplay(_ outcome: String) -> (String, Color) {
        switch outcome {
        case "pass":             return ("Pass", .green)
        case "fail":             return ("Fail", .red)
        case "needs_adjustment": return ("Adjust", .orange)
        case "testing":          return ("Testing", .blue)
        default:                 return (outcome.capitalized, .secondary)
        }
    }
}
