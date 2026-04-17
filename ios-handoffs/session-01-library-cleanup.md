# Session 1: Library Cleanup + Photo Detail Foundation

## Overview

Remove mock/placeholder data from the mobile library view (locations, memories) and ensure the metadata sheet is properly structured. The metadata sheet and info button already exist, so this session is primarily about deleting dead code.

---

## 1. Remove Mock Locations from MobileLibraryView.swift

**File:** `HoehnPhotosMobile/Features/Library/MobileLibraryView.swift`

### Delete the mock locations property (line 25)

```swift
// DELETE this line:
private let mockLocations = ["Tokyo", "Paris", "London", "New York", "Kyoto"]
```

### Delete the location filter chips in `filterBar` (lines 156-166)

Remove the entire `ForEach` block that renders mock location pills:

```swift
// DELETE this block (inside filterBar, after the CurationState ForEach):
// Location chips -- mock data until GPS is wired
ForEach(mockLocations, id: \.self) { city in
    filterPill(city, isActive: selectedLocation == city, color: .blue) {
        if selectedLocation == city {
            selectedLocation = nil
        } else {
            selectedLocation = city
            selectedFilterRaw = "all"
        }
    }
}
```

### Delete the selectedLocation state property (line 24)

```swift
// DELETE this line:
@State private var selectedLocation: String? = nil
```

Also remove the `selectedLocation == nil` conditions in the "All" pill action (line 146) and the CurationState pills (line 150). After cleanup, the filter pill actions simplify to:

```swift
// "All" pill -- simplify to:
filterPill("All", isActive: selectedFilterRaw == "all", color: .secondary) {
    selectedFilterRaw = "all"
    Task { await resetAndLoad() }
}

// CurationState pills -- simplify isActive condition:
ForEach(CurationState.allCases, id: \.self) { state in
    filterPill(state.title, isActive: selectedFilterRaw == state.rawValue, color: state.tint) {
        selectedFilterRaw = state.rawValue
        Task { await resetAndLoad() }
    }
}
```

### Remove the TODO comment (line 23)

```swift
// DELETE:
// TODO: wire to real EXIF GPS data
```

---

## 2. Remove Mock Memories from MobileLibraryView.swift

**File:** `HoehnPhotosMobile/Features/Library/MobileLibraryView.swift`

### Delete the memories state and mock data (lines 28-33)

```swift
// DELETE these lines:
// Memories state
@State private var selectedMemory: MemoryItem? = nil
private let mockMemories: [MemoryItem] = [
    MemoryItem(id: UUID(), title: "Tokyo Trip", dateRange: "Mar 15-22", photoCount: 48, coverPhotoName: ""),
    MemoryItem(id: UUID(), title: "Paris in Spring", dateRange: "Apr 3-10", photoCount: 31, coverPhotoName: ""),
    MemoryItem(id: UUID(), title: "Kyoto Garden", dateRange: "Mar 28-29", photoCount: 17, coverPhotoName: ""),
]
```

### Delete the `memoriesSection` call in body (line 45)

```swift
// DELETE this line from the VStack in body:
memoriesSection
```

### Delete the entire `memoriesSection` computed property (lines 176-195)

```swift
// DELETE the entire block:
// MARK: - Memories Section

private var memoriesSection: some View {
    ScrollView(.horizontal, showsIndicators: false) {
        ...
    }
    .background(Color(uiColor: .systemBackground))
}
```

### Delete the memory detail sheet modifier (lines 133-135)

```swift
// DELETE this sheet modifier from NavigationStack:
.sheet(item: $selectedMemory) { memory in
    MemoryDetailView(memory: memory, photos: allPhotos)
}
```

---

## 3. Delete Memory View Files

Delete these two files entirely:

- **`HoehnPhotosMobile/Features/Library/MemoryCardView.swift`** -- contains `MemoryItem` model and `MemoryCardView`
- **`HoehnPhotosMobile/Features/Library/MemoryDetailView.swift`** -- contains `MemoryDetailView` and `MemorySlideshowView`

After deleting, remove both files from the Xcode project (`project.pbxproj`) or just delete via Xcode's navigator (Delete > Move to Trash).

---

## 4. Info Button + Metadata Sheet -- Already Implemented

The info button and metadata sheet are **already in place** in `MobilePhotoDetailView.swift`. No new code needed here. For reference, here is how they work:

### Info button (lines 213-219)

Located in the toolbar, top-right:

```swift
ToolbarItem(placement: .topBarTrailing) {
    Button {
        showMetadata = true
    } label: {
        Image(systemName: "info.circle")
            .foregroundStyle(.white)
    }
}
```

### Swipe-up gesture also opens metadata (line 399)

```swift
if dy < -60 {
    showMetadata = true
}
```

### Metadata sheet (lines 470-603)

The `metadataSheet` computed property renders a `NavigationStack` with:
- **EXIF grid** using `MetadataCell` components in a 2-column `LazyVGrid`
- **Fields displayed:** Date, Camera (Make/cameraMake/LensMake), Shutter (ExposureTime/shutterSpeed/ShutterSpeedValue), Aperture (FNumber/aperture/ApertureValue), ISO (ISOSpeedRatings/ISO/iso), Focal Length (FocalLength/focalLength/FocalLengthIn35mmFilm), File name, File size, Dimensions (from loaded UIImage), Color Profile, Bit Depth, Camera Model
- **Location section** (conditional): City (locationCity), Country (locationCountry), GPS (GPSLatitude/latitude + GPSLongitude/longitude)
- **Classification section:** Curation state, Scene type, Modified date
- Presentation detents: `.medium` and `.large`

### EXIF Parsing (line 694-699)

`rawExifJson` is a JSON string stored on `PhotoAsset`. It is parsed via:

```swift
private func parseExif(_ json: String?) -> [String: Any]? {
    guard let json = json,
          let data = json.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return dict
}
```

The JSON is a flat dictionary. Known keys searched across the codebase:
- **Camera:** `Make`, `cameraMake`, `LensMake`, `Model`, `cameraModel`
- **Exposure:** `ExposureTime`, `shutterSpeed`, `ShutterSpeedValue`
- **Aperture:** `FNumber`, `aperture`, `ApertureValue`
- **ISO:** `ISOSpeedRatings`, `ISO`, `iso`
- **Focal:** `FocalLength`, `focalLength`, `FocalLengthIn35mmFilm`
- **Location:** `locationCity`, `locationCountry`, `GPSLatitude`, `latitude`, `GPSLongitude`, `longitude`
- **Other from Mac inspector:** `LensModel`, `Lens`, `DateTimeOriginal`, `CreateDate`

---

## 5. Remove Mock Faces from MobilePhotoDetailView.swift

**File:** `HoehnPhotosMobile/Features/Library/MobilePhotoDetailView.swift`

### Delete MockFace struct and data (lines 102-112)

```swift
// DELETE:
// MARK: - Mock Face Data (TODO: replace with real Vision face detection results)

private struct MockFace: Identifiable {
    let id = UUID()
    let name: String
    var initials: String { name.split(separator: " ").compactMap(\.first).map(String.init).joined() }
}

private let mockFaces: [MockFace] = [
    MockFace(name: "Connor Hoehn"),
    MockFace(name: "Jane Smith"),
]
```

### Remove face overlay from imageContent (lines 143-146)

```swift
// DELETE this overlay modifier from imageContent:
.overlay(alignment: .topTrailing) {
    if !mockFaces.isEmpty {
        faceAvatarsOverlay
    }
}
```

### Delete faceAvatarsOverlay computed property (lines 268-279)

```swift
// DELETE entire block:
// MARK: - Face Avatars Overlay

private var faceAvatarsOverlay: some View {
    HStack(spacing: -12) {
        ForEach(mockFaces) { face in
            ...
        }
    }
    .padding(12)
}
```

---

## Verification Checklist

- [ ] App compiles with no references to `MemoryItem`, `MemoryCardView`, `MemoryDetailView`, `MemorySlideshowView`
- [ ] No references to `mockLocations`, `mockMemories`, `mockFaces`, `selectedLocation`, `selectedMemory`
- [ ] Filter bar shows only "All" + curation state pills (Keeper, Archive, Needs Review, Rejected, Deleted)
- [ ] Info button in photo detail toolbar still opens metadata sheet
- [ ] Swipe-up gesture in photo detail still opens metadata sheet
- [ ] Metadata sheet displays EXIF data correctly from `rawExifJson`
- [ ] No compiler warnings about unused variables
