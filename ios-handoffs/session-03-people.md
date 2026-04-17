# Session 3: People Enhancement

## Scope

- Redesign person cards: 96pt circle face crop, name below, photo count
- Add `.searchable` to filter people by name
- Add sort toggle: "Most Photos" vs "A-Z"
- Improve person detail view: hero face crop at top, 3-col photo grid below
- Tap photo opens `MobilePhotoDetailView`
- Pull-to-refresh (already wired)

## Files to Modify

| File | What changes |
|------|-------------|
| `HoehnPhotosMobile/Features/People/MobilePeopleView.swift` | Redesign `PersonCardView`, redesign `PersonPhotoListView` into `MobilePersonDetailView`, add search + sort |
| `HoehnPhotosMobile/Features/People/FaceCropCache.swift` | No changes needed -- works as-is |
| `HoehnPhotosCore/Database/Repository/MobileRepositories.swift` | No changes needed -- all required methods exist |

---

## Current Data Layer (no changes needed)

### PersonSummary struct (MobileRepositories.swift:220-228)

```swift
public struct PersonSummary: Identifiable {
    public let id: String
    public let name: String
    public let faceCount: Int
    /// ID of a representative face embedding for thumbnail generation.
    public let representativeFaceId: String?
    /// Photo ID for the representative face (used to build proxy URL).
    public let representativePhotoId: String?
}
```

### Available MobilePeopleRepository methods

```swift
public actor MobilePeopleRepository {
    public let db: AppDatabase
    public init(db: AppDatabase)

    /// Returns all named people, ordered by face count DESC.
    public func fetchPeople() async throws -> [PersonSummary]

    /// One representative FaceEmbedding for a person (for thumbnail crop).
    public func fetchFaceForPerson(personId: String) async throws -> FaceEmbedding?

    /// All photos for a person via face_embeddings join, newest first.
    public func fetchPhotosForPerson(personId: String) async throws -> [PhotoAsset]
}
```

### FaceEmbedding model fields used for cropping

```swift
public struct FaceEmbedding {
    public var id: String
    public var photoId: String      // CodingKey: "photo_id"
    public var bboxX: Double        // Vision normalized bbox (origin bottom-left)
    public var bboxY: Double
    public var bboxWidth: Double
    public var bboxHeight: Double
    public var personId: String?    // CodingKey: "person_id"
    // ... other fields
}
```

The iOS `FaceCropCache.swift` extends this with:

```swift
extension FaceEmbedding {
    var bboxRect: CGRect {
        CGRect(x: bboxX, y: bboxY, width: bboxWidth, height: bboxHeight)
    }
}
```

---

## How FaceCropCache Works on iOS

The cache is a Swift `actor` with LRU eviction (max 200 entries). It uses `UIImage` (not `NSImage`).

### Loading pattern (current code in MobilePeopleView.swift:85-116)

```swift
private func loadFaceCrop(for person: MobilePeopleRepository.PersonSummary) async {
    guard let db = appDatabase,
          faceCrops[person.id] == nil else { return }

    // 1. Fetch the representative FaceEmbedding for this person
    let face: FaceEmbedding?
    do {
        face = try await MobilePeopleRepository(db: db).fetchFaceForPerson(personId: person.id)
    } catch { return }
    guard let face else { return }

    // 2. Build proxy URL from the photo's canonical name
    guard let photoAsset = try? await MobilePhotoRepository(db: db).fetchById(face.photoId) else { return }
    let baseName = (photoAsset.canonicalName as NSString).deletingPathExtension
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let proxyURL = appSupport
        .appendingPathComponent("HoehnPhotos")
        .appendingPathComponent("proxies")
        .appendingPathComponent(baseName + ".jpg")

    // 3. Crop using the actor-isolated cache
    let crop = await FaceCropCache.shared.crop(
        id: face.id,
        proxyURL: proxyURL,
        bbox: face.bboxRect
    )
    if let crop {
        faceCrops[person.id] = crop
    }
}
```

The underlying `cropFaceFromProxy` function:
- Uses `CGImageSource` to create a 400px max thumbnail
- Converts Vision bbox (origin bottom-left, normalized 0-1) to pixel coords via `VNImageRectForNormalizedRect`
- Flips Y for CGImage's top-left origin
- Adds 25% padding around the face for context
- Returns `UIImage(cgImage: cropped)`

---

## Current PersonCardView (REPLACE)

Current code at `MobilePeopleView.swift:121-166`:

```swift
private struct PersonCardView: View {
    let person: MobilePeopleRepository.PersonSummary
    let crop: UIImage?
    @State private var isPressed = false

    var body: some View {
        VStack(spacing: 8) {
            if let crop {
                Image(uiImage: crop)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 100, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 100, height: 100)
                    .overlay(
                        Image(systemName: "person.fill")
                            .foregroundStyle(Color.accentColor)
                    )
            }
            Text(person.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Text("\(person.faceCount) photo\(person.faceCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // ... press animation with DragGesture
    }
}
```

### Redesigned PersonCardView (skeleton)

Replace with 96pt circle crop, subtle shadow card, centered layout:

```swift
private struct PersonCardView: View {
    let person: MobilePeopleRepository.PersonSummary
    let crop: UIImage?

    @State private var isPressed = false

    var body: some View {
        VStack(spacing: 10) {
            // 96pt circle face crop
            Group {
                if let crop {
                    Image(uiImage: crop)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(.systemGray5)
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.tertiary)
                        )
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(Circle())

            VStack(spacing: 2) {
                Text(person.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text("\(person.faceCount) photo\(person.faceCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        )
        .contentShape(Rectangle())
        .scaleEffect(isPressed ? 0.96 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}
```

---

## Search + Sort Implementation

### State to add in MobilePeopleView

```swift
@State private var searchText = ""
@State private var sortOrder: PeopleSortOrder = .mostPhotos

enum PeopleSortOrder: String, CaseIterable {
    case mostPhotos = "Most Photos"
    case alphabetical = "A-Z"
}
```

### Computed filtered/sorted array

```swift
private var displayedPeople: [MobilePeopleRepository.PersonSummary] {
    let filtered: [MobilePeopleRepository.PersonSummary]
    if searchText.isEmpty {
        filtered = people
    } else {
        filtered = people.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    switch sortOrder {
    case .mostPhotos:
        return filtered.sorted { $0.faceCount > $1.faceCount }
    case .alphabetical:
        return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
```

Note: `fetchPeople()` already returns results ordered by count DESC, so the `.mostPhotos` sort preserves the DB order. The `.alphabetical` case re-sorts client-side.

### Searchable + toolbar integration

Apply `.searchable` and a toolbar sort picker to the `NavigationStack`:

```swift
var body: some View {
    NavigationStack {
        Group {
            if isLoading && people.isEmpty {
                // ... loading state (unchanged)
            } else if people.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(displayedPeople) { person in
                            // ... same NavigationLink as before
                        }
                    }
                    .padding(12)
                }
            }
        }
        .navigationTitle("People")
        .searchable(text: $searchText, prompt: "Search people")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(PeopleSortOrder.allCases, id: \.self) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
        }
        .task { await loadPeople() }
        .refreshable { await loadPeople() }
    }
}
```

---

## MobilePersonDetailView (skeleton)

Replace the existing `PersonPhotoListView` (MobilePeopleView.swift:170-232) with a redesigned view that has a hero face crop at top and a 3-column photo grid.

```swift
struct MobilePersonDetailView: View {
    let person: MobilePeopleRepository.PersonSummary

    @Environment(\.appDatabase) private var appDatabase
    @EnvironmentObject private var syncService: PeerSyncService
    @State private var photos: [PhotoAsset] = []
    @State private var isLoading = true
    @State private var selectedPhotoIndex: Int?
    @State private var heroCrop: UIImage?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if photos.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        // MARK: Hero section
                        heroSection

                        // MARK: Photo grid
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                                MobilePhotoCell(photo: photo)
                                    .aspectRatio(1, contentMode: .fill)
                                    .onTapGesture { selectedPhotoIndex = index }
                            }
                        }
                    }
                }
                .refreshable { await loadPhotos() }
            }
        }
        .navigationTitle(person.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadAll() }
        .sheet(isPresented: Binding(
            get: { selectedPhotoIndex != nil },
            set: { if !$0 { selectedPhotoIndex = nil } }
        )) {
            if let idx = selectedPhotoIndex {
                MobilePhotoDetailView(photos: photos, initialIndex: idx)
                    .environmentObject(syncService)
            }
        }
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        VStack(spacing: 8) {
            Group {
                if let heroCrop {
                    Image(uiImage: heroCrop)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(.systemGray5)
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(.tertiary)
                        )
                }
            }
            .frame(width: 120, height: 120)
            .clipShape(Circle())

            Text("\(photos.count) photo\(photos.count == 1 ? "" : "s")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.square.badge.camera")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No Photos Found")
                .font(.title3.weight(.semibold))
            Text("Photos with \(person.name) will appear here after face detection runs.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data Loading

    private func loadAll() async {
        await loadPhotos()
        await loadHeroCrop()
    }

    private func loadPhotos() async {
        guard let db = appDatabase else {
            isLoading = false
            return
        }
        photos = (try? await MobilePeopleRepository(db: db).fetchPhotosForPerson(personId: person.id)) ?? []
        isLoading = false
    }

    private func loadHeroCrop() async {
        guard let db = appDatabase else { return }
        guard let face = try? await MobilePeopleRepository(db: db).fetchFaceForPerson(personId: person.id) else { return }
        guard let photoAsset = try? await MobilePhotoRepository(db: db).fetchById(face.photoId) else { return }

        let baseName = (photoAsset.canonicalName as NSString).deletingPathExtension
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let proxyURL = appSupport
            .appendingPathComponent("HoehnPhotos")
            .appendingPathComponent("proxies")
            .appendingPathComponent(baseName + ".jpg")

        heroCrop = await FaceCropCache.shared.crop(
            id: face.id,
            proxyURL: proxyURL,
            bbox: face.bboxRect
        )
    }
}
```

### Update the NavigationLink destination in MobilePeopleView

Change the `NavigationLink` destination from `PersonPhotoListView` to `MobilePersonDetailView`:

```swift
NavigationLink {
    MobilePersonDetailView(person: person)
        .environmentObject(syncService)
} label: {
    personCell(person)
        .task {
            await loadFaceCrop(for: person)
        }
}
```

---

## Existing Dependencies (already available, no new imports needed)

- `MobilePhotoCell` -- defined in `HoehnPhotosMobile/Features/Library/MobileLibraryView.swift:457`
- `MobilePhotoDetailView` -- defined in `HoehnPhotosMobile/Features/Library/MobilePhotoDetailView.swift:66`, takes `(photos: [PhotoAsset], initialIndex: Int)`
- `MobilePhotoRepository` -- used to fetch `PhotoAsset` by ID for proxy URL construction
- `FaceCropCache.shared` -- actor at `HoehnPhotosMobile/Features/People/FaceCropCache.swift`
- `PeerSyncService` -- passed via `@EnvironmentObject`
- `.appDatabase` -- custom `@Environment` key providing optional `AppDatabase`

## Pull-to-Refresh

Already wired on `MobilePeopleView` via `.refreshable { await loadPeople() }`. The new detail view skeleton above also includes `.refreshable { await loadPhotos() }`.

## Checklist

- [ ] Replace `PersonCardView` body with 96pt circle design
- [ ] Add `PeopleSortOrder` enum, `searchText` and `sortOrder` @State
- [ ] Add `displayedPeople` computed property
- [ ] Replace `ForEach(people)` with `ForEach(displayedPeople)`
- [ ] Add `.searchable` and sort toolbar to NavigationStack
- [ ] Rename/replace `PersonPhotoListView` with `MobilePersonDetailView`
- [ ] Add hero section with 120pt circle face crop to detail view
- [ ] Keep 3-col grid + tap-to-detail sheet (already works)
- [ ] Add `.refreshable` to detail view
- [ ] Update NavigationLink destination to `MobilePersonDetailView`
