# Session 12: Context Menus + Swipe Actions

## Goal
Add consistent context menus to all photo grids, people cards, and job rows. Add swipe actions to job list rows. Use consistent haptic feedback throughout.

---

## CurationState Reference (from SharedEnums.swift)

```swift
public enum CurationState: String, CaseIterable, Identifiable {
    case keeper
    case archive
    case needsReview = "needs_review"
    case rejected
    case deleted

    public var title: String {
        switch self {
        case .keeper:      "Keeper"
        case .archive:     "Archive"
        case .needsReview: "Needs Review"
        case .rejected:    "Rejected"
        case .deleted:     "Deleted"
        }
    }

    public var tint: Color {
        switch self {
        case .keeper:      .green
        case .archive:     .blue
        case .needsReview: .orange
        case .rejected:    .red
        case .deleted:     .gray
        }
    }

    public var systemIcon: String {
        switch self {
        case .keeper:      "star.fill"
        case .archive:     "archivebox.fill"
        case .needsReview: "exclamationmark.circle.fill"
        case .rejected:    "xmark.circle.fill"
        case .deleted:     "trash.fill"
        }
    }
}
```

---

## Step 1: Reusable PhotoContextMenu Component

**New file:** `HoehnPhotosMobile/Components/PhotoContextMenu.swift`

```swift
import SwiftUI
import HoehnPhotosCore

/// Reusable context menu for any photo tile across all tabs.
/// Attach with: .modifier(PhotoContextMenu(photo: photo, onCurate: { ... }, onShare: { ... }))
struct PhotoContextMenu: ViewModifier {
    let photo: PhotoAsset
    let onCurate: (CurationState) -> Void
    var onShare: (() -> Void)? = nil
    var onViewDetails: (() -> Void)? = nil

    func body(content: Content) -> some View {
        content.contextMenu {
            // Curation section
            Section("Curation") {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onCurate(.keeper)
                } label: {
                    Label("Keep", systemImage: CurationState.keeper.systemIcon)
                }

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onCurate(.archive)
                } label: {
                    Label("Archive", systemImage: CurationState.archive.systemIcon)
                }

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onCurate(.needsReview)
                } label: {
                    Label("Needs Review", systemImage: CurationState.needsReview.systemIcon)
                }

                Button(role: .destructive) {
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    onCurate(.rejected)
                } label: {
                    Label("Reject", systemImage: CurationState.rejected.systemIcon)
                }
            }

            // Actions section
            if onShare != nil || onViewDetails != nil {
                Section {
                    if let onShare {
                        Button {
                            onShare()
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }

                    if let onViewDetails {
                        Button {
                            onViewDetails()
                        } label: {
                            Label("Details", systemImage: "info.circle")
                        }
                    }
                }
            }
        } preview: {
            // Context menu preview: larger version of the photo
            MobilePhotoCell(photo: photo)
                .frame(width: 300, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

extension View {
    func photoContextMenu(
        photo: PhotoAsset,
        onCurate: @escaping (CurationState) -> Void,
        onShare: (() -> Void)? = nil,
        onViewDetails: (() -> Void)? = nil
    ) -> some View {
        modifier(PhotoContextMenu(
            photo: photo,
            onCurate: onCurate,
            onShare: onShare,
            onViewDetails: onViewDetails
        ))
    }
}
```

---

## Step 2: Delta Sync Pattern for Curation Changes

When a curation change happens on iOS, it must be written locally AND enqueued for sync to Mac. Here is the canonical pattern (from `MobilePhotoDetailView.swift`):

```swift
// 1. Write to local DB
try? await MobilePhotoRepository(db: db).updateCurationState(id: photo.id, state: state)

// 2. Enqueue delta for peer sync
syncService.enqueueDelta(
    PhotoCurationDelta(photoId: photo.id, curationState: state.rawValue)
)
```

`PhotoCurationDelta` is defined in `HoehnPhotosCore/Sync/SyncDeltaQueue.swift`:

```swift
public struct PhotoCurationDelta: Codable, Identifiable, Equatable {
    public let id: String        // photoId
    public let curationState: String
    public let updatedAt: String // ISO8601

    public init(photoId: String, curationState: String) { ... }
}
```

`PeerSyncService.enqueueDelta()` deduplicates by photo ID (latest wins) and auto-flushes when connected.

**Important:** Every curation change from a context menu or swipe action MUST call both the local DB write and `enqueueDelta`. Create a shared helper:

```swift
// Add to a shared location (e.g., PhotoContextMenu.swift or a new CurationHelper.swift)
func applyCuration(
    photo: PhotoAsset,
    state: CurationState,
    db: AppDatabase,
    syncService: PeerSyncService
) async {
    try? await MobilePhotoRepository(db: db).updateCurationState(id: photo.id, state: state)
    syncService.enqueueDelta(
        PhotoCurationDelta(photoId: photo.id, curationState: state.rawValue)
    )
    UINotificationFeedbackGenerator().notificationOccurred(.success)
}
```

---

## Step 3: Integration Points

### 3A. Library Grid (BentoSectionView photo tiles)

**File:** `HoehnPhotosMobile/Features/Library/BentoSectionView.swift`

The `photoTile` function (line 126) currently has a stub context menu:

**Before:**
```swift
private func photoTile(_ photo: PhotoAsset) -> some View {
    let isSelected = selectedPhotoIDs.contains(photo.id)
    MobilePhotoCell(photo: photo, isSelected: isSelected)
        .contentShape(Rectangle())
        .onTapGesture { onTapPhoto(photo) }
        .contextMenu {
            Button { } label: {
                Label("View Details", systemImage: "arrow.up.left.and.arrow.down.right")
            }
        }
}
```

**After:**
```swift
private func photoTile(_ photo: PhotoAsset) -> some View {
    let isSelected = selectedPhotoIDs.contains(photo.id)
    MobilePhotoCell(photo: photo, isSelected: isSelected)
        .contentShape(Rectangle())
        .onTapGesture { onTapPhoto(photo) }
        .photoContextMenu(photo: photo, onCurate: { state in
            onCurate?(photo, state)
        })
}
```

This requires adding an `onCurate` callback to `BentoSectionView`:

```swift
// Add to BentoSectionView properties:
var onCurate: ((PhotoAsset, CurationState) -> Void)? = nil
```

And in `MobileLibraryView`, wire it when constructing `BentoSectionView`:

```swift
BentoSectionView(
    photos: section.photos,
    isExpanded: expandedMonths.contains(section.monthKey),
    isSelecting: isSelecting,
    selectedPhotoIDs: selectedPhotoIDs,
    onTapPhoto: { photo in handlePhotoTap(photo) },
    onToggleExpand: { ... },
    onCurate: { photo, state in
        curate(photo: photo, state: state)
        syncService.enqueueDelta(
            PhotoCurationDelta(photoId: photo.id, curationState: state.rawValue)
        )
    }
)
```

Also add context menus to the **expanded grid** photos in `BentoSectionView` (line 144):

```swift
// In expandedGrid, add to each ForEach item:
MobilePhotoCell(photo: photo, isSelected: isSelected)
    .aspectRatio(1, contentMode: .fill)
    .onTapGesture { onTapPhoto(photo) }
    .photoContextMenu(photo: photo, onCurate: { state in
        onCurate?(photo, state)
    })
```

---

### 3B. Search Grid

**File:** `HoehnPhotosMobile/Features/Search/MobileSearchView.swift`

The search grid (line 129) currently has NO context menu.

**Before:**
```swift
ForEach(Array(results.enumerated()), id: \.element.id) { index, photo in
    MobilePhotoCell(photo: photo)
        .aspectRatio(1, contentMode: .fill)
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            selectedPhotoIndex = index
        }
}
```

**After:**
```swift
ForEach(Array(results.enumerated()), id: \.element.id) { index, photo in
    MobilePhotoCell(photo: photo)
        .aspectRatio(1, contentMode: .fill)
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            selectedPhotoIndex = index
        }
        .photoContextMenu(photo: photo, onCurate: { state in
            Task {
                await applyCuration(photo: photo, state: state, db: appDatabase!, syncService: syncService)
            }
        })
}
```

Note: `MobileSearchView` needs `@EnvironmentObject private var syncService: PeerSyncService` added (it currently lacks it).

---

### 3C. Job Detail Photo Grid

**File:** `HoehnPhotosMobile/Features/Jobs/MobileJobsView.swift`

The job detail grid (line 219) already has an inline context menu. Replace it with the reusable component.

**Before:**
```swift
MobilePhotoCell(photo: photo)
    .aspectRatio(1, contentMode: .fill)
    .onTapGesture { selectedPhotoIndex = index }
    .contextMenu {
        Button {
            Task { await setCuration(photo: photo, state: .keeper) }
        } label: {
            Label("Keep", systemImage: CurationState.keeper.systemIcon)
        }
        Button {
            Task { await setCuration(photo: photo, state: .archive) }
        } label: {
            Label("Archive", systemImage: CurationState.archive.systemIcon)
        }
        Button(role: .destructive) {
            Task { await setCuration(photo: photo, state: .rejected) }
        } label: {
            Label("Reject", systemImage: CurationState.rejected.systemIcon)
        }
    }
```

**After:**
```swift
MobilePhotoCell(photo: photo)
    .aspectRatio(1, contentMode: .fill)
    .onTapGesture { selectedPhotoIndex = index }
    .photoContextMenu(photo: photo, onCurate: { state in
        Task { await setCuration(photo: photo, state: state) }
    })
```

Also update `setCuration` in `MobileJobDetailView` to add delta sync:

```swift
private func setCuration(photo: PhotoAsset, state: CurationState) async {
    guard let db = appDatabase else { return }
    try? await MobilePhotoRepository(db: db).updateCurationState(id: photo.id, state: state)
    syncService.enqueueDelta(
        PhotoCurationDelta(photoId: photo.id, curationState: state.rawValue)
    )
    photos = (try? await MobileJobRepository(db: db).fetchPhotos(jobId: job.id)) ?? photos
}
```

---

### 3D. Person Photos Grid

**File:** `HoehnPhotosMobile/Features/People/MobilePeopleView.swift`

The person photo grid (line 203 in `PersonPhotoListView`) currently has NO context menu.

**Before:**
```swift
ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
    MobilePhotoCell(photo: photo)
        .aspectRatio(1, contentMode: .fill)
        .onTapGesture { selectedPhotoIndex = index }
}
```

**After:**
```swift
ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
    MobilePhotoCell(photo: photo)
        .aspectRatio(1, contentMode: .fill)
        .onTapGesture { selectedPhotoIndex = index }
        .photoContextMenu(photo: photo, onCurate: { state in
            Task {
                guard let db = appDatabase else { return }
                try? await MobilePhotoRepository(db: db).updateCurationState(id: photo.id, state: state)
                syncService.enqueueDelta(
                    PhotoCurationDelta(photoId: photo.id, curationState: state.rawValue)
                )
                // Refresh to show updated curation dot
                photos = (try? await MobilePeopleRepository(db: db).fetchPhotosForPerson(personId: person.id)) ?? photos
            }
        })
}
```

---

### 3E. People Grid (Person Cards)

**File:** `HoehnPhotosMobile/Features/People/MobilePeopleView.swift`

Add a context menu to each person card in the people grid (line 30):

```swift
ForEach(people) { person in
    NavigationLink {
        PersonPhotoListView(person: person)
            .environmentObject(syncService)
    } label: {
        personCell(person)
            .task { await loadFaceCrop(for: person) }
    }
    .buttonStyle(.plain)
    .contextMenu {
        Button {
            // Navigate to person detail (programmatic nav)
        } label: {
            Label("View Photos", systemImage: "photo.on.rectangle")
        }
        Button {
            UIPasteboard.general.string = person.name
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } label: {
            Label("Copy Name", systemImage: "doc.on.doc")
        }
    }
}
```

---

## Step 4: Job List Swipe Actions

**File:** `HoehnPhotosMobile/Features/Jobs/MobileJobsView.swift`

Add swipe actions to each job row in the list. The `NavigationLink` rows (line 91) should get `.swipeActions`:

**Before:**
```swift
NavigationLink {
    MobileJobDetailView(job: parent)
        .environmentObject(syncService)
} label: {
    jobRow(parent)
}
.simultaneousGesture(TapGesture().onEnded {
    UISelectionFeedbackGenerator().selectionChanged()
})
```

**After:**
```swift
NavigationLink {
    MobileJobDetailView(job: parent)
        .environmentObject(syncService)
} label: {
    jobRow(parent)
}
.simultaneousGesture(TapGesture().onEnded {
    UISelectionFeedbackGenerator().selectionChanged()
})
.swipeActions(edge: .trailing, allowsFullSwipe: true) {
    Button {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task {
            guard let db = appDatabase else { return }
            try? await MobileJobRepository(db: db).markComplete(jobId: parent.id)
            await loadJobs()
        }
    } label: {
        Label("Complete", systemImage: "checkmark.circle.fill")
    }
    .tint(.green)
}
.swipeActions(edge: .leading, allowsFullSwipe: false) {
    Button {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        // TODO: implement pin/priority
    } label: {
        Label("Pin", systemImage: "pin.fill")
    }
    .tint(.orange)
}
```

Apply the same pattern to child job rows (line 101).

---

## Step 5: Haptic Feedback Patterns

Use these consistently across all interactions:

| Action | Generator | Style |
|--------|-----------|-------|
| Tap photo tile | `UIImpactFeedbackGenerator` | `.light` |
| Context menu curation (keep/archive) | `UIImpactFeedbackGenerator` | `.medium` |
| Context menu curation (reject) | `UIImpactFeedbackGenerator` | `.heavy` |
| Batch curation success | `UINotificationFeedbackGenerator` | `.success` |
| Swipe action complete job | `UINotificationFeedbackGenerator` | `.success` |
| Swipe action (secondary) | `UIImpactFeedbackGenerator` | `.medium` |
| Row selection | `UISelectionFeedbackGenerator` | `.selectionChanged()` |
| Error / failure | `UINotificationFeedbackGenerator` | `.error` |

The haptics are already baked into the `PhotoContextMenu` modifier above. For swipe actions, add them inline as shown.

---

## Checklist

- [ ] Create `HoehnPhotosMobile/Components/PhotoContextMenu.swift`
- [ ] Replace stub context menu in `BentoSectionView.photoTile` with `photoContextMenu`
- [ ] Add `onCurate` callback to `BentoSectionView` and wire in `MobileLibraryView`
- [ ] Add context menu to search grid in `MobileSearchView` (add `syncService` env object)
- [ ] Replace inline context menu in `MobileJobDetailView` with `photoContextMenu`
- [ ] Add delta sync (`enqueueDelta`) to `MobileJobDetailView.setCuration`
- [ ] Add context menu to person photo grid in `PersonPhotoListView`
- [ ] Add context menu to person cards in `MobilePeopleView`
- [ ] Add `.swipeActions` to job list rows (both parent and child) in `MobileJobsView`
- [ ] Verify all curation actions call both local DB write AND `enqueueDelta`
- [ ] Test haptic feedback on physical device (haptics don't work in Simulator)
- [ ] Build and verify context menu previews render correctly
