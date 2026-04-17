# Session 2: Library Curation UX

## Overview

The curation button bar in `MobilePhotoDetailView` already exists and is wired to both the local DB and `syncService.enqueueDelta()`. This session focuses on adding context menus to photo thumbnails in the bento grid and verifying pull-to-refresh works correctly.

---

## 1. Existing Curation Bar -- Already Implemented

The rating bar in `MobilePhotoDetailView.swift` (lines 427-466) is fully functional. Here is how it works for reference:

### Rating bar component (lines 427-436)

```swift
private var ratingBar: some View {
    HStack(spacing: 20) {
        ratingButton(.rejected, icon: "xmark", label: "Reject", feedbackLabel: "Rejected", color: .red)
        ratingButton(.archive, icon: "archivebox", label: "Archive", feedbackLabel: "Archived", color: .blue)
        ratingButton(.keeper, icon: "star.fill", label: "Keep", feedbackLabel: "Kept", color: .green)
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 16)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    .padding(.bottom, 20)
}
```

### Each button's action pattern (lines 439-465)

```swift
private func ratingButton(_ state: CurationState, icon: String, label: String, feedbackLabel: String, color: Color) -> some View {
    Button {
        // 1. Haptic feedback
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // 2. Update local state
        currentState = state
        // 3. Show success badge overlay
        withAnimation(.easeIn(duration: 0.3)) {
            lastCurationFeedback = feedbackLabel
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            withAnimation { lastCurationFeedback = nil }
        }
        // 4. Persist to DB + enqueue sync delta
        let photoID = photo.id
        Task {
            guard let db = appDatabase else { return }
            try? await MobilePhotoRepository(db: db).updateCurationState(id: photoID, state: state)
            syncService.enqueueDelta(PhotoCurationDelta(photoId: photoID, curationState: state.rawValue))
        }
    } label: {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 22))
            Text(label)
                .font(.caption2)
        }
        .foregroundStyle(currentState == state ? color : .white.opacity(0.7))
        .frame(width: 60)
    }
}
```

### Key API calls

**Local DB update:**
```swift
try? await MobilePhotoRepository(db: db).updateCurationState(id: photoID, state: state)
```

**Sync delta enqueue:**
```swift
syncService.enqueueDelta(PhotoCurationDelta(photoId: photoID, curationState: state.rawValue))
```

**PhotoCurationDelta** (from `HoehnPhotosCore/Sync/SyncDeltaQueue.swift`):
```swift
public struct PhotoCurationDelta: Codable, Identifiable, Equatable {
    public let id: String        // photoId
    public let curationState: String
    public let updatedAt: String // ISO8601

    public init(photoId: String, curationState: String) {
        self.id = photoId
        self.curationState = curationState
        self.updatedAt = ISO8601DateFormatter().string(from: Date())
    }
}
```

**enqueueDelta** (from `HoehnPhotosCore/Sync/PeerSyncService.swift`, line 92):
```swift
public func enqueueDelta(_ delta: PhotoCurationDelta) {
    // Remove any existing delta for same photo (latest wins)
    pendingDeltas.removeAll { $0.id == delta.id }
    pendingDeltas.append(delta)
    savePendingDeltas()
    // Auto-flush if connected...
}
```

---

## 2. CurationState Reference

**File:** `HoehnPhotosCore/Models/SharedEnums.swift`

| Case | rawValue | title | SF Symbol | Color |
|------|----------|-------|-----------|-------|
| `keeper` | `"keeper"` | `"Keeper"` | `"star.fill"` | `.green` |
| `archive` | `"archive"` | `"Archive"` | `"archivebox.fill"` | `.blue` |
| `needsReview` | `"needs_review"` | `"Needs Review"` | `"exclamationmark.circle.fill"` | `.orange` |
| `rejected` | `"rejected"` | `"Rejected"` | `"xmark.circle.fill"` | `.red` |
| `deleted` | `"deleted"` | `"Deleted"` | `"trash.fill"` | `.gray` |

Access via `CurationState.tint`, `CurationState.systemIcon`, `CurationState.title`.

---

## 3. Add Context Menus to Bento Grid Photo Tiles

**File:** `HoehnPhotosMobile/Features/Library/BentoSectionView.swift`

### Current context menu (line 131-135)

The `photoTile` function already has a placeholder context menu:

```swift
.contextMenu {
    Button { } label: {
        Label("View Details", systemImage: "arrow.up.left.and.arrow.down.right")
    }
}
```

### Replace with curation context menu

The `BentoSectionView` needs a new callback for curation. Add an `onCuratePhoto` callback parameter.

**Step 1:** Add callback to struct (after existing parameters, around line 16):

```swift
struct BentoSectionView: View {
    let photos: [PhotoAsset]
    let isExpanded: Bool
    let isSelecting: Bool
    let selectedPhotoIDs: Set<String>
    let onTapPhoto: (PhotoAsset) -> Void
    let onToggleExpand: () -> Void
    let onCuratePhoto: ((PhotoAsset, CurationState) -> Void)?  // ADD THIS
```

**Step 2:** Replace the `.contextMenu` modifier in `photoTile` (lines 131-135) with:

```swift
.contextMenu {
    // View Details
    Button {
        onTapPhoto(photo)
    } label: {
        Label("View Details", systemImage: "arrow.up.left.and.arrow.down.right")
    }

    Divider()

    // Curation actions
    Button {
        onCuratePhoto?(photo, .keeper)
    } label: {
        Label("Keep", systemImage: CurationState.keeper.systemIcon)
    }

    Button {
        onCuratePhoto?(photo, .archive)
    } label: {
        Label("Archive", systemImage: CurationState.archive.systemIcon)
    }

    Button(role: .destructive) {
        onCuratePhoto?(photo, .rejected)
    } label: {
        Label("Reject", systemImage: CurationState.rejected.systemIcon)
    }
}
```

**Step 3:** Also add context menu to expanded grid tiles. In `expandedGrid` (around line 148), add the same `.contextMenu` modifier after the `.onTapGesture`:

```swift
ForEach(Array(expandedPhotos), id: \.id) { photo in
    let isSelected = selectedPhotoIDs.contains(photo.id)
    MobilePhotoCell(photo: photo, isSelected: isSelected)
        .aspectRatio(1, contentMode: .fill)
        .onTapGesture { onTapPhoto(photo) }
        .contextMenu {
            Button {
                onTapPhoto(photo)
            } label: {
                Label("View Details", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            Divider()
            Button {
                onCuratePhoto?(photo, .keeper)
            } label: {
                Label("Keep", systemImage: CurationState.keeper.systemIcon)
            }
            Button {
                onCuratePhoto?(photo, .archive)
            } label: {
                Label("Archive", systemImage: CurationState.archive.systemIcon)
            }
            Button(role: .destructive) {
                onCuratePhoto?(photo, .rejected)
            } label: {
                Label("Reject", systemImage: CurationState.rejected.systemIcon)
            }
        }
}
```

**Step 4:** Update the call site in `MobileLibraryView.swift` (lines 262-277).

Current call:
```swift
BentoSectionView(
    photos: section.photos,
    isExpanded: expandedMonths.contains(section.monthKey),
    isSelecting: isSelecting,
    selectedPhotoIDs: selectedPhotoIDs,
    onTapPhoto: { photo in handlePhotoTap(photo) },
    onToggleExpand: { ... }
)
```

Add the new parameter:
```swift
BentoSectionView(
    photos: section.photos,
    isExpanded: expandedMonths.contains(section.monthKey),
    isSelecting: isSelecting,
    selectedPhotoIDs: selectedPhotoIDs,
    onTapPhoto: { photo in handlePhotoTap(photo) },
    onToggleExpand: { ... },
    onCuratePhoto: { photo, state in
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        curate(photo: photo, state: state)
    }
)
```

This reuses the existing `curate(photo:state:)` method (line 383) which does a direct DB write. To also enqueue a sync delta, update that method:

### Update `curate(photo:state:)` in MobileLibraryView.swift (lines 383-406)

Add `syncService.enqueueDelta` after the DB write:

```swift
private func curate(photo: PhotoAsset, state: CurationState) {
    guard let db = appDatabase else { return }
    Task {
        do {
            try await db.dbPool.write { dbConn in
                try dbConn.execute(
                    sql: "UPDATE photo_assets SET curation_state = ? WHERE id = ?",
                    arguments: [state.rawValue, photo.id]
                )
            }
            // Enqueue sync delta  <-- ADD THIS
            syncService.enqueueDelta(PhotoCurationDelta(photoId: photo.id, curationState: state.rawValue))
            // Refresh the photo in the local monthSections array
            for sectionIndex in monthSections.indices {
                if let photoIndex = monthSections[sectionIndex].photos.firstIndex(where: { $0.id == photo.id }) {
                    var updated = monthSections[sectionIndex].photos[photoIndex]
                    updated.curationState = state.rawValue
                    monthSections[sectionIndex].photos[photoIndex] = updated
                    break
                }
            }
        } catch {
            print("[Library] curate error: \(error)")
        }
    }
}
```

Also add the delta enqueue to `batchCurate` (after the DB write loop, around line 363):

```swift
// After the DB write loop, before updating local monthSections:
for id in ids {
    syncService.enqueueDelta(PhotoCurationDelta(photoId: id, curationState: state.rawValue))
}
```

---

## 4. Haptic Feedback -- Already Implemented

Haptic feedback is already in place:

- **Photo tap in grid** (line 295): `UIImpactFeedbackGenerator(style: .light).impactOccurred()`
- **Detail view curation buttons** (line 441): `UIImpactFeedbackGenerator(style: .medium).impactOccurred()`
- **Batch curation** (line 354): `UINotificationFeedbackGenerator().notificationOccurred(.success)`

For the new context menu curation, the callback in the call site above includes `UIImpactFeedbackGenerator(style: .medium).impactOccurred()`.

---

## 5. Pull-to-Refresh -- Already Implemented

**File:** `HoehnPhotosMobile/Features/Library/MobileLibraryView.swift`, line 287-289

```swift
.refreshable {
    await reloadAndFetch()
}
```

This is on the `ScrollView` in `photoGrid`. It calls `reloadAndFetch()` which:
1. Calls `db.reload()` to pick up any new DB file from sync
2. Calls `resetAndLoad()` which clears `monthSections` and re-fetches via `MobilePhotoRepository.fetchLibraryPhotosGroupedByMonth()`

The manual reload button in the toolbar (line 80-83) does the same thing.

### Verify

- Pull down on the photo grid scrollview -- spinner appears, data reloads
- After a sync completes (`syncService.state == .completed`), the view auto-reloads (line 120-126)

---

## Verification Checklist

- [ ] Long-press a photo tile in bento grid shows context menu with Keep/Archive/Reject
- [ ] Context menu curation updates the curation dot on the tile immediately
- [ ] Context menu curation enqueues a sync delta (check `syncService.pendingDeltas` count)
- [ ] Haptic fires on context menu curation selection
- [ ] Context menu also appears on expanded grid tiles (after tapping overflow "+N")
- [ ] Batch selection bar still works (Select > tap photos > Keep/Archive/Reject)
- [ ] Batch curation now also enqueues sync deltas
- [ ] Pull-to-refresh works on the photo grid
- [ ] Curation in detail view still works with haptic + sync delta (already wired)
- [ ] No compilation errors from new `onCuratePhoto` parameter
