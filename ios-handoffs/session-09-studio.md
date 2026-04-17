# Session 9: Studio Gallery + Detail

## Goal
Build `MobileStudioGalleryView` with medium filter chips and a 2-column grid of renders, plus `MobileStudioDetailView` with full-bleed image and metadata overlay. These replace the existing `MobileStudioBrowseView` and `StudioRevisionDetailView` in `MobileStudioHistoryView.swift`.

---

## Key Files

| File | Role |
|------|------|
| `HoehnPhotosMobile/Features/Studio/MobileStudioHistoryView.swift` | Existing views to replace/enhance |
| `HoehnPhotosCore/Models/StudioRevision.swift` | Shared model + StudioMedium enum + StudioParameters |
| `HoehnPhotosCore/Database/Repository/MobileRepositories.swift` | `MobileStudioRepository` (added in session 8) |
| `HoehnPhotosMobile/Features/Creative/MobileCreativeView.swift` | Parent container (session 8) |

---

## StudioRevision Model (HoehnPhotosCore)

Already exists and is fully defined. No changes needed.

```swift
public struct StudioRevision: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "studio_revisions"

    public var id: String            // UUID string
    public var photoId: String       // FK to photo_assets.id
    public var name: String          // e.g. "Oil Painting -- Mar 30, 2026"
    public var medium: String        // StudioMedium.rawValue e.g. "Oil Painting"
    public var paramsJson: String    // JSON-encoded StudioParameters
    public var createdAt: String     // ISO 8601
    public var thumbnailPath: String? // Relative path under AppSupport/HoehnPhotos/studio/
    public var fullResPath: String?  // Relative path to full-res render

    // CodingKeys: photo_id, params_json, created_at, thumbnail_path, full_res_path

    // Convenience accessors:
    public var studioMedium: StudioMedium { ... }   // Decoded enum, falls back to .oil
    public var parameters: StudioParameters? { ... } // Decoded from paramsJson
}
```

### StudioParameters
```swift
public struct StudioParameters: Equatable, Codable {
    public var brushSize: Double       // 1-20
    public var detail: Double          // 0-1
    public var texture: Double         // 0-1
    public var colorSaturation: Double // 0-1
    public var contrast: Double        // 0-1
}
```

---

## StudioMedium Enum (HoehnPhotosCore)

Already defined in `StudioRevision.swift`. All 9 cases with SF Symbol icons:

```swift
public enum StudioMedium: String, CaseIterable, Identifiable, Codable {
    case oil = "Oil Painting"          // icon: "drop.fill"
    case watercolor = "Watercolor"     // icon: "drop.triangle"
    case charcoal = "Charcoal"         // icon: "scribble"
    case troisCrayon = "Trois Crayon"  // icon: "pencil.and.outline"
    case graphite = "Graphite"         // icon: "pencil"
    case inkWash = "Ink Wash"          // icon: "paintbrush"
    case pastel = "Pastel"             // icon: "circle.lefthalf.filled"
    case penAndInk = "Pen & Ink"       // icon: "pencil.tip"
    case mezzotint = "Mezzotint"       // icon: "square.grid.3x3.fill"

    public var icon: String { ... }
    public var displayDescription: String { ... }
}
```

---

## Thumbnail Loading Pattern

The existing `StudioRevisionCard` in `MobileStudioHistoryView.swift` already handles thumbnail loading. The pattern:

```swift
let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
let url = appSupport
    .appendingPathComponent("HoehnPhotos")
    .appendingPathComponent("studio")
    .appendingPathComponent(revision.thumbnailPath!)  // relative path stored in DB
```

Full-res follows the same pattern with `revision.fullResPath`.

Reuse this logic -- do not change the path structure.

---

## MobileStudioGalleryView

New file: `HoehnPhotosMobile/Features/Creative/MobileStudioGalleryView.swift`

This replaces `MobileStudioBrowseView` as the Studio content inside `MobileCreativeView`. Key differences from existing browse view: adds medium filter chips at the top.

```swift
import SwiftUI
import HoehnPhotosCore

struct MobileStudioGalleryView: View {

    @Environment(\.appDatabase) private var appDatabase
    @State private var allRevisions: [StudioRevision] = []
    @State private var isLoading = true
    @State private var selectedMedium: StudioMedium?  // nil = "All"
    @State private var selectedRevision: StudioRevision?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    private var filteredRevisions: [StudioRevision] {
        guard let medium = selectedMedium else { return allRevisions }
        return allRevisions.filter { $0.medium == medium.rawValue }
    }

    /// Mediums that actually have renders (for chip visibility).
    private var availableMediums: [StudioMedium] {
        let present = Set(allRevisions.map(\.medium))
        return StudioMedium.allCases.filter { present.contains($0.rawValue) }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if allRevisions.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    mediumFilterChips
                    revisionGrid
                }
            }
        }
        .task { await loadRevisions() }
        .sheet(item: $selectedRevision) { revision in
            MobileStudioDetailView(revision: revision)
        }
    }

    // MARK: - Filter Chips

    private var mediumFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // "All" chip
                FilterChip(
                    label: "All",
                    icon: "paintpalette",
                    isSelected: selectedMedium == nil,
                    count: allRevisions.count
                ) {
                    selectedMedium = nil
                }

                // Per-medium chips
                ForEach(availableMediums) { medium in
                    let count = allRevisions.filter { $0.medium == medium.rawValue }.count
                    FilterChip(
                        label: medium.rawValue,
                        icon: medium.icon,
                        isSelected: selectedMedium == medium,
                        count: count
                    ) {
                        selectedMedium = (selectedMedium == medium) ? nil : medium
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Grid

    private var revisionGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(filteredRevisions) { revision in
                    StudioRevisionCard(revision: revision)
                        .onTapGesture {
                            selectedRevision = revision
                        }
                }
            }
            .padding(16)
        }
        .refreshable {
            await loadRevisions()
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "paintpalette")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No Studio Renders")
                .font(.title3.weight(.semibold))
            Text("Render artistic versions of your photos on Mac, then sync to see them here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading

    private func loadRevisions() async {
        guard let db = appDatabase else {
            isLoading = false
            return
        }
        do {
            allRevisions = try await MobileStudioRepository(db: db).fetchAllRevisions()
        } catch {
            print("[StudioGallery] Load error: \(error)")
        }
        isLoading = false
    }
}
```

---

## FilterChip (Reusable Component)

Create a shared chip view for use in both Studio and Print Lab:

File: `HoehnPhotosMobile/Features/Creative/FilterChip.swift`

```swift
import SwiftUI

struct FilterChip: View {
    let label: String
    let icon: String
    let isSelected: Bool
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.caption.weight(.medium))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10).weight(.semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            isSelected
                                ? Color.white.opacity(0.3)
                                : Color(uiColor: .tertiarySystemFill)
                        )
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentColor : Color(uiColor: .secondarySystemBackground))
            .foregroundStyle(isSelected ? .white : .primary)
            .clipShape(Capsule())
        }
    }
}
```

---

## MobileStudioDetailView

This replaces `StudioRevisionDetailView` in `MobileStudioHistoryView.swift`. Same core behavior (full-bleed image + metadata bar) but enhanced with source photo info.

```swift
import SwiftUI
import HoehnPhotosCore

struct MobileStudioDetailView: View {
    let revision: StudioRevision
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appDatabase) private var appDatabase
    @State private var fullImage: UIImage?
    @State private var sourcePhoto: PhotoAsset?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let img = fullImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                } else if revision.fullResPath != nil {
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text("Loading render...")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: revision.studioMedium.icon)
                            .font(.system(size: 56))
                            .foregroundStyle(.white.opacity(0.3))
                        Text("Full resolution not synced")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                metadataBar
            }
            .navigationTitle(revision.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .task {
                loadFullRes()
                await loadSourcePhoto()
            }
        }
    }

    // MARK: - Metadata Bar

    private var metadataBar: some View {
        VStack(spacing: 8) {
            // Medium + date row
            HStack(spacing: 12) {
                Label(revision.studioMedium.rawValue, systemImage: revision.studioMedium.icon)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(formattedDate(revision.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Parameters row
            if let params = revision.parameters {
                HStack(spacing: 16) {
                    paramPill("Brush", value: String(format: "%.0f", params.brushSize))
                    paramPill("Detail", value: String(format: "%.0f%%", params.detail * 100))
                    paramPill("Texture", value: String(format: "%.0f%%", params.texture * 100))
                    paramPill("Sat", value: String(format: "%.0f%%", params.colorSaturation * 100))
                    paramPill("Contrast", value: String(format: "%.0f%%", params.contrast * 100))
                }
            }

            // Source photo info
            if let photo = sourcePhoto {
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(photo.canonicalName ?? "Source photo")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    private func paramPill(_ label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.caption.weight(.semibold))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Loading

    private func loadFullRes() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let studioDir = appSupport
            .appendingPathComponent("HoehnPhotos")
            .appendingPathComponent("studio")

        // Try full-res first
        if let fullPath = revision.fullResPath {
            let url = studioDir.appendingPathComponent(fullPath)
            if let data = try? Data(contentsOf: url),
               let img = UIImage(data: data) {
                fullImage = img
                return
            }
        }

        // Fall back to thumbnail
        if let thumbPath = revision.thumbnailPath {
            let url = studioDir.appendingPathComponent(thumbPath)
            if let data = try? Data(contentsOf: url),
               let img = UIImage(data: data) {
                fullImage = img
            }
        }
    }

    private func loadSourcePhoto() async {
        guard let db = appDatabase else { return }
        do {
            sourcePhoto = try await MobilePhotoRepository(db: db).fetchById(revision.photoId)
        } catch {
            print("[StudioDetail] Source photo load error: \(error)")
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
}
```

---

## Existing Code to Reuse

The `StudioRevisionCard` in `MobileStudioHistoryView.swift` (line 180-267) is already well-built. Reuse it directly -- it handles thumbnail loading, medium icon overlay, and date formatting. No need to rewrite it.

The `MobileStudioHistoryView` (per-photo history) should remain as-is. It is navigated to from photo detail views. The new `MobileStudioGalleryView` is the top-level browse across ALL photos.

---

## File Organization

After session 9, the Studio feature folder should look like:

```
HoehnPhotosMobile/Features/
  Creative/
    MobileCreativeView.swift          (session 8)
    MobileStudioGalleryView.swift     (this session)
    MobileStudioDetailView.swift      (this session)
    FilterChip.swift                  (shared component)
  Studio/
    MobileStudioHistoryView.swift     (existing -- per-photo history, keep as-is)
```

---

## Verification Checklist

- [ ] Gallery shows 2-col grid of all revisions, newest first
- [ ] Medium filter chips appear only for mediums that have renders
- [ ] Tapping "All" shows everything; tapping a medium filters; re-tapping deselects
- [ ] Chip counts are accurate
- [ ] Tapping a card opens detail sheet with full-bleed image
- [ ] Detail shows medium name, icon, parameters, date, and source photo name
- [ ] Full-res loads if synced; falls back to thumbnail; shows placeholder if neither exists
- [ ] Pull-to-refresh reloads the gallery
- [ ] Empty state shows when no revisions exist
