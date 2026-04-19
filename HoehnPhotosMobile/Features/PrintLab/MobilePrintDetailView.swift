import SwiftUI
import HoehnPhotosCore
import GRDB

struct MobilePrintDetailView: View {
    let attempt: MobilePrintRepository.PrintAttemptSummary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDatabase) private var appDatabase
    @State private var sourcePhoto: PhotoAsset?
    @State private var extendedFields: [String: String] = [:]

    var body: some View {
        NavigationStack {
            List {
                // MARK: Source Photo Section
                if let photo = sourcePhoto {
                    Section("Source Photo") {
                        HStack(spacing: HPSpacing.md) {
                            ProxyImageView(canonicalName: photo.canonicalName)
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: HPRadius.small))
                            VStack(alignment: .leading, spacing: HPSpacing.xxs) {
                                Text(photo.canonicalName)
                                    .font(HPFont.bodyStrong)
                                if let date = photo.dateModified ?? photo.createdAt as String? {
                                    Text(date)
                                        .font(HPFont.timestamp)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                // MARK: Configuration Section
                Section("Configuration") {
                    LabelValueRow(icon: PrintTypeInfo.icon(for: attempt.printType),
                                label: "Type",
                                value: PrintTypeInfo.displayName(for: attempt.printType))
                    LabelValueRow(icon: "doc.plaintext", label: "Paper", value: attempt.paper)

                    if let icc = extendedFields["icc_profile_name"], !icc.isEmpty {
                        LabelValueRow(icon: "paintpalette", label: "ICC Profile", value: icc)
                    }
                    if let intent = extendedFields["rendering_intent"], !intent.isEmpty {
                        LabelValueRow(icon: "slider.horizontal.3", label: "Rendering Intent", value: intent.capitalized)
                    }
                    if let curve = extendedFields["qtr_curve_name"], !curve.isEmpty {
                        LabelValueRow(icon: "chart.line.uptrend.xyaxis", label: "QTR Curve", value: curve)
                    }
                    if let res = extendedFields["qtr_resolution"], !res.isEmpty {
                        LabelValueRow(icon: "viewfinder", label: "Resolution", value: res)
                    }
                }

                // MARK: Outcome Section
                Section("Outcome") {
                    HStack {
                        Text("Result")
                            .font(HPFont.body)
                        Spacer()
                        outcomeBadge(attempt.outcome)
                    }
                    if !attempt.outcomeNotes.isEmpty {
                        VStack(alignment: .leading, spacing: HPSpacing.xs) {
                            Text("Notes")
                                .font(HPFont.metaLabel)
                                .foregroundStyle(.secondary)
                            Text(attempt.outcomeNotes)
                                .font(HPFont.body)
                        }
                    }
                }

                // MARK: Metadata
                Section("Metadata") {
                    LabelValueRow(icon: "calendar", label: "Date", value: formattedDate(attempt.createdAt))
                    LabelValueRow(icon: "number", label: "ID", value: String(attempt.id.prefix(8)) + "...")
                }
            }
            .navigationTitle("Print Attempt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await loadSourcePhoto()
                await loadExtendedFields()
            }
        }
    }

    // MARK: - Helpers

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
        case "needs_adjustment": return ("Needs Adjustment", .orange)
        case "testing":          return ("Testing", .blue)
        default:                 return (outcome.capitalized, .secondary)
        }
    }

    private func formattedDate(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: isoString) {
            let display = DateFormatter()
            display.dateStyle = .long
            display.timeStyle = .short
            return display.string(from: date)
        }
        return isoString
    }

    private func loadSourcePhoto() async {
        guard let db = appDatabase else { return }
        do {
            sourcePhoto = try await MobilePhotoRepository(db: db).fetchById(attempt.photoId)
        } catch {
            print("[PrintDetail] Source photo load error: \(error)")
        }
    }

    /// Load extended fields from the thread_entries content_json for this print attempt.
    private func loadExtendedFields() async {
        guard let db = appDatabase else { return }
        do {
            let fields = try await Self.fetchExtendedFields(db: db, attemptId: attempt.id)
            extendedFields = fields
        } catch {
            print("[PrintDetail] Extended fields load error: \(error)")
        }
    }

    /// Fetches extended print attempt fields from thread_entries content_json.
    private static func fetchExtendedFields(db: AppDatabase, attemptId: String) async throws -> [String: String] {
        let row: Row? = try await db.dbPool.read { conn in
            return try Row.fetchOne(conn, sql: """
                SELECT content_json FROM thread_entries WHERE id = ?
            """, arguments: [attemptId])
        }
        guard let jsonStr = row?["content_json"] as? String,
              let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }

        var fields: [String: String] = [:]
        for (key, value) in json {
            if let str = value as? String {
                fields[key] = str
            }
        }
        return fields
    }
}
