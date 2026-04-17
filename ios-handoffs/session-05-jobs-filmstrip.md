# Session 5: Filmstrip + Actions

## Goal
Add a horizontal photo filmstrip to job detail (up to 20 thumbnails with curation badge overlays), tap-to-detail navigation, a "Mark Complete" button with confirmation, and swipe actions on job list rows.

---

## Key Files
| File | Purpose |
|------|---------|
| `HoehnPhotosMobile/Features/Jobs/MobileJobsView.swift` | Job list + detail (modify both) |
| `HoehnPhotosMobile/Features/Library/MobileLibraryView.swift` | `MobilePhotoCell` definition (line 457) -- proxy URL pattern |
| `HoehnPhotosMobile/Features/Library/MobilePhotoDetailView.swift` | `FilmstripThumbnail` (line 6), `proxyURL(for:)` (line 128), `MobilePhotoDetailView` |
| `HoehnPhotosCore/Models/SharedEnums.swift` | `CurationState` enum with `.tint` and `.systemIcon` |
| `HoehnPhotosCore/Database/Repository/MobileRepositories.swift` | `MobileJobRepository.markComplete(jobId:)` |

---

## 1. Horizontal Filmstrip Component

Place this between the task cards grid (Session 4) and the full photo grid. Show up to 20 photos in a horizontal scroll. The Mac version is at `JobsView.swift` line 778.

### Proxy URL Pattern (copy from existing code)

This is the standard pattern used everywhere in the iOS app (`MobilePhotoCell`, `FilmstripThumbnail`, `OverflowBadgeTile`):

```swift
private func proxyURL(for photo: PhotoAsset) -> URL {
    let baseName = (photo.canonicalName as NSString).deletingPathExtension
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return appSupport
        .appendingPathComponent("HoehnPhotos")
        .appendingPathComponent("proxies")
        .appendingPathComponent(baseName + ".jpg")
}
```

### Filmstrip Thumbnail with Curation Badge

```swift
private struct JobFilmstripThumb: View {
    let photo: PhotoAsset
    let proxyURL: URL

    @State private var image: UIImage?

    private var curationState: CurationState? {
        CurationState(rawValue: photo.curationState)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let img = image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(uiColor: .secondarySystemBackground)
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .frame(width: 80, height: 60)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Curation badge overlay
            if let state = curationState, state != .needsReview {
                curationBadge(state)
            }
        }
        .task(id: photo.id) {
            // Same pattern as MobilePhotoCell (MobileLibraryView.swift line 457)
            if let data = try? Data(contentsOf: proxyURL),
               let img = UIImage(data: data) {
                image = img
            }
        }
    }

    private func curationBadge(_ state: CurationState) -> some View {
        Image(systemName: state.systemIcon)
            .font(.system(size: 10))
            .foregroundStyle(.white)
            .padding(3)
            .background(Circle().fill(state.tint))
            .padding(3)
    }
}
```

### Filmstrip ScrollView

Add to `MobileJobDetailView`:

```swift
private var filmstripSection: some View {
    VStack(alignment: .leading, spacing: 6) {
        HStack {
            Text("\(photos.count) Photo\(photos.count == 1 ? "" : "s")")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if photos.count > 20 {
                Text("+\(photos.count - 20) more below")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal)

        if photos.isEmpty {
            HStack {
                Spacer()
                Text("No photos yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .frame(height: 60)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    // Show up to 20 photos
                    ForEach(Array(photos.prefix(20).enumerated()), id: \.element.id) { index, photo in
                        JobFilmstripThumb(
                            photo: photo,
                            proxyURL: proxyURL(for: photo)
                        )
                        .onTapGesture {
                            selectedPhotoIndex = index
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}
```

---

## 2. Curation Badge Overlay (design reference)

The `CurationState` enum (SharedEnums.swift) provides everything needed:

| State | `.tint` | `.systemIcon` |
|-------|---------|---------------|
| `.keeper` | `.green` | `"star.fill"` |
| `.archive` | `.blue` | `"archivebox.fill"` |
| `.rejected` | `.red` | `"xmark.circle.fill"` |
| `.needsReview` | `.orange` | `"exclamationmark.circle.fill"` |

The badge is already built into `JobFilmstripThumb` above. Photos with `.needsReview` show no badge (they are the default/unrated state).

---

## 3. Tap to MobilePhotoDetailView

The existing code already handles this via `selectedPhotoIndex` and the `.sheet` presentation. The filmstrip thumbnails set `selectedPhotoIndex` on tap, and the existing sheet code presents `MobilePhotoDetailView`:

```swift
// Already exists in MobileJobDetailView (line 250):
.sheet(isPresented: Binding(
    get: { selectedPhotoIndex != nil },
    set: { if !$0 { selectedPhotoIndex = nil } }
)) {
    if let idx = selectedPhotoIndex {
        MobilePhotoDetailView(photos: photos, initialIndex: idx)
            .environmentObject(syncService)
    }
}
```

No changes needed -- the filmstrip just sets `selectedPhotoIndex` and this existing sheet code handles the rest.

---

## 4. Mark Complete Button + Confirmation

The existing implementation is already in place (line 183-204). Keep it as-is or move it to a more prominent position below the filmstrip.

### Existing Repository Method

```swift
// MobileRepositories.swift line 185
public func markComplete(jobId: String) async throws {
    try await db.dbPool.write { conn in
        let now = Date()
        try conn.execute(
            sql: "UPDATE triage_jobs SET status = ?, completed_at = ?, updated_at = ? WHERE id = ?",
            arguments: [TriageJobStatus.complete.rawValue, now, now, jobId]
        )
    }
}
```

### Existing Confirmation Pattern (keep or refine)

```swift
// Already in MobileJobDetailView body (line 183):
if job.status == .open {
    Button("Mark All Keepers Complete") {
        showMarkCompleteConfirmation = true
    }
    .buttonStyle(.borderedProminent)
    .tint(.green)
    .padding(.horizontal)
    .confirmationDialog(
        "Mark All Keepers Complete?",
        isPresented: $showMarkCompleteConfirmation
    ) {
        Button("Mark Complete") {
            Task {
                guard let db = appDatabase else { return }
                try? await MobileJobRepository(db: db).markComplete(jobId: job.id)
            }
        }
        Button("Cancel", role: .cancel) {}
    } message: {
        Text("This will mark \(job.photoCount) kept photos as reviewed and close the job.")
    }
}
```

### Enhancement: dismiss or reload after marking complete

Currently the button fires and forgets. Add navigation dismissal or state refresh:

```swift
Button("Mark Complete") {
    Task {
        guard let db = appDatabase else { return }
        try? await MobileJobRepository(db: db).markComplete(jobId: job.id)
        // Pop back to job list
        dismiss()
    }
}
```

Add `@Environment(\.dismiss) private var dismiss` to `MobileJobDetailView` state.

---

## 5. Swipe Actions on Job List Rows

Add swipe actions to the `NavigationLink` rows in the `jobsList` computed property (line 88).

### Implementation

Modify the `jobsList` in `MobileJobsView` (line 81). Wrap each `NavigationLink` with `.swipeActions`:

```swift
// Inside jobsList, for each NavigationLink:
NavigationLink {
    MobileJobDetailView(job: parent)
        .environmentObject(syncService)
} label: {
    jobRow(parent)
}
.swipeActions(edge: .trailing, allowsFullSwipe: false) {
    if parent.status == .open {
        Button {
            jobToComplete = parent
            showSwipeCompleteConfirmation = true
        } label: {
            Label("Complete", systemImage: "checkmark.circle")
        }
        .tint(.green)
    }

    if parent.status != .archived {
        Button {
            Task { await archiveJob(parent) }
        } label: {
            Label("Archive", systemImage: "archivebox")
        }
        .tint(.gray)
    }
}
.swipeActions(edge: .leading, allowsFullSwipe: false) {
    // Quick info or other action
    Button {
        // optional: show job info sheet
    } label: {
        Label("Info", systemImage: "info.circle")
    }
    .tint(.blue)
}
```

### New State + Methods for MobileJobsView

```swift
// Add to MobileJobsView state:
@State private var jobToComplete: TriageJob?
@State private var showSwipeCompleteConfirmation = false

// Add confirmation dialog to the NavigationStack body:
.confirmationDialog(
    "Mark Job Complete?",
    isPresented: $showSwipeCompleteConfirmation,
    presenting: jobToComplete
) { job in
    Button("Mark Complete") {
        Task {
            guard let db = appDatabase else { return }
            try? await MobileJobRepository(db: db).markComplete(jobId: job.id)
            await loadJobs()  // refresh list
        }
    }
    Button("Cancel", role: .cancel) {}
} message: { job in
    Text("Mark \"\(job.title)\" as complete? This will close the job.")
}
```

### Archive Method (new repo method needed)

Add to `MobileJobRepository` in `MobileRepositories.swift`:

```swift
public func archiveJob(jobId: String) async throws {
    try await db.dbPool.write { conn in
        let now = Date()
        try conn.execute(
            sql: "UPDATE triage_jobs SET status = ?, updated_at = ? WHERE id = ?",
            arguments: [TriageJobStatus.archived.rawValue, now, jobId]
        )
    }
}
```

Helper in `MobileJobsView`:
```swift
private func archiveJob(_ job: TriageJob) async {
    guard let db = appDatabase else { return }
    try? await MobileJobRepository(db: db).archiveJob(jobId: job.id)
    await loadJobs()
}
```

---

## 6. Updated Body Structure for MobileJobDetailView

After Sessions 4 + 5, the full body layout:

```swift
var body: some View {
    ScrollView {
        VStack(spacing: 16) {
            jobDetailHeader          // Session 4: 48pt ring, title, date, badge
            stagedBanner             // Session 4: blue info banner when .open
            taskCardsGrid            // Session 4: 2x2 progress cards
            filmstripSection         // Session 5: horizontal filmstrip with badges

            // Mark Complete button
            if job.status == .open {
                Button("Mark All Keepers Complete") {
                    showMarkCompleteConfirmation = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .padding(.horizontal)
            }

            Divider().padding(.horizontal)

            // Full photo grid (existing code)
            if photos.isEmpty {
                // existing empty state
            } else {
                LazyVGrid(columns: columns, spacing: 2) {
                    // existing ForEach with MobilePhotoCell
                }
            }
        }
    }
    .navigationTitle(job.title)
    .task { /* load photos + progress */ }
    .sheet(/* existing detail sheet */)
    .confirmationDialog(/* existing mark complete dialog */)
}
```

---

## Integration Checklist

- [ ] Replace `jobInfoSection` with `jobDetailHeader` (48pt ring)
- [ ] Add `stagedBanner` view
- [ ] Add `MobileJobTask` model + `TaskProgressCard` view
- [ ] Add `taskCardsGrid` with 2x2 layout
- [ ] Add `fetchPeopleProgress` and `fetchDevelopProgress` to `MobileJobRepository`
- [ ] Add `JobFilmstripThumb` component with curation badge
- [ ] Add `filmstripSection` horizontal scroll
- [ ] Add `@Environment(\.dismiss)` and post-complete dismissal
- [ ] Add `.swipeActions` to both parent and child `NavigationLink` rows in `jobsList`
- [ ] Add `archiveJob(jobId:)` to `MobileJobRepository`
- [ ] Add swipe-complete confirmation dialog to `MobileJobsView`
