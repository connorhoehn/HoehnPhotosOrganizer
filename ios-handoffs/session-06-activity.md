# Session 6: Activity Feed Polish

## Goal
Add horizontal filter chips, relative timestamps, tappable event rows with a detail sheet, and per-filter empty states to `MobileActivityView`.

---

## Key Files

| File | Role |
|------|------|
| `HoehnPhotosMobile/Features/Activity/MobileActivityView.swift` | Main view to modify |
| `HoehnPhotosCore/Models/ActivityEvent.swift` | Shared model (18 kinds -- see note below) |
| `HoehnPhotosCore/Database/Repository/MobileRepositories.swift` | `MobileActivityRepository` |
| `HoehnPhotosOrganizer/Features/ActivityFeed/ActivityFeedView.swift` | Mac reference for filter bar, empty states |
| `HoehnPhotosOrganizer/Features/ActivityFeed/EventDetailSheet.swift` | Mac reference for detail view (`EventDetailView`) |

---

## ActivityEvent Model (HoehnPhotosCore)

The shared `ActivityEventKind` enum currently has 18 cases. The Mac app defines a **separate, extended** copy at `HoehnPhotosOrganizer/Models/ActivityEvent.swift` with 11 additional kinds (studio, job, curve, version). The mobile `sfSymbol(for:)` switch only handles the original 18. When filtering, only use kinds that exist in the HoehnPhotosCore enum to avoid compile errors. If studio/job/curve kinds are needed on mobile, they must first be added to the shared package.

### Shared ActivityEvent Fields
```swift
public struct ActivityEvent: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public var id: String               // UUID string
    public var kind: ActivityEventKind
    public var parentEventId: String?   // nil = root event
    public var photoAssetId: String?    // associated photo (optional)
    public var title: String
    public var detail: String?
    public var metadata: String?        // JSON blob for kind-specific data
    public var occurredAt: Date
    public var createdAt: Date
    public var savedSearchRuleId: String?
}
```

### ActivityEventKind (HoehnPhotosCore -- 18 cases)
```swift
public enum ActivityEventKind: String, Codable, CaseIterable {
    case importBatch         = "import_batch"
    case frameExtraction     = "frame_extraction"
    case adjustment          = "adjustment"
    case colorGrade          = "color_grade"
    case printAttempt        = "print_attempt"
    case batchTransform      = "batch_transform"
    case reAdjustment        = "re_adjustment"
    case note                = "note"
    case todo                = "todo"
    case rollback            = "rollback"
    case pipelineRun         = "pipeline_run"
    case editorialReview     = "editorial_review"
    case faceDetection       = "face_detection"
    case metadataEnrichment  = "metadata_enrichment"
    case printJob            = "print_job"
    case scanAttachment      = "scan_attachment"
    case aiSummary           = "ai_summary"
    case search              = "search"
}
```

Each case has a `.filterLabel` property returning a human-readable string (e.g., `.importBatch` -> `"import"`).

---

## Current SF Symbol Mapping (MobileActivityView)

Copy this into any new views that need it, or refactor into a shared extension:

```swift
private func sfSymbol(for kind: ActivityEventKind) -> String {
    switch kind {
    case .importBatch:        return "square.and.arrow.down"
    case .frameExtraction:    return "film.stack"
    case .adjustment:         return "slider.horizontal.3"
    case .colorGrade:         return "paintpalette"
    case .printAttempt:       return "printer"
    case .batchTransform:     return "wand.and.stars"
    case .reAdjustment:       return "arrow.uturn.backward"
    case .note:               return "note.text"
    case .todo:               return "checklist"
    case .rollback:           return "arrow.uturn.backward.circle"
    case .pipelineRun:        return "gearshape.2"
    case .editorialReview:    return "text.bubble"
    case .faceDetection:      return "person.crop.rectangle"
    case .metadataEnrichment: return "tag"
    case .printJob:           return "printer.fill"
    case .scanAttachment:     return "doc.viewfinder"
    case .aiSummary:          return "brain"
    case .search:             return "magnifyingglass"
    }
}
```

---

## Existing Grouped Events Logic

The current view groups events by calendar day with "Today" / "Yesterday" pinned to the top:

```swift
private var groupedEvents: [(String, [ActivityEvent])] {
    let calendar = Calendar.current
    let grouped = Dictionary(grouping: events) { event -> String in
        if calendar.isDateInToday(event.occurredAt) { return "Today" }
        if calendar.isDateInYesterday(event.occurredAt) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: event.occurredAt)
    }
    return grouped.sorted { a, b in
        if a.key == "Today" { return true }
        if b.key == "Today" { return false }
        if a.key == "Yesterday" { return true }
        if b.key == "Yesterday" { return false }
        return a.key > b.key
    }
}
```

This should continue to work as-is; just feed it the **filtered** events instead of all events.

---

## MobileActivityRepository

Located in `HoehnPhotosCore/Database/Repository/MobileRepositories.swift` (line 198):

```swift
public actor MobileActivityRepository {
    public let db: AppDatabase
    public init(db: AppDatabase) { self.db = db }

    public func fetchRecent(limit: Int = 50) async throws -> [ActivityEvent] {
        try await db.dbPool.read { conn in
            try ActivityEvent
                .order(Column("created_at").desc)
                .limit(limit)
                .fetchAll(conn)
        }
    }
}
```

Filtering happens client-side after fetch (same pattern as the Mac app). No server-side kind filter needed.

---

## Implementation: Filter Chip Bar

### State to Add
```swift
@State private var kindFilter: Set<ActivityEventKind>? = nil  // nil = "All"
```

### Filter Chip Definitions

Use these 6 chips (scoped to the 18 kinds available in HoehnPhotosCore):

| Label | Kinds | Notes |
|-------|-------|-------|
| All | `nil` | No filter applied |
| Imports | `[.importBatch]` | |
| Studio | `[.pipelineRun]` | Only `pipelineRun` exists in shared package for studio-like work |
| Print | `[.printJob, .printAttempt]` | |
| Adjustments | `[.adjustment, .colorGrade, .reAdjustment]` | |
| Notes | `[.note]` | |

**Alternative**: If studio/job/curve kinds get added to HoehnPhotosCore before this session, expand Studio to `[.studioRender, .studioVersion, .studioExport, .studioPrintLab]` to match the Mac filter bar.

### Filtered Events Computed Property
```swift
private var filteredEvents: [ActivityEvent] {
    guard let filter = kindFilter else { return events }
    return events.filter { filter.contains($0.kind) }
}
```

Update `groupedEvents` to use `filteredEvents` instead of `events`.

### FilterChipBar Skeleton
```swift
private var filterChipBar: some View {
    ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
            filterChip(label: "All", kinds: nil)
            filterChip(label: "Imports", kinds: [.importBatch])
            filterChip(label: "Studio", kinds: [.pipelineRun])
            filterChip(label: "Print", kinds: [.printJob, .printAttempt])
            filterChip(label: "Adjustments", kinds: [.adjustment, .colorGrade, .reAdjustment])
            filterChip(label: "Notes", kinds: [.note])
        }
        .padding(.horizontal, 16)
    }
}

private func filterChip(label: String, kinds: Set<ActivityEventKind>?) -> some View {
    let isActive = kindFilter == kinds
    return Button {
        withAnimation(.easeInOut(duration: 0.15)) {
            kindFilter = kinds
        }
    } label: {
        Text(label)
            .font(.subheadline.weight(isActive ? .semibold : .medium))
            .foregroundStyle(isActive ? .white : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isActive ? Color.accentColor : Color(uiColor: .secondarySystemFill))
            )
    }
    .buttonStyle(.plain)
}
```

Place the `filterChipBar` between the navigation title and the List, or as the first item inside the List as a `listRowSeparator(.hidden)` row.

---

## Implementation: RelativeDateTimeFormatter

Replace the current timestamp line:
```swift
// BEFORE
Text(event.createdAt.formatted(date: .abbreviated, time: .shortened))
    .font(.caption2)
    .foregroundStyle(.tertiary)
```

With SwiftUI's built-in relative date style:
```swift
// AFTER
Text(event.occurredAt, style: .relative)
    .font(.caption2)
    .foregroundStyle(.tertiary)
```

This auto-updates ("2 min ago", "3 hours ago", etc.) without a timer. If you need a static snapshot instead of live-updating, use:

```swift
private static let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated  // "2 hr. ago" vs "2 hours ago"
    return f
}()

// Usage
Text(Self.relativeFormatter.localizedString(for: event.occurredAt, relativeTo: Date()))
```

The Mac detail view uses `Text(event.occurredAt, style: .relative)` -- prefer the same for consistency.

---

## Implementation: Tappable Events + MobileEventDetailView

### Make Rows Tappable

Add state for the selected event:
```swift
@State private var selectedEvent: ActivityEvent? = nil
```

Wrap each row in a `Button` or use `.onTapGesture`:
```swift
ForEach(sectionEvents) { event in
    Button {
        selectedEvent = event
    } label: {
        // ... existing HStack row content ...
    }
    .buttonStyle(.plain)
}
```

Present the detail sheet:
```swift
.sheet(item: $selectedEvent) { event in
    MobileEventDetailView(event: event)
}
```

### MobileEventDetailView Skeleton

Create new file: `HoehnPhotosMobile/Features/Activity/MobileEventDetailView.swift`

```swift
import SwiftUI
import HoehnPhotosCore

struct MobileEventDetailView: View {

    let event: ActivityEvent
    @Environment(\.dismiss) private var dismiss
    @State private var thumbnail: UIImage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // MARK: Header with icon + title
                    headerSection

                    // MARK: Photo thumbnail (if event has photoAssetId)
                    if thumbnail != nil {
                        photoSection
                    }

                    // MARK: Detail text
                    if let detail = event.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.body)
                            .foregroundStyle(.primary)
                    }

                    // MARK: Metadata table
                    if let metadata = parseMetadata(), !metadata.isEmpty {
                        metadataSection(metadata)
                    }

                    // MARK: Timestamps
                    timestampSection
                }
                .padding()
            }
            .navigationTitle("Event Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await loadThumbnail() }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 48, height: 48)
                Image(systemName: sfSymbol(for: event.kind))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.headline)
                Text(event.kind.filterLabel.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }

            Spacer()
        }
    }

    // MARK: - Photo

    @ViewBuilder
    private var photoSection: some View {
        if let img = thumbnail {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
                )
        }
    }

    // MARK: - Metadata

    @ViewBuilder
    private func metadataSection(_ json: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(json.keys.sorted(), id: \.self) { key in
                if let value = json[key] {
                    HStack(alignment: .top) {
                        Text(key.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .trailing)
                        Text(stringValue(value))
                            .font(.caption)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    // MARK: - Timestamps

    private var timestampSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(event.occurredAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(event.occurredAt, format: .dateTime.month().day().year().hour().minute())
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Helpers

    private func sfSymbol(for kind: ActivityEventKind) -> String {
        switch kind {
        case .importBatch:        return "square.and.arrow.down"
        case .frameExtraction:    return "film.stack"
        case .adjustment:         return "slider.horizontal.3"
        case .colorGrade:         return "paintpalette"
        case .printAttempt:       return "printer"
        case .batchTransform:     return "wand.and.stars"
        case .reAdjustment:       return "arrow.uturn.backward"
        case .note:               return "note.text"
        case .todo:               return "checklist"
        case .rollback:           return "arrow.uturn.backward.circle"
        case .pipelineRun:        return "gearshape.2"
        case .editorialReview:    return "text.bubble"
        case .faceDetection:      return "person.crop.rectangle"
        case .metadataEnrichment: return "tag"
        case .printJob:           return "printer.fill"
        case .scanAttachment:     return "doc.viewfinder"
        case .aiSummary:          return "brain"
        case .search:             return "magnifyingglass"
        }
    }

    private func parseMetadata() -> [String: Any]? {
        guard let metadata = event.metadata, !metadata.isEmpty,
              let data = metadata.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    private func stringValue(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let a = value as? [Any] { return a.map { "\($0)" }.joined(separator: ", ") }
        return "\(value)"
    }

    // MARK: - Thumbnail loading

    private func loadThumbnail() async {
        guard let photoId = event.photoAssetId else { return }
        // The photoAssetId is a UUID. We need the canonicalName to find the proxy.
        // If the event metadata contains canonical_name, use it.
        // Otherwise, look up the photo in the database.
        //
        // For now, attempt a direct proxy lookup using the photoId as filename stem:
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let proxyDir = appSupport
            .appendingPathComponent("HoehnPhotos")
            .appendingPathComponent("proxies")

        // Try metadata first for canonical_name
        var canonicalName: String? = nil
        if let meta = parseMetadata(), let name = meta["canonical_name"] as? String {
            canonicalName = name
        }

        if let name = canonicalName {
            let baseName = (name as NSString).deletingPathExtension
            let url = proxyDir.appendingPathComponent(baseName + ".jpg")
            if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                await MainActor.run { thumbnail = img }
            }
        }
        // If no canonical_name in metadata, the thumbnail will remain nil
        // and the photo section won't show. This is acceptable for v1.
    }
}
```

### Photo Thumbnail Pattern (from MobileLibraryView)

The established proxy URL pattern on iOS is:
```swift
let baseName = (photo.canonicalName as NSString).deletingPathExtension
let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
let proxyURL = appSupport
    .appendingPathComponent("HoehnPhotos")
    .appendingPathComponent("proxies")
    .appendingPathComponent(baseName + ".jpg")
```

The challenge: `ActivityEvent.photoAssetId` is a UUID, not a filename. You need the `canonicalName` from the `PhotoAsset` table. Options:
1. Check `event.metadata` for a `"canonical_name"` key (some events store it)
2. Add a lookup method to `MobileActivityRepository` that joins `activity_events` to `photo_assets` on `photoAssetId`
3. Accept that some events won't have thumbnails in v1

---

## Implementation: Per-Filter Empty States

When the list is empty and a filter is active, show a context-specific message. The Mac app pattern (from `ActivityFeedView.swift` line 450):

```swift
@ViewBuilder
private var filteredEmptyState: some View {
    let isFiltered = kindFilter != nil

    if isFiltered {
        VStack(spacing: 12) {
            Image(systemName: emptyStateIcon)
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(emptyStateTitle)
                .font(.headline)
            Text(emptyStateSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
```

### Suggested Empty State Text per Filter

| Filter | Icon | Title | Subtitle |
|--------|------|-------|----------|
| All (no events at all) | `clock` | No Activity | Import photos and work on jobs to see activity here. |
| Imports | `square.and.arrow.down` | No Imports | Imported photos will appear here. |
| Studio | `paintbrush.pointed` | No Studio Activity | Studio renders and exports will appear here. |
| Print | `printer` | No Print Activity | Print jobs and attempts will appear here. |
| Adjustments | `slider.horizontal.3` | No Adjustments | Edits and color grades will appear here. |
| Notes | `note.text` | No Notes | Add notes to photos to see them here. |

Compute based on `kindFilter`:
```swift
private var emptyStateIcon: String {
    guard let filter = kindFilter else { return "clock" }
    if filter.contains(.importBatch) { return "square.and.arrow.down" }
    if filter.contains(.pipelineRun) { return "paintbrush.pointed" }
    if filter.contains(.printJob)    { return "printer" }
    if filter.contains(.adjustment)  { return "slider.horizontal.3" }
    if filter.contains(.note)        { return "note.text" }
    return "tray"
}

private var emptyStateTitle: String {
    guard let filter = kindFilter else { return "No Activity" }
    if filter.contains(.importBatch) { return "No Imports" }
    if filter.contains(.pipelineRun) { return "No Studio Activity" }
    if filter.contains(.printJob)    { return "No Print Activity" }
    if filter.contains(.adjustment)  { return "No Adjustments" }
    if filter.contains(.note)        { return "No Notes" }
    return "No Events"
}

private var emptyStateSubtitle: String {
    guard let filter = kindFilter else { return "Import photos and work on jobs to see activity here." }
    if filter.contains(.importBatch) { return "Imported photos will appear here." }
    if filter.contains(.pipelineRun) { return "Studio renders and exports will appear here." }
    if filter.contains(.printJob)    { return "Print jobs and attempts will appear here." }
    if filter.contains(.adjustment)  { return "Edits and color grades will appear here." }
    if filter.contains(.note)        { return "Add notes to photos to see them here." }
    return "They will appear here as you work."
}
```

---

## Modification Summary for MobileActivityView.swift

1. **Add state**: `@State private var kindFilter: Set<ActivityEventKind>? = nil` and `@State private var selectedEvent: ActivityEvent? = nil`
2. **Add `filteredEvents`** computed property that applies `kindFilter` to `events`
3. **Update `groupedEvents`** to read from `filteredEvents` instead of `events`
4. **Add `filterChipBar`** view + `filterChip(label:kinds:)` helper (horizontal ScrollView of capsules)
5. **Insert `filterChipBar`** at the top of the content (above the List, or as a pinned section header)
6. **Replace timestamp** with `Text(event.occurredAt, style: .relative)`
7. **Wrap each event row** in a `Button` that sets `selectedEvent`
8. **Add `.sheet(item: $selectedEvent)`** presenting `MobileEventDetailView`
9. **Replace the generic empty state** with a conditional that checks `kindFilter` and shows per-filter text
10. **Create** `MobileEventDetailView.swift` as a new file

---

## Checklist

- [ ] FilterChipBar renders horizontally, scrolls, highlights active chip
- [ ] "All" chip clears the filter (sets `kindFilter = nil`)
- [ ] Timestamps show relative time ("2 min ago") instead of absolute dates
- [ ] Tapping an event row opens `MobileEventDetailView` as a sheet
- [ ] Detail sheet shows: icon, title, kind badge, detail text, metadata table, timestamps
- [ ] Detail sheet shows photo thumbnail when `photoAssetId` + canonical_name available
- [ ] Empty state updates per active filter with relevant icon and text
- [ ] Pull-to-refresh still works
- [ ] "Showing recent 50 events" footer still appears when applicable
