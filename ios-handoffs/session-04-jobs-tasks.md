# Session 4: Task Cards + Staged Banner

## Goal
Upgrade `MobileJobDetailView` with a proper header (large CompletenessRing, title, date, status badge), a blue info banner for open jobs, and a 2x2 grid of task progress cards (Review, People, Develop, Metadata).

---

## Key Files
| File | Purpose |
|------|---------|
| `HoehnPhotosMobile/Features/Jobs/MobileJobsView.swift` | Current job list + detail views (both in this file) |
| `HoehnPhotosCore/Models/TriageJob.swift` | TriageJob model, TriageJobStatus, CompletenessWeights |
| `HoehnPhotosCore/Models/SharedEnums.swift` | CurationState enum (keeper/archive/needsReview/rejected/deleted) |
| `HoehnPhotosCore/Database/Repository/MobileRepositories.swift` | MobileJobRepository actor |
| `HoehnPhotosOrganizer/Features/Jobs/JobsView.swift` | Mac reference: TaskCard at line ~2125, JobTask model at line ~2111 |

---

## TriageJob Model (actual fields)

```swift
public struct TriageJob: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public var id: String
    public var parentJobId: String?
    public var title: String
    public var source: TriageJobSource          // .importBatch | .manual | .split
    public var status: TriageJobStatus          // .open | .complete | .archived
    public var inheritedMetadata: String?       // JSON
    public var completenessScore: Double        // 0.0-1.0
    public var photoCount: Int                  // denormalized
    public var currentMilestone: JobMilestone   // .triage | .develop | .print
    public var triageCompletedAt: Date?
    public var developCompletedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
}
```

## CompletenessWeights (from TriageJob.swift)

```swift
public struct CompletenessWeights {
    public static let curation: Double = 0.25    // all photos rated
    public static let people: Double = 0.25      // all faces identified
    public static let developed: Double = 0.25   // keeper photos developed
    public static let metadata: Double = 0.25    // keeper photos have title/caption
}
```

---

## MobileJobRepository (actual signatures)

```swift
public actor MobileJobRepository {
    public let db: AppDatabase
    public init(db: AppDatabase)

    public func fetchAll() async throws -> [TriageJob]
    public func fetchPhotos(jobId: String) async throws -> [PhotoAsset]
    public func markComplete(jobId: String) async throws
}
```

Usage pattern (from existing code):
```swift
guard let db = appDatabase else { return }
let repo = MobileJobRepository(db: db)
let photos = try await repo.fetchPhotos(jobId: job.id)
```

---

## Current MobileJobDetailView Structure

The existing detail view is in `MobileJobsView.swift` starting at line 167. It currently has:
- `jobInfoSection` (line 263): small CompletenessRing (28pt), title, percentage, status badge, photo count, date
- "Mark All Keepers Complete" button (line 183)
- Photo grid using `LazyVGrid` with `MobilePhotoCell` (line 218)
- Context menu for curation (keeper/archive/reject)

State properties:
```swift
let job: TriageJob
@Environment(\.appDatabase) private var appDatabase
@EnvironmentObject private var syncService: PeerSyncService
@State private var photos: [PhotoAsset] = []
@State private var selectedPhotoIndex: Int?
@State private var showMarkCompleteConfirmation = false
```

---

## New Components to Build

### 1. JobDetailHeader (replaces current `jobInfoSection`)

Larger ring (48pt), prominent title, photo count, date, status badge. Replace the existing `jobInfoSection` computed property.

```swift
// Replace the existing jobInfoSection in MobileJobDetailView
private var jobDetailHeader: some View {
    VStack(spacing: 12) {
        HStack(spacing: 14) {
            // Larger ring (48pt vs current 28pt)
            ZStack {
                Circle()
                    .stroke(ringColor.opacity(0.2), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: job.completenessScore)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(job.completenessScore * 100))%")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(ringColor)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.title)
                    .font(.title3.weight(.semibold))
                HStack(spacing: 12) {
                    Label("\(job.photoCount) photos", systemImage: "photo.on.rectangle")
                    Label(
                        job.createdAt.formatted(date: .abbreviated, time: .omitted),
                        systemImage: "calendar"
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Status badge
            Text(job.status.rawValue.capitalized)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(statusColor.opacity(0.15))
                )
                .foregroundStyle(statusColor)
        }
    }
    .padding()
    .background(Color(uiColor: .secondarySystemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .padding(.horizontal)
}

private var ringColor: Color {
    job.completenessScore < 0.33 ? .red
        : job.completenessScore < 0.66 ? .orange
        : .green
}

private var statusColor: Color {
    switch job.status {
    case .open: .orange
    case .complete: .green
    case .archived: .secondary
    }
}
```

### 2. StagedPhotoBanner

Blue info banner shown when `job.status == .open`. Place it between the header and the task cards.

```swift
private var stagedBanner: some View {
    Group {
        if job.status == .open {
            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                Text("These photos are staged for triage. Review and rate them to make progress.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
        }
    }
}
```

### 3. TaskProgressCard (2x2 grid)

Port the Mac `JobTask` model and `TaskCard` view, adapted for iOS mobile layout.

#### Task Model (add to MobileJobsView.swift or a new file)

The Mac defines this at JobsView.swift line 2111:
```swift
struct MobileJobTask: Identifiable {
    let id: String
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String      // e.g. "12 / 24 rated"
    let progress: Double      // 0.0-1.0
    let isComplete: Bool
}
```

#### TaskProgressCard View

```swift
private struct TaskProgressCard: View {
    let task: MobileJobTask

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: task.icon)
                    .font(.system(size: 18))
                    .foregroundStyle(task.isComplete ? .green : task.iconColor)
                Spacer()
                if task.isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 14))
                }
            }

            Text(task.title)
                .font(.subheadline.weight(.semibold))

            Text(task.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            ProgressView(value: task.progress)
                .tint(task.isComplete ? .green : task.iconColor)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
```

#### 2x2 Grid Layout

```swift
private var taskCardsGrid: some View {
    let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    return LazyVGrid(columns: columns, spacing: 12) {
        ForEach(computedTasks) { task in
            TaskProgressCard(task: task)
        }
    }
    .padding(.horizontal)
}
```

---

## Computing Task Progress

Add these as computed properties or methods in `MobileJobDetailView`. All computations use the `photos: [PhotoAsset]` array already loaded via `MobileJobRepository.fetchPhotos(jobId:)`.

```swift
private var computedTasks: [MobileJobTask] {
    let total = photos.count
    guard total > 0 else { return [] }

    // 1. Review: photos where curationState != "needs_review"
    let reviewedCount = photos.filter { $0.curationState != CurationState.needsReview.rawValue }.count
    let reviewProgress = Double(reviewedCount) / Double(total)

    // 2. People: requires a DB query for face_embeddings count
    //    Use peopleProgress state var, loaded in .task {}
    let peopleProgress = self.peopleProgress  // new @State var

    // 3. Develop: keeper photos that have at least one DevelopmentVersion
    //    Use developProgress state var, loaded in .task {}
    let developProgress = self.developProgress  // new @State var

    // 4. Metadata: keeper photos that have a non-nil/non-empty title
    let keepers = photos.filter { $0.curationState == CurationState.keeper.rawValue }
    let keeperCount = max(keepers.count, 1)
    let metadataCount = keepers.filter { ($0.title ?? "").isEmpty == false }.count
    let metadataProgress = Double(metadataCount) / Double(keeperCount)

    return [
        MobileJobTask(
            id: "review", icon: "eye", iconColor: .orange,
            title: "Review", subtitle: "\(reviewedCount) / \(total) rated",
            progress: reviewProgress, isComplete: reviewProgress >= 1.0
        ),
        MobileJobTask(
            id: "people", icon: "person.2", iconColor: .purple,
            title: "People", subtitle: peopleSubtitle,
            progress: peopleProgress, isComplete: peopleProgress >= 1.0
        ),
        MobileJobTask(
            id: "develop", icon: "slider.horizontal.3", iconColor: .blue,
            title: "Develop", subtitle: developSubtitle,
            progress: developProgress, isComplete: developProgress >= 1.0
        ),
        MobileJobTask(
            id: "metadata", icon: "text.badge.checkmark", iconColor: .teal,
            title: "Metadata", subtitle: "\(metadataCount) / \(keeperCount) titled",
            progress: metadataProgress, isComplete: metadataProgress >= 1.0
        ),
    ]
}
```

### People Progress Query (new repo method needed)

Add to `MobileJobRepository`:
```swift
public func fetchPeopleProgress(jobId: String) async throws -> (identified: Int, total: Int) {
    try await db.dbPool.read { conn in
        // Count photos in job that have at least one identified face
        let total = try Int.fetchOne(conn, sql: """
            SELECT COUNT(DISTINCT tjp.photo_id)
            FROM triage_job_photos tjp
            JOIN face_embeddings fe ON fe.photo_id = tjp.photo_id
            WHERE tjp.job_id = ?
        """, arguments: [jobId]) ?? 0

        let identified = try Int.fetchOne(conn, sql: """
            SELECT COUNT(DISTINCT tjp.photo_id)
            FROM triage_job_photos tjp
            JOIN face_embeddings fe ON fe.photo_id = tjp.photo_id
            WHERE tjp.job_id = ? AND fe.person_id IS NOT NULL
        """, arguments: [jobId]) ?? 0

        return (identified, total)
    }
}
```

### Develop Progress Query (new repo method needed)

```swift
public func fetchDevelopProgress(jobId: String) async throws -> (developed: Int, total: Int) {
    try await db.dbPool.read { conn in
        // Count keeper photos in job
        let keeperCount = try Int.fetchOne(conn, sql: """
            SELECT COUNT(*)
            FROM triage_job_photos tjp
            JOIN photo_assets pa ON pa.id = tjp.photo_id
            WHERE tjp.job_id = ? AND pa.curation_state = ?
        """, arguments: [jobId, CurationState.keeper.rawValue]) ?? 0

        // Count keeper photos that have at least one development_version
        let developedCount = try Int.fetchOne(conn, sql: """
            SELECT COUNT(DISTINCT tjp.photo_id)
            FROM triage_job_photos tjp
            JOIN photo_assets pa ON pa.id = tjp.photo_id
            JOIN development_versions dv ON dv.photo_id = tjp.photo_id
            WHERE tjp.job_id = ? AND pa.curation_state = ?
        """, arguments: [jobId, CurationState.keeper.rawValue]) ?? 0

        return (developedCount, keeperCount)
    }
}
```

---

## New State Variables for MobileJobDetailView

```swift
@State private var peopleProgress: Double = 0
@State private var peopleSubtitle: String = "Loading..."
@State private var developProgress: Double = 0
@State private var developSubtitle: String = "Loading..."
```

Load in the existing `.task` block:
```swift
.task {
    guard let db = appDatabase else { return }
    let repo = MobileJobRepository(db: db)

    // Existing photo load
    photos = (try? await repo.fetchPhotos(jobId: job.id)) ?? []

    // People progress
    if let people = try? await repo.fetchPeopleProgress(jobId: job.id) {
        let total = max(people.total, 1)
        peopleProgress = Double(people.identified) / Double(total)
        peopleSubtitle = "\(people.identified) / \(people.total) identified"
    }

    // Develop progress
    if let dev = try? await repo.fetchDevelopProgress(jobId: job.id) {
        let total = max(dev.total, 1)
        developProgress = Double(dev.developed) / Double(total)
        developSubtitle = "\(dev.developed) / \(dev.total) developed"
    }
}
```

---

## Updated Body Structure

Replace the current `MobileJobDetailView.body`:

```swift
var body: some View {
    ScrollView {
        VStack(spacing: 16) {
            jobDetailHeader       // NEW: 48pt ring, title, date, badge
            stagedBanner          // NEW: blue info banner when .open
            taskCardsGrid         // NEW: 2x2 task progress cards

            // Mark complete button (keep existing)
            if job.status == .open { /* existing button code */ }

            // Photo grid (keep existing LazyVGrid code)
            // ...existing photo grid code...
        }
    }
    .navigationTitle(job.title)
    .task { /* updated task block above */ }
    .sheet(/* existing sheet code */)
}
```

---

## CurationState Reference (from SharedEnums.swift)

| Case | rawValue | tint | systemIcon |
|------|----------|------|------------|
| `.keeper` | `"keeper"` | `.green` | `"star.fill"` |
| `.archive` | `"archive"` | `.blue` | `"archivebox.fill"` |
| `.needsReview` | `"needs_review"` | `.orange` | `"exclamationmark.circle.fill"` |
| `.rejected` | `"rejected"` | `.red` | `"xmark.circle.fill"` |
| `.deleted` | `"deleted"` | `.gray` | `"trash.fill"` |

PhotoAsset stores `curationState` as a raw `String` -- compare with `CurationState.keeper.rawValue` etc.
