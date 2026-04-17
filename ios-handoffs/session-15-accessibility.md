# Session 15: Accessibility + Final Polish

## Goal
Add VoiceOver labels to all icon buttons, accessibility hints for non-obvious interactions, Dynamic Type support, touch target verification, error banners, and edge case handling.

---

## 1. Icon-Only Button Audit

Every button that uses only an SF Symbol with no visible text label. VoiceOver users hear nothing useful without an `accessibilityLabel`.

| # | File | Line | Icon | Current Label | Fix |
|---|------|------|------|---------------|-----|
| 1 | MobileLibraryView.swift | 82 | `arrow.clockwise` | None | [ ] `.accessibilityLabel("Reload library")` |
| 2 | MobileLibraryView.swift | 99 | `clock` | None | [ ] `.accessibilityLabel("Activity")` |
| 3 | MobileLibraryView.swift | 109 | `tray.fill` / `tray.full.fill` | None | [ ] `.accessibilityLabel(showStaged ? "Hide staged photos" : "Show staged photos")` |
| 4 | MobileLibraryView.swift | 319 | `hand.thumbsup.fill` (batch Keep) | None | [ ] `.accessibilityLabel("Mark selected as keepers")` |
| 5 | MobileLibraryView.swift | 327 | `archivebox.fill` (batch Archive) | None | [ ] `.accessibilityLabel("Archive selected photos")` |
| 6 | MobileLibraryView.swift | 335 | `hand.thumbsdown.fill` (batch Reject) | None | [ ] `.accessibilityLabel("Reject selected photos")` |
| 7 | MobilePhotoDetailView.swift | 217 | `info.circle` | None | [ ] `.accessibilityLabel("Photo info")` `.accessibilityHint("Shows EXIF metadata and classification")` |
| 8 | MobileSyncView.swift | 45 | `lock.shield` | None | [ ] `.accessibilityLabel("Encrypted connection")` |
| 9 | MobileSyncView.swift | 182 | `doc.on.doc` (copy PIN) | None | [ ] `.accessibilityLabel("Copy PIN to clipboard")` |
| 10 | MemoryDetailView.swift | 39 | `play.fill` (Play Memory) | Has text "Play Memory" | OK -- has visible label |

### Batch action bar buttons (MobileLibraryView.swift lines 316-342)
Each has an icon + "Keep"/"Archive"/"Reject" caption, but the VStack is not grouped:
- [ ] Add `.accessibilityElement(children: .combine)` to each batch button VStack
- [ ] Add `.accessibilityLabel("Keep \(selectedPhotoIDs.count) photos")` etc.

### Rating bar buttons (MobilePhotoDetailView.swift lines 439-465)
Each has icon + label text in a VStack:
- [ ] Add `.accessibilityElement(children: .combine)` to each VStack
- [ ] Add `.accessibilityHint("Double tap to mark this photo as [state]")`

---

## 2. Existing Accessibility (Already Good)

These elements already have proper accessibility:

| File | Line | Element | Label |
|------|------|---------|-------|
| OverflowBadgeTile.swift | 42 | Overflow tile | `accessibilityLabel("Show all photos...")` |
| BentoSkeletonSection.swift | 21, 54 | Skeleton | `accessibilityHidden(true)` |
| MonthSectionHeader.swift | 19 | Section header | `accessibilityAddTraits(.isHeader)` |
| MobilePeopleView.swift | 135, 145 | Person card image | `accessibilityLabel` with name + count |
| MobilePeopleView.swift | 136, 146 | Person card | `accessibilityAddTraits(.isButton)` |
| MobilePeopleView.swift | 155 | Photo count | `accessibilityLabel("Photo count: N")` |
| MobileJobsView.swift | 144, 286 | Job status pill | `accessibilityLabel("Job status: X")` |

---

## 3. VoiceOver Label Templates

### Photo Card (MobilePhotoCell)
```swift
.accessibilityLabel(accessibilityPhotoLabel(photo))
.accessibilityAddTraits(.isButton)

private func accessibilityPhotoLabel(_ photo: PhotoAsset) -> String {
    let state = CurationState(rawValue: photo.curationState)?.title ?? "Uncategorized"
    let name = photo.canonicalName
    return "\(name), \(state)"
}
```
- [ ] MobileLibraryView.swift (MobilePhotoCell, line 472) -- add `accessibilityLabel` and `.isButton` trait

### Photo Card in Selection Mode
```swift
.accessibilityLabel("\(photo.canonicalName), \(isSelected ? "selected" : "not selected")")
.accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
```
- [ ] MobilePhotoCell: Add selection-aware accessibility label and traits

### Person Card (already partially done)
- [ ] PersonCardView: Verify VoiceOver reads name, count, and "button" trait as one element
- [ ] Add `.accessibilityHint("Shows photos of \(person.name)")`

### Job Card
```swift
.accessibilityLabel("\(job.title), \(Int(job.completenessScore * 100)) percent complete, \(job.photoCount) photos, \(job.status.rawValue)")
.accessibilityAddTraits(.isButton)
```
- [ ] MobileJobsView.swift (jobRow, line 122): Add combined accessibility label

### Activity Event
```swift
.accessibilityLabel("\(event.title). \(event.detail ?? "")")
.accessibilityValue(event.createdAt.formatted(date: .abbreviated, time: .shortened))
```
- [ ] MobileActivityView.swift:62-78 -- add accessibility label to event HStack

### Studio Revision Card
```swift
.accessibilityLabel("\(revision.studioMedium.rawValue) render, \(formattedDate(revision.createdAt))")
.accessibilityAddTraits(.isButton)
```
- [ ] MobileStudioHistoryView.swift (StudioRevisionCard, line 184) -- add label

---

## 4. Accessibility Hints for Non-Obvious Interactions

| # | File | Element | Hint |
|---|------|---------|------|
| 1 | MobilePhotoDetailView.swift | Double-tap zoom | [ ] `.accessibilityAction(named: "Toggle zoom") { ... }` |
| 2 | MobilePhotoDetailView.swift | Swipe-up for info | [ ] `.accessibilityAction(named: "Show photo info") { showMetadata = true }` |
| 3 | MobilePhotoDetailView.swift | Horizontal swipe | [ ] `.accessibilityAction(named: "Next photo") { advanceIndex(by: 1) }` and "Previous photo" |
| 4 | MobileLibraryView.swift | Long-press context menu | Already handled by `.contextMenu` modifier (VoiceOver auto-exposes) |
| 5 | OverflowBadgeTile.swift | Tap to expand | Already has label; [ ] add `.accessibilityHint("Double tap to expand and show all photos")` |
| 6 | MemorySlideshowView.swift | Tap to dismiss | [ ] `.accessibilityAction(named: "Dismiss slideshow") { dismiss() }` |
| 7 | MobileSyncView.swift | Connect to peer | [ ] `.accessibilityHint("Double tap to start syncing with this Mac")` |

---

## 5. Dynamic Type Testing Checklist

Test at these text sizes: Default, Large, Extra Large, AX3, AX5 (maximum)

### Elements likely to break:

- [ ] Filter pills (MobileLibraryView.swift): Text may overflow capsule at AX sizes
  - Fix: Add `.minimumScaleFactor(0.8)` and `.lineLimit(1)` to pill text
- [ ] Batch action bar icons + captions: May overlap at large sizes
  - Fix: Use `@ScaledMetric` for icon size, ensure minimum spacing
- [ ] Rating bar (MobilePhotoDetailView.swift): Three buttons may overflow horizontally
  - Fix: Add `.minimumScaleFactor(0.7)` to button labels
- [ ] MonthSectionHeader: Title may truncate
  - Fix: Add `.lineLimit(2)` -- already uses `.title3` which scales
- [ ] MetadataCell (MobilePhotoDetailView.swift): Label may overflow 2-column grid
  - Fix: Consider switching to single column at AX sizes
- [ ] CompletenessRing: Fixed 28pt frame won't scale
  - Fix: Use `@ScaledMetric(relativeTo: .body) private var ringSize: CGFloat = 28`
- [ ] Job status pill: Text may overflow capsule
  - Fix: Add `.lineLimit(1)` and `.minimumScaleFactor(0.8)`
- [ ] FilmstripThumbnail: Fixed 56pt frame
  - Fix: Use `@ScaledMetric` or accept fixed size (thumbnails are touch targets)
- [ ] Person card: Fixed 100pt image frame
  - Fix: Consider `@ScaledMetric` with reasonable max

### Global Dynamic Type checklist:
- [ ] Run app in Simulator with each size (Settings > Accessibility > Larger Text)
- [ ] Screenshot every screen at Default and AX3
- [ ] Verify no text is truncated without ellipsis
- [ ] Verify no text overlaps other elements
- [ ] Verify scrollability still works at large sizes

---

## 6. Touch Target Audit (44pt Minimum)

| # | File | Element | Current Size | Fix |
|---|------|---------|-------------|-----|
| 1 | MobilePhotoCell:504 | Curation dot | 8pt | Not tappable (display only) -- OK |
| 2 | MobileLibraryView.swift:198 | Filter pills | ~32pt tall (6pt padding * 2 + text) | [ ] Increase vertical padding to 10pt or add `.frame(minHeight: 44)` |
| 3 | MobileLibraryView.swift:316-342 | Batch action buttons | VStack is ~44pt+ | Verify -- likely OK |
| 4 | MobilePhotoDetailView.swift:236-253 | Filmstrip thumbnails | 56x56pt | OK |
| 5 | MobilePhotoDetailView.swift:457 | Rating buttons | 60pt wide, ~44pt tall | OK |
| 6 | MobileSearchView.swift:72-83 | Recent search chips | ~32pt tall | [ ] Increase vertical padding to 10pt |
| 7 | MobileSyncView.swift:172-191 | PIN copy button | Text only, small | [ ] Add `.frame(minHeight: 44)` |
| 8 | MobileTabView.swift:107 | "Dismiss" button in sync bar | Text only | [ ] Add `.frame(minHeight: 44)` or ensure bar height >= 44pt |
| 9 | MobileActivityView.swift:62-78 | Event rows | List rows default to 44pt+ | OK |
| 10 | OverflowBadgeTile.swift | Entire tile | Sized by bento grid (~110pt+) | OK |
| 11 | MobileSettingsView.swift | List rows | Default List row height | OK |

---

## 7. Error State Banner Component

Currently errors are shown inline as red text (e.g., MobileLibraryView.swift:233, MobileJobsView.swift:66). Create a reusable banner:

```swift
struct ErrorBanner: View {
    let message: String
    var retryAction: (() -> Void)? = nil
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(3)
            Spacer()
            if let retry = retryAction {
                Button("Retry", action: retry)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.2), in: Capsule())
            }
        }
        .padding(16)
        .background(Color.red, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
        .accessibilityAddTraits(.isStaticText)
    }
}
```

### Deployment locations:
- [ ] Create `ErrorBanner.swift` in HoehnPhotosMobile/Components/
- [ ] MobileLibraryView.swift: Replace `loadError` red text with `ErrorBanner`
- [ ] MobileJobsView.swift: Replace `loadError` red text with `ErrorBanner`
- [ ] MobileSyncView.swift: Replace failed state with `ErrorBanner` + retry
- [ ] Add error banner to MobilePeopleView.swift (currently silently fails)
- [ ] Add error banner to MobileSearchView.swift (currently silently fails)
- [ ] Add error banner to MobileStudioHistoryView.swift (currently prints to console only)

---

## 8. Edge Case Testing Checklist

### 0 Items
- [ ] Library: Empty state shows with correct message and reload button
- [ ] Jobs: Empty state shows with correct message
- [ ] People: Empty state shows with correct message
- [ ] Activity: Empty state shows with correct message
- [ ] Search (no query): Empty state shows search prompt
- [ ] Search (no results): Empty state shows "No results for X"
- [ ] Studio History: Empty state shows correct message
- [ ] Studio Browse: Empty state shows correct message
- [ ] Print Lab: Empty state shows correct message
- [ ] Job Detail (0 photos): Empty state shows correct message
- [ ] Person Detail (0 photos): Empty state shows correct message

### 1 Item
- [ ] Library: Single photo renders in bento layout (Row A only, 1 tile)
- [ ] Jobs: Single job renders without crash
- [ ] People: Single person card renders centered
- [ ] Activity: Single event in section renders
- [ ] Search: Single result renders in grid
- [ ] Studio: Single revision renders

### 1000+ Items
- [ ] Library: LazyVStack + LazyVGrid performs (no frame drops on scroll)
- [ ] Jobs: List scrolls smoothly
- [ ] Search: Results grid scrolls smoothly
- [ ] Memory usage stays under 200MB with proxy images

### No Sync / Empty DB
- [ ] App launches without crash when DB file doesn't exist
- [ ] Library shows "Sync from your Mac first" message
- [ ] Settings > Sync shows "Not connected" state
- [ ] Tab bar still functions, all tabs accessible
- [ ] No console errors spam

### Sync In Progress
- [ ] Sync bar stays visible across tab switches
- [ ] Library auto-reloads on sync completion
- [ ] Progress bar animates smoothly

### DB Errors
- [ ] Missing tables (older DB schema) shows empty state, not crash
- [ ] Read-only DB shows meaningful error
- [ ] Corrupted proxy image shows placeholder, not crash

### Network/State Edge Cases
- [ ] Sync interrupted mid-transfer: shows error, retry works
- [ ] Rapidly switching tabs during load: no race conditions
- [ ] Rapidly tapping filter chips: no duplicate queries
- [ ] Batch select all + curate on 500 photos: doesn't hang UI
- [ ] Photo detail: swipe past last/first photo doesn't crash

---

## 9. Final Ship Checklist

### Accessibility
- [ ] Every icon-only button has `accessibilityLabel`
- [ ] Every non-obvious interaction has `accessibilityHint` or custom action
- [ ] VoiceOver can navigate all screens completely
- [ ] VoiceOver reads photo cards with name + curation state
- [ ] VoiceOver reads job cards with title + completeness + status
- [ ] Reduce Motion setting disables all spring/bounce animations
- [ ] Dynamic Type tested at Default, Large, AX3, AX5
- [ ] No text truncated without visible ellipsis at AX3

### Touch Targets
- [ ] Filter pills >= 44pt touch target
- [ ] Search chips >= 44pt touch target
- [ ] All toolbar buttons >= 44pt touch target (UIKit default handles this)
- [ ] PIN copy button >= 44pt touch target

### Error Handling
- [ ] ErrorBanner component created and deployed
- [ ] All data loading paths show error state on failure
- [ ] No silent failures (console-only errors converted to UI)
- [ ] Retry buttons on all recoverable errors

### Edge Cases
- [ ] All 0-item empty states verified
- [ ] All 1-item layouts verified
- [ ] Performance verified with 1000+ items
- [ ] Empty DB / no sync state verified
- [ ] Interrupted sync recovery verified

### Dark Mode (verify Session 13 complete)
- [ ] All screens verified in both light and dark mode
- [ ] No invisible text or controls in dark mode
- [ ] Status pill backgrounds visible in dark mode

### Animations (verify Session 14 complete)
- [ ] All animations respect Reduce Motion
- [ ] No animation causes frame drops on iPhone SE
- [ ] Empty state fade-in works on all screens
- [ ] CompletenessRing fill animation works

### Final
- [ ] Run full VoiceOver walkthrough of every screen
- [ ] Run Accessibility Inspector audit on every screen
- [ ] Test on physical device (iPhone SE + iPhone 15 Pro)
- [ ] Profile with Instruments for memory leaks on photo detail swipe
- [ ] Archive build succeeds with no warnings
