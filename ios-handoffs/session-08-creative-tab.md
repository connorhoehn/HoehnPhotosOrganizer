# Session 8: Tab Restructure + Creative Tab + Repositories

## Goal
Replace the Activity tab with a Creative tab containing Studio and Print Lab. Add `MobileStudioRepository` and `MobilePrintRepository` to the shared Core package. Move Activity into a secondary location (Settings or a sub-nav).

---

## Key Files

| File | Role |
|------|------|
| `HoehnPhotosMobile/MobileTabView.swift` | Tab bar -- restructure tabs here |
| `HoehnPhotosCore/Database/Repository/MobileRepositories.swift` | Add new repos here |
| `HoehnPhotosMobile/Features/Studio/MobileStudioHistoryView.swift` | Already calls `MobileStudioRepository` (compile error until repo exists) |
| `HoehnPhotosMobile/Features/Settings/MobileSettingsView.swift` | Remove "View Only" section, optionally add Activity link |
| `HoehnPhotosCore/Models/StudioRevision.swift` | Shared model (already exists and is correct) |

---

## Step 1: Update MobileTab Enum

Current enum in `MobileTabView.swift`:
```swift
enum MobileTab: String {
    case library, jobs, search, people, activity, settings
}
```

Change to:
```swift
enum MobileTab: String {
    case library, jobs, search, people, creative, settings
}
```

---

## Step 2: Replace Activity Tab with Creative Tab

In `MobileTabView.swift`, replace the Activity tab entry:

```swift
// REMOVE:
MobileActivityView()
    .tabItem {
        Label("Activity", systemImage: "clock")
    }
    .tag(MobileTab.activity)

// ADD:
MobileCreativeView()
    .tabItem {
        Label("Creative", systemImage: "paintpalette")
    }
    .tag(MobileTab.creative)
```

---

## Step 3: Create MobileCreativeView

New file: `HoehnPhotosMobile/Features/Creative/MobileCreativeView.swift`

This is a segmented control container switching between Studio and Print Lab.

```swift
import SwiftUI
import HoehnPhotosCore

struct MobileCreativeView: View {

    enum CreativeSection: String, CaseIterable {
        case studio = "Studio"
        case printLab = "Print Lab"
    }

    @State private var selectedSection: CreativeSection = .studio

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Segmented control
                Picker("Section", selection: $selectedSection) {
                    ForEach(CreativeSection.allCases, id: \.self) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                // Content
                switch selectedSection {
                case .studio:
                    MobileStudioGalleryView()
                case .printLab:
                    MobilePrintLabView()
                }
            }
            .navigationTitle("Creative")
        }
    }
}
```

**Note:** `MobileStudioGalleryView` (session 9) and `MobilePrintLabView` (session 10) don't exist yet. For session 8, either create placeholder stubs or use the existing `MobileStudioBrowseView` (already in `MobileStudioHistoryView.swift`) as the studio content. The browse view already has a 2-col grid of all revisions.

Temporary stub if needed:
```swift
struct MobileStudioGalleryView: View {
    var body: some View {
        MobileStudioBrowseView()  // reuse existing browse view
    }
}

struct MobilePrintLabView: View {
    var body: some View {
        Text("Print Lab coming soon")
            .foregroundStyle(.secondary)
    }
}
```

---

## Step 4: Add MobileStudioRepository to MobileRepositories.swift

The existing `MobileStudioHistoryView.swift` already calls `MobileStudioRepository(db:).fetchRevisions(photoId:)` and `.fetchAllRevisions()` -- but the repo does not exist yet. This is a compile error. Add it to `HoehnPhotosCore/Database/Repository/MobileRepositories.swift`.

### Database Schema: `studio_revisions` Table

Created in v29, altered in v30 (added `params_json`) and v32 (added `canvas_id`):

```sql
CREATE TABLE studio_revisions (
    id              TEXT NOT NULL PRIMARY KEY,
    photo_id        TEXT NOT NULL REFERENCES photo_assets(id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    medium          TEXT NOT NULL,       -- StudioMedium.rawValue e.g. "Oil Painting"
    params_json     TEXT NOT NULL DEFAULT '{}',  -- JSON-encoded StudioParameters
    created_at      TEXT NOT NULL,       -- ISO 8601
    thumbnail_path  TEXT,                -- relative path under AppSupport/HoehnPhotos/studio/
    full_res_path   TEXT,                -- relative path to full-res render
    canvas_id       TEXT REFERENCES studio_canvases(id) ON DELETE CASCADE
    -- NOTE: v29 also created brush_size, detail, texture, color_saturation, contrast
    -- columns, but they are superseded by params_json (v30). They still exist in the
    -- schema but are not used by current code.
);
CREATE INDEX idx_studio_revisions_photo_id ON studio_revisions(photo_id);
```

### Repository Code

Follow the `MobileActivityRepository` actor pattern:

```swift
// MARK: - MobileStudioRepository

public actor MobileStudioRepository {
    public let db: AppDatabase

    public init(db: AppDatabase) { self.db = db }

    /// Fetch all revisions across all photos, newest first.
    public func fetchAllRevisions(limit: Int = 200) async throws -> [StudioRevision] {
        try await db.dbPool.read { conn in
            try StudioRevision
                .order(Column("created_at").desc)
                .limit(limit)
                .fetchAll(conn)
        }
    }

    /// Fetch revisions for a specific photo.
    public func fetchRevisions(photoId: String) async throws -> [StudioRevision] {
        try await db.dbPool.read { conn in
            try StudioRevision
                .filter(Column("photo_id") == photoId)
                .order(Column("created_at").desc)
                .fetchAll(conn)
        }
    }

    /// Fetch revisions grouped by medium (for filter chips).
    /// Returns a dictionary keyed by StudioMedium raw value.
    public func fetchGroupedByMedium() async throws -> [String: [StudioRevision]] {
        let all = try await fetchAllRevisions(limit: 500)
        return Dictionary(grouping: all) { $0.medium }
    }

    /// Fetch distinct mediums that have at least one revision (for filter chip visibility).
    public func fetchAvailableMediums() async throws -> [String] {
        try await db.dbPool.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT DISTINCT medium FROM studio_revisions ORDER BY medium
            """)
            return rows.compactMap { $0["medium"] as? String }
        }
    }
}
```

---

## Step 5: Add MobilePrintRepository to MobileRepositories.swift

### How Print Attempts Are Stored

**Important:** There is NO `print_attempts` table. Print attempts are stored as rows in `thread_entries` with `kind = 'print_attempt'`. The print data is JSON-encoded in the `content_json` column. The existing `PrintLabPreviewView` in Settings queries a non-existent `print_attempts` table (always shows empty because the EXISTS check fails).

### thread_entries Table Schema (relevant columns)

```sql
CREATE TABLE thread_entries (
    id                TEXT NOT NULL PRIMARY KEY,
    thread_root_id    TEXT NOT NULL REFERENCES photo_assets(id) ON DELETE CASCADE,
    sequence_number   INTEGER NOT NULL,
    kind              TEXT NOT NULL,           -- "print_attempt", "text_note", "ai_turn", etc.
    authored_by       TEXT NOT NULL,           -- "user" | "ai"
    content_json      TEXT NOT NULL,           -- JSON blob with print attempt fields
    created_at        TEXT NOT NULL,           -- ISO 8601
    sync_state        TEXT NOT NULL DEFAULT 'local_only',
    activity_event_id TEXT,
    UNIQUE(thread_root_id, sequence_number)
);
-- Partial index for print attempts:
CREATE INDEX idx_thread_entries_print_attempts
    ON thread_entries(thread_root_id, kind, sequence_number)
    WHERE kind = 'print_attempt';
```

### content_json Structure for Print Attempts

The `content_json` for `kind = 'print_attempt'` entries contains fields from the `PrintAttempt` model. Key fields to extract:

- `print_type` -- e.g. "platinum_palladium", "inkjet_bw", "cyanotype"
- `paper` -- paper name string
- `outcome` -- "pass", "fail", "needs_adjustment", "testing"
- `outcome_notes` -- text notes
- `icc_profile_name` -- optional ICC profile
- `qtr_curve_name` -- optional QTR curve

### PrintAttempt Model Fields (Mac target, for reference)

```swift
struct PrintAttempt: Identifiable, Codable {
    var id: String
    var photoId: String                      // photo_id in content_json
    var printType: PrintType                 // enum: inkjetColor, inkjetBW, silverGelatinDarkroom,
                                             //        platinumPalladium, cyanotype, digitalNegative
    var paper: String
    var outcome: PrintOutcome                // enum: pass, fail, needsAdjustment, testing
    var outcomeNotes: String
    var curveFileId: String?
    var curveFileName: String?
    var printPhotoId: String?
    var createdAt: Date
    var updatedAt: Date
    var processSpecificFields: [String: AnyCodable]
    // ICC fields
    var iccProfileName: String?
    var renderingIntent: String?
    var blackPointCompensation: Bool?
    var brightnessCorrection: Double?
    var saturationCorrection: Double?
    // QTR fields
    var qtrCurveName: String?
    var qtrColorModel: String?
    var qtrResolution: String?
    var qtrInkLimit: String?
    var qtrDitherAlgorithm: String?
    var qtrFeedMode: String?
    var qtrBlackInk: String?
    // Calibration fields
    var calibrationTemplate: String?
    var tileParametersJSON: String?
    var winnerTileIndex: Int?
    var calibrationNotes: String?
}
```

### Repository Code

Since print attempts live in `thread_entries.content_json`, use raw SQL and manual decoding:

```swift
// MARK: - MobilePrintRepository

public actor MobilePrintRepository {
    public let db: AppDatabase

    public init(db: AppDatabase) { self.db = db }

    /// Summary struct for list display (avoids decoding full content_json).
    public struct PrintAttemptSummary: Identifiable, Sendable {
        public let id: String              // thread_entry.id
        public let photoId: String         // thread_root_id
        public let printType: String       // from content_json
        public let paper: String           // from content_json
        public let outcome: String         // from content_json
        public let outcomeNotes: String    // from content_json
        public let createdAt: String       // ISO 8601
    }

    /// Fetch all print attempts across all photos, newest first.
    public func fetchAll(limit: Int = 100) async throws -> [PrintAttemptSummary] {
        try await db.dbPool.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT id, thread_root_id, content_json, created_at
                FROM thread_entries
                WHERE kind = 'print_attempt'
                ORDER BY created_at DESC
                LIMIT ?
            """, arguments: [limit])

            return rows.compactMap { row -> PrintAttemptSummary? in
                guard let id = row["id"] as? String,
                      let photoId = row["thread_root_id"] as? String,
                      let jsonStr = row["content_json"] as? String,
                      let createdAt = row["created_at"] as? String,
                      let data = jsonStr.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }

                return PrintAttemptSummary(
                    id: id,
                    photoId: photoId,
                    printType: json["print_type"] as? String ?? "unknown",
                    paper: json["paper"] as? String ?? "Unknown",
                    outcome: json["outcome"] as? String ?? "unknown",
                    outcomeNotes: json["outcome_notes"] as? String ?? "",
                    createdAt: createdAt
                )
            }
        }
    }

    /// Fetch print attempts for a specific photo.
    public func fetchForPhoto(photoId: String) async throws -> [PrintAttemptSummary] {
        try await db.dbPool.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT id, thread_root_id, content_json, created_at
                FROM thread_entries
                WHERE kind = 'print_attempt' AND thread_root_id = ?
                ORDER BY created_at DESC
            """, arguments: [photoId])

            return rows.compactMap { row -> PrintAttemptSummary? in
                guard let id = row["id"] as? String,
                      let photoId = row["thread_root_id"] as? String,
                      let jsonStr = row["content_json"] as? String,
                      let createdAt = row["created_at"] as? String,
                      let data = jsonStr.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }

                return PrintAttemptSummary(
                    id: id,
                    photoId: photoId,
                    printType: json["print_type"] as? String ?? "unknown",
                    paper: json["paper"] as? String ?? "Unknown",
                    outcome: json["outcome"] as? String ?? "unknown",
                    outcomeNotes: json["outcome_notes"] as? String ?? "",
                    createdAt: createdAt
                )
            }
        }
    }
}
```

---

## Step 6: Relocate Activity

Activity was previously a top-level tab. Two options:

**Option A (recommended):** Add Activity as a link in Settings:
```swift
Section("History") {
    NavigationLink {
        MobileActivityView()
    } label: {
        Label("Activity", systemImage: "clock")
    }
}
```

**Option B:** Add Activity as a third segment in MobileCreativeView (Studio / Print Lab / Activity). Less ideal since Activity is not "creative."

---

## Verification Checklist

- [ ] MobileTab enum has `.creative` instead of `.activity`
- [ ] Tab bar shows: Library | Jobs | Search | People | Creative | Settings
- [ ] Creative tab has segmented control switching Studio / Print Lab
- [ ] `MobileStudioRepository` compiles and resolves existing call sites in `MobileStudioHistoryView.swift`
- [ ] `MobilePrintRepository` compiles and correctly queries `thread_entries WHERE kind = 'print_attempt'`
- [ ] Activity is accessible from Settings (or other secondary location)
- [ ] No compile errors from removed `.activity` tab references
