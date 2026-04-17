# Session 10: PrintLab History + Detail

## Goal
Build `MobilePrintLabView` showing print attempts grouped by date with type filter chips, plus `MobilePrintDetailView` for config/outcome/notes. Remove the "View Only" section from Settings.

---

## Key Files

| File | Role |
|------|------|
| `HoehnPhotosCore/Database/Repository/MobileRepositories.swift` | `MobilePrintRepository` (added in session 8) |
| `HoehnPhotosMobile/Features/Creative/MobileCreativeView.swift` | Parent container (session 8) |
| `HoehnPhotosMobile/Features/Settings/MobileSettingsView.swift` | Remove "View Only" section |
| `HoehnPhotosOrganizer/Models/PrintType.swift` | `PrintType` + `PrintOutcome` enums (Mac target) |
| `HoehnPhotosOrganizer/Models/PrintAttempt.swift` | Full PrintAttempt model (Mac target, reference only) |

---

## How Print Data Is Stored

**Critical:** There is NO `print_attempts` table. Print attempts are stored in the `thread_entries` table with `kind = 'print_attempt'`. The actual print data is JSON-encoded in the `content_json` column.

The `MobilePrintRepository` (from session 8) handles the JSON decoding and returns `PrintAttemptSummary` structs.

### PrintAttemptSummary (from MobileRepositories.swift)

```swift
public struct PrintAttemptSummary: Identifiable, Sendable {
    public let id: String              // thread_entry.id
    public let photoId: String         // thread_root_id (FK to photo_assets)
    public let printType: String       // raw value: "inkjet_color", "platinum_palladium", etc.
    public let paper: String           // paper name
    public let outcome: String         // "pass", "fail", "needs_adjustment", "testing"
    public let outcomeNotes: String    // user notes
    public let createdAt: String       // ISO 8601
}
```

---

## PrintType Enum (Mac target -- reference for display names and icons)

```swift
enum PrintType: String, CaseIterable, Identifiable, Codable {
    case inkjetColor = "inkjet_color"
    case inkjetBW = "inkjet_bw"
    case silverGelatinDarkroom = "silver_gelatin_darkroom"
    case platinumPalladium = "platinum_palladium"
    case cyanotype
    case digitalNegative = "digital_negative"
}
```

These enums live in the Mac target only. On iOS, use string matching for filter chips. Create a helper for display names and icons:

```swift
// Put in MobilePrintLabView.swift or a shared helpers file

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
```

### PrintOutcome values
- `"pass"` -- display: "Pass", color: green
- `"fail"` -- display: "Fail", color: red
- `"needs_adjustment"` -- display: "Needs Adjustment", color: orange
- `"testing"` -- display: "Testing", color: blue

---

## MobilePrintLabView

New file: `HoehnPhotosMobile/Features/Creative/MobilePrintLabView.swift`

List of print attempts grouped by date, with type filter chips.

```swift
import SwiftUI
import HoehnPhotosCore

struct MobilePrintLabView: View {

    @Environment(\.appDatabase) private var appDatabase
    @State private var allAttempts: [MobilePrintRepository.PrintAttemptSummary] = []
    @State private var isLoading = true
    @State private var selectedType: String?  // nil = "All", otherwise PrintType raw value
    @State private var selectedAttempt: MobilePrintRepository.PrintAttemptSummary?

    private var filteredAttempts: [MobilePrintRepository.PrintAttemptSummary] {
        guard let type = selectedType else { return allAttempts }
        return allAttempts.filter { $0.printType == type }
    }

    /// Group filtered attempts by date (day granularity).
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
            let label = dateFormatter.string(from: date)

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

    /// Print types that have at least one attempt.
    private var availableTypes: [String] {
        Array(Set(allAttempts.map(\.printType))).sorted()
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
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
            HStack(spacing: 8) {
                FilterChip(
                    label: "All",
                    icon: "printer",
                    isSelected: selectedType == nil,
                    count: allAttempts.count
                ) {
                    selectedType = nil
                }

                ForEach(availableTypes, id: \.self) { type in
                    let count = allAttempts.filter { $0.printType == type }.count
                    FilterChip(
                        label: PrintTypeInfo.displayName(for: type),
                        icon: PrintTypeInfo.icon(for: type),
                        isSelected: selectedType == type,
                        count: count
                    ) {
                        selectedType = (selectedType == type) ? nil : type
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
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
        VStack(spacing: 16) {
            Image(systemName: "printer")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No Print Attempts")
                .font(.title3.weight(.semibold))
            Text("Log print attempts on your Mac, then sync to see them here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading

    private func loadAttempts() async {
        guard let db = appDatabase else {
            isLoading = false
            return
        }
        do {
            allAttempts = try await MobilePrintRepository(db: db).fetchAll()
        } catch {
            print("[PrintLab] Load error: \(error)")
        }
        isLoading = false
    }
}
```

---

## PrintAttemptRow

```swift
struct PrintAttemptRow: View {
    let attempt: MobilePrintRepository.PrintAttemptSummary

    var body: some View {
        HStack(spacing: 12) {
            // Type icon
            Image(systemName: PrintTypeInfo.icon(for: attempt.printType))
                .font(.system(size: 16))
                .frame(width: 36, height: 36)
                .background(Color(uiColor: .tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(PrintTypeInfo.displayName(for: attempt.printType))
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    Text(attempt.paper)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Outcome badge
            outcomeBadge(attempt.outcome)
        }
    }

    private func outcomeBadge(_ outcome: String) -> some View {
        let (label, color) = outcomeDisplay(outcome)
        return Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
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
```

---

## MobilePrintDetailView

New file: `HoehnPhotosMobile/Features/Creative/MobilePrintDetailView.swift`

Shows configuration, outcome, and notes for a print attempt. Since `PrintAttemptSummary` only has basic fields, this view can optionally reload the full `content_json` for extended details.

```swift
import SwiftUI
import HoehnPhotosCore

struct MobilePrintDetailView: View {
    let attempt: MobilePrintRepository.PrintAttemptSummary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDatabase) private var appDatabase
    @State private var sourcePhoto: PhotoAsset?
    @State private var extendedFields: [String: Any] = [:]

    var body: some View {
        NavigationStack {
            List {
                // MARK: Configuration Section
                Section("Configuration") {
                    detailRow("Type", value: PrintTypeInfo.displayName(for: attempt.printType),
                              icon: PrintTypeInfo.icon(for: attempt.printType))
                    detailRow("Paper", value: attempt.paper, icon: "doc.plaintext")

                    // Extended fields from content_json (loaded async)
                    if let icc = extendedFields["icc_profile_name"] as? String, !icc.isEmpty {
                        detailRow("ICC Profile", value: icc, icon: "paintpalette")
                    }
                    if let intent = extendedFields["rendering_intent"] as? String, !intent.isEmpty {
                        detailRow("Rendering Intent", value: intent.capitalized, icon: "slider.horizontal.3")
                    }
                    if let curve = extendedFields["qtr_curve_name"] as? String, !curve.isEmpty {
                        detailRow("QTR Curve", value: curve, icon: "chart.line.uptrend.xyaxis")
                    }
                    if let res = extendedFields["qtr_resolution"] as? String, !res.isEmpty {
                        detailRow("Resolution", value: res, icon: "viewfinder")
                    }
                }

                // MARK: Outcome Section
                Section("Outcome") {
                    HStack {
                        Text("Result")
                        Spacer()
                        outcomeBadge(attempt.outcome)
                    }
                    if !attempt.outcomeNotes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Notes")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(attempt.outcomeNotes)
                                .font(.subheadline)
                        }
                    }
                }

                // MARK: Source Photo Section
                if let photo = sourcePhoto {
                    Section("Source Photo") {
                        HStack(spacing: 12) {
                            Image(systemName: "photo")
                                .font(.system(size: 20))
                                .frame(width: 36, height: 36)
                                .background(Color(uiColor: .tertiarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(photo.canonicalName ?? "Untitled")
                                    .font(.subheadline.weight(.medium))
                                if let date = photo.dateModified ?? photo.createdAt as String? {
                                    Text(date)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                // MARK: Metadata
                Section("Metadata") {
                    detailRow("Date", value: formattedDate(attempt.createdAt), icon: "calendar")
                    detailRow("ID", value: String(attempt.id.prefix(8)) + "...", icon: "number")
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

    private func detailRow(_ label: String, value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
        }
    }

    private func outcomeBadge(_ outcome: String) -> some View {
        let (label, color) = outcomeDisplay(outcome)
        return Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
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

    /// Reload the full content_json from thread_entries for extended fields.
    private func loadExtendedFields() async {
        guard let db = appDatabase else { return }
        do {
            let row = try await db.dbPool.read { conn in
                try Row.fetchOne(conn, sql: """
                    SELECT content_json FROM thread_entries WHERE id = ?
                """, arguments: [attempt.id])
            }
            if let jsonStr = row?["content_json"] as? String,
               let data = jsonStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                extendedFields = json
            }
        } catch {
            print("[PrintDetail] Extended fields load error: \(error)")
        }
    }
}
```

---

## MobilePrintRepository.PrintAttemptSummary Identifiable Conformance

Make sure the `PrintAttemptSummary` nested struct in `MobilePrintRepository` conforms to `Identifiable` (it should from session 8), and also add `Hashable` for use with `.sheet(item:)`:

```swift
public struct PrintAttemptSummary: Identifiable, Sendable, Hashable {
    public let id: String
    public let photoId: String
    public let printType: String
    public let paper: String
    public let outcome: String
    public let outcomeNotes: String
    public let createdAt: String
}
```

---

## Changes to MobileSettingsView

Remove the "View Only" section entirely. The Studio and Print Lab content are now in the Creative tab.

In `HoehnPhotosMobile/Features/Settings/MobileSettingsView.swift`, delete:

```swift
// DELETE THIS ENTIRE SECTION:
Section("View Only") {
    NavigationLink {
        PrintLabPreviewView()
    } label: {
        Label("Print Lab", systemImage: "printer")
    }
    NavigationLink {
        StudioPreviewView()
    } label: {
        Label("Studio", systemImage: "paintbrush")
    }
}
```

Optionally add Activity to Settings (if relocated from session 8):

```swift
Section("History") {
    NavigationLink {
        MobileActivityView()
    } label: {
        Label("Activity", systemImage: "clock")
    }
}
```

Also remove or keep `PrintLabPreviewView` and `StudioPreviewView` structs at the bottom of the file. If removed, make sure no other code references them. They are `private` scope so safe to delete.

### Final MobileSettingsView Structure

```swift
struct MobileSettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Sync") {
                    NavigationLink {
                        MobileSyncView()
                    } label: {
                        Label("Sync from Mac", systemImage: "desktopcomputer")
                    }
                }

                Section("History") {
                    NavigationLink {
                        MobileActivityView()
                    } label: {
                        Label("Activity", systemImage: "clock")
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
```

---

## File Organization

After session 10, the Creative feature folder should contain:

```
HoehnPhotosMobile/Features/
  Creative/
    MobileCreativeView.swift          (session 8)
    MobileStudioGalleryView.swift     (session 9)
    MobileStudioDetailView.swift      (session 9)
    MobilePrintLabView.swift          (this session -- includes PrintAttemptRow, PrintTypeInfo)
    MobilePrintDetailView.swift       (this session)
    FilterChip.swift                  (session 9, shared)
```

---

## Verification Checklist

- [ ] Print Lab tab in Creative shows list of print attempts grouped by date
- [ ] Type filter chips appear only for types with data
- [ ] Tapping a chip filters; re-tapping deselects back to "All"
- [ ] Outcome badges show correct colors (green/red/orange/blue)
- [ ] Tapping a row opens detail sheet
- [ ] Detail shows config section (type, paper, ICC, QTR curve, resolution)
- [ ] Detail shows outcome section (result badge + notes)
- [ ] Detail shows source photo name if available
- [ ] Pull-to-refresh reloads the list
- [ ] Empty state shows when no print attempts exist
- [ ] "View Only" section removed from Settings
- [ ] Activity link added to Settings (if relocated)
- [ ] No compile errors from removed Settings preview views
