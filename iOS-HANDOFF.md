# iOS App Handoff: Session-by-Session Plan

> 15 sessions, each scoped to ~1 sitting with Claude. Work front-to-back.
> Every session produces a visible, committable improvement.

---

## Current State

6 tabs working: Library (bento grid), Jobs (list + hierarchy), Search (text),
People (2-col grid), Activity (date-grouped list), Settings (sync + read-only previews).
Sync works via Multipeer Connectivity. All data from shared HoehnPhotosCore framework.

**What's rough:** mock data in Library, no metadata in photo detail, Jobs lacks task
cards, People is shallow, Activity has no filters, Studio/PrintLab buried in Settings,
no haptics/context menus/animations anywhere.

---

## Guiding Principles

- **Read-heavy, write-light.** Mac is the engine. iOS browses, curates, monitors.
- **Every Mac section gets iOS presence.** Not feature-complete — useful read-only + light interaction.
- **Modern iOS patterns.** SF Symbols, system materials, haptics, context menus, swipe actions.
- **No unit tests.** Ship functional UI.
- **Use HoehnPhotosCore.** Models and repos already exist. Don't duplicate.

---

## Architecture Quick Ref

```
HoehnPhotosMobile/
  HoehnPhotosMobileApp.swift       <- @main, injects AppDatabase + PeerSyncService
  MobileTabView.swift              <- TabView + sync status bar
  Features/{Library,Jobs,Search,People,Activity,Settings,Studio}/

HoehnPhotosCore/
  Models/        <- PhotoAsset, TriageJob, PersonIdentity, FaceEmbedding,
                    ActivityEvent, StudioRevision, PrintAttempt, SharedEnums
  Database/
    AppDatabase.swift
    Repository/MobileRepositories.swift  <- MobilePhotoRepo, MobileJobRepo,
                                            MobilePeopleRepo, MobileActivityRepo
  Sync/PeerSyncService.swift
```

---

## What NOT to Build on iOS

Studio rendering, PrintLab canvas/printing, CurveLab editor, Develop mode,
Drive browsing, Import wizard, Film detection, Pipeline execution,
Face clustering/labeling, Cloud sync coordinator. All desktop-only.

---

## Session Breakdown

### Session 1: Library Cleanup + Photo Detail Foundation
**Goal:** Remove junk, make photo detail actually useful.

**Scope:**
- Delete `mockLocations`, `mockMemories` arrays and `MemoryCardView`/`MemoryDetailView` files (or gut the memories section to just a placeholder comment)
- Remove the TODO location filter chips (or hide behind a feature flag)
- In `MobilePhotoDetailView`: add an info button (i) that opens a metadata sheet
- Create `MobilePhotoMetadataSheet.swift`: parse `PhotoAsset.rawExifJson` and display camera, lens, ISO, shutter speed, aperture, date taken, location, file dimensions, file size
- Show curation state badge (Keep/Archive/Reject/NeedsReview) in the metadata sheet header

**Files:** `MobileLibraryView.swift`, `MobilePhotoDetailView.swift`, new `MobilePhotoMetadataSheet.swift`

**Commit:** "feat(ios): photo metadata sheet, remove mock data from library"

---

### Session 2: Library Curation UX
**Goal:** Make rating photos on iPhone feel great.

**Scope:**
- Add a persistent curation button bar at bottom of `MobilePhotoDetailView`: Keep (green checkmark), Archive (blue box), Reject (red X), with labels
- Wire buttons to `syncService.enqueueDelta()` — already exists
- Add `UIImpactFeedbackGenerator(.medium)` on each curation tap
- Show current curation state as highlighted button
- Add context menu (long-press) on photo thumbnails in the bento grid: Keep, Archive, Reject, View Details
- Verify pull-to-refresh reloads data properly

**Files:** `MobilePhotoDetailView.swift`, `MobileLibraryView.swift`, `BentoSectionView.swift`

**Commit:** "feat(ios): curation buttons with haptics, photo context menus"

---

### Session 3: People — Cards + Detail View
**Goal:** Make People tab look like Apple Photos' people view.

**Scope:**
- Redesign `personCell` in `MobilePeopleView`: 96pt circle face crop, name below (`.headline`), photo count below name (`.caption`, `.secondary`)
- Add `.searchable` modifier to filter people by name
- Add sort toggle in toolbar: "Most Photos" vs "A–Z"
- Improve `PersonPhotoListView` (or create `MobilePersonDetailView`): hero face crop at top (large, centered), 3-col photo grid below
- Tap photo in person detail → opens `MobilePhotoDetailView`
- Add pull-to-refresh

**Files:** `MobilePeopleView.swift`, existing `PersonPhotoListView` or new `MobilePersonDetailView.swift`

**Commit:** "feat(ios): redesign people cards, add person detail with photo grid"

---

### Session 4: Jobs — Task Cards + Staged Banner
**Goal:** Jobs detail shows workflow progress, not just photos.

**Scope:**
- In job detail view, add a header section: `CompletenessRing` (48pt), job title, photo count, creation date, status badge
- Add blue info banner when `job.status == .open`: "Photos are staged — not yet visible in Library"
- Add task progress section: 4 compact cards in a 2x2 grid
  - Review & Cull (orange, eye icon) — progress = culled / total
  - Identify People (blue, person icon) — progress = identified / face count
  - Develop Selects (purple, slider icon) — progress from development versions
  - Complete Metadata (teal, text icon) — progress from metadata completeness
- Each card: icon, title, progress bar, "Done" checkmark when complete
- Compute progress from job photos using `MobileJobRepository.fetchPhotos()`

**Files:** `MobileJobsView.swift`

**Commit:** "feat(ios): job task cards with progress, staged photo banner"

---

### Session 5: Jobs — Filmstrip + Actions
**Goal:** Interact with job photos directly.

**Scope:**
- Add horizontal photo filmstrip in job detail (below task cards): up to 20 thumbnails, horizontal scroll
- Each filmstrip thumbnail shows curation badge overlay (green dot = keeper, red = rejected, etc.)
- Tap filmstrip photo → opens `MobilePhotoDetailView` scoped to job photos
- Add "Mark Complete" button in job detail header (green, prominent)
  - If tasks incomplete: show confirmation alert "Some tasks are incomplete. Mark complete anyway?"
  - Calls `MobileJobRepository.markComplete()`
  - Haptic feedback on success
- Add swipe action on job list rows: swipe right → Mark Complete

**Files:** `MobileJobsView.swift`

**Commit:** "feat(ios): job photo filmstrip, mark complete action"

---

### Session 6: Activity — Filters + Detail
**Goal:** Activity becomes a useful dashboard.

**Scope:**
- Add horizontal filter chip bar at top: All, Imports, Studio, Print, Adjustments, Notes
  - Capsule buttons with SF Symbol + label
  - Accent tint when active, filter `events` array by `event.kind`
- Switch to `RelativeDateTimeFormatter` for timestamps ("2h ago", "Yesterday")
- Make event rows tappable → present `MobileEventDetailView` sheet
- Create `MobileEventDetailView.swift`: full title, detail text, timestamp, parsed metadata fields, photo thumbnail if `photoAssetId` set (load from proxy)
- Show per-filter empty state: "No import events yet"

**Files:** `MobileActivityView.swift`, new `MobileEventDetailView.swift`

**Commit:** "feat(ios): activity filter chips, event detail sheet, relative timestamps"

---

### Session 7: Search — Filters + Polish
**Goal:** Search feels powerful with structured filtering.

**Scope:**
- Add filter button in toolbar (`line.3.horizontal.decrease.circle`)
- Create filter sheet with: curation state picker (Any/Keeper/Archive/Rejected), year range picker, grayscale toggle
- Apply filters to search query in `MobilePhotoRepository.search()`
- Show active filters as dismissible capsule chips below search bar
- Add result count header: "42 results" with sort toggle (Date Added / Date Taken)
- Improve empty state: suggest categories ("Try cameras, locations, or dates")
- Add grid density toggle in toolbar: 3-col vs 4-col

**Files:** `MobileSearchView.swift`

**Commit:** "feat(ios): search filters, result count, grid density toggle"

---

### Session 8: Tab Restructure + Studio Repository
**Goal:** Set up the Creative tab and data layer for Studio/PrintLab.

**Scope:**
- Decision: restructure tabs to **Library | Jobs | Search | People | Creative | Settings**
- Create the Creative tab container: segmented control at top with "Studio" and "Print Lab" segments (and optionally "Activity" as third segment, or keep Activity in Settings)
- Add `MobileStudioRepository` to `MobileRepositories.swift`:
  - `fetchAll(limit:)` → all StudioRevisions ordered by date
  - `fetchForPhoto(photoId:)` → revisions for specific photo
  - `fetchGroupedByMedium()` → dictionary of medium → revisions
- Add `MobilePrintRepository` to `MobileRepositories.swift`:
  - `fetchAll(limit:)` → all print attempts ordered by date
  - `fetchForPhoto(photoId:)` → attempts for specific photo
- Update `MobileTabView.swift` with new tab structure
- Move Activity to Settings or keep as separate tab (your call at session time)

**Files:** `MobileTabView.swift`, `MobileRepositories.swift`, new `MobileCreativeView.swift`

**Commit:** "feat(ios): creative tab, studio + print repositories"

---

### Session 9: Studio Gallery + Detail
**Goal:** Browse all studio renders with filtering.

**Scope:**
- Create `MobileStudioGalleryView.swift`: 2-col grid of all StudioRevisions
  - Card: thumbnail, medium icon badge (bottom-left corner), photo name, date
  - Rounded corners (12pt), subtle shadow
- Add medium filter chips at top: All, Oil, Watercolor, Charcoal, Graphite, etc.
  - Use `StudioMedium` enum for names and icons
- Create `MobileStudioDetailView.swift`: tap a card to see
  - Full-bleed render image (pinch to zoom)
  - Overlay bar at bottom: medium name, parameter summary, source photo, date
  - "View Original" button to show source photo
- Wire into Creative tab's "Studio" segment

**Files:** new `MobileStudioGalleryView.swift`, new `MobileStudioDetailView.swift`, `MobileCreativeView.swift`

**Commit:** "feat(ios): studio gallery with medium filters, detail view"

---

### Session 10: PrintLab History + Detail
**Goal:** Browse print history with useful context.

**Scope:**
- Create `MobilePrintLabView.swift`: vertical list of print attempts
  - Row: photo thumbnail (left), print type icon circle, paper name, outcome badge, date
  - Group by date (Today/Yesterday/older) like Activity
- Add print type filter chips: All, Inkjet B&W, Inkjet Color, Platinum, Cyanotype, etc.
- Create `MobilePrintDetailView.swift`: tap to see
  - Photo thumbnail (large)
  - Config section: print type, paper, ink, curve name
  - Outcome section: notes, comparison scan if available
  - Date and metadata
- Wire into Creative tab's "Print Lab" segment
- Remove "View Only" PrintLab/Studio from `MobileSettingsView.swift`

**Files:** new `MobilePrintLabView.swift`, new `MobilePrintDetailView.swift`, `MobileCreativeView.swift`, `MobileSettingsView.swift`

**Commit:** "feat(ios): print lab history view, detail view, remove from settings"

---

### Session 11: Skeleton Loaders Everywhere
**Goal:** Replace all "Loading..." spinners with shimmer skeletons.

**Scope:**
- Create a reusable `SkeletonView` component (or extend `BentoSkeletonSection` pattern):
  - `SkeletonRect(width:height:cornerRadius:)` — shimmer-animated rounded rect
  - `SkeletonCircle(size:)` — for face crops, icons
  - `SkeletonRow` — icon circle + two text lines (for list views)
- Replace loading states in:
  - `MobileJobsView` → skeleton job rows
  - `MobilePeopleView` → skeleton person cards (circle + text)
  - `MobileActivityView` → skeleton event rows
  - `MobileSearchView` → skeleton grid
  - `MobileStudioGalleryView` → skeleton cards
  - `MobilePrintLabView` → skeleton rows
- Use `.redacted(reason: .placeholder)` where simpler (SwiftUI built-in)

**Files:** new `SkeletonComponents.swift` (shared), all view files above

**Commit:** "feat(ios): shimmer skeleton loaders for all tabs"

---

### Session 12: Context Menus + Swipe Actions
**Goal:** Add iOS-native interaction patterns everywhere.

**Scope:**
- **Photo context menus** (Library grid, Search grid, Job filmstrip, Person photos):
  - Keep / Archive / Reject / Needs Review (with SF Symbols + colors)
  - View Details (opens detail view)
  - Divider
  - Share (UIActivityViewController)
- **People context menus**: View All Photos
- **Job list swipe actions**: Swipe right → Mark Complete (green checkmark)
- **Activity swipe actions**: Swipe right → Pin/Unpin note (if applicable)
- **Consistent haptics**: `.medium` impact on curation, `.light` on navigation, `.success` notification on complete

**Files:** All view files — systematic pass

**Commit:** "feat(ios): context menus and swipe actions across all tabs"

---

### Session 13: Dark Mode + Color Audit
**Goal:** App looks great in both light and dark mode.

**Scope:**
- Audit every custom color usage — replace hardcoded colors with system equivalents:
  - Backgrounds: `.systemBackground`, `.secondarySystemBackground`, `.tertiarySystemBackground`
  - Text: `.label`, `.secondaryLabel`, `.tertiaryLabel`
  - Fills: `.systemFill`, `.secondarySystemFill`
- Verify curation state colors work in dark mode (green/red/blue/orange)
- Check card shadows aren't invisible in dark mode — use `.shadow(color: .black.opacity(0.15), ...)` 
- Verify sync status bar colors work in both modes
- Test filter chips contrast in both modes
- Fix any `.white` or `.black` hardcoded backgrounds

**Files:** All view files — systematic audit

**Commit:** "fix(ios): dark mode color audit, use system colors throughout"

---

### Session 14: Animation + Transitions
**Goal:** Everything feels smooth and alive.

**Scope:**
- Add `.animation(.spring(duration: 0.3), value:)` to:
  - Filter chip selection changes
  - Batch selection bar appear/disappear (already has `.transition(.move)` — verify)
  - Grid layout changes (column count toggle)
  - Tab content switches
- Add `.matchedGeometryEffect` for photo grid → detail transition (if feasible)
- Smooth expand/collapse for job child rows (`.animation(.easeInOut(duration: 0.2))`)
- Curation button press: scale down briefly (`.scaleEffect` + spring)
- Completeness ring: animate ring fill on appear
- Empty state: fade in on appear (`.transition(.opacity)`)
- Pull-to-refresh: verify smooth completion

**Files:** All view files — systematic pass

**Commit:** "feat(ios): spring animations and smooth transitions"

---

### Session 15: Accessibility + Final Polish
**Goal:** Ship-ready quality pass.

**Scope:**
- **Accessibility:**
  - `.accessibilityLabel` on all icon-only buttons ("Mark as keeper", "Filter by medium", etc.)
  - `.accessibilityHint` on non-obvious interactions ("Double tap to view photo details")
  - Verify VoiceOver reads photo cards: "{photo name}, {curation state}, {date}"
  - Verify Dynamic Type works — test with largest accessibility text size
  - Check touch targets are ≥44pt
- **Empty states:** Verify every view has a consistent empty state (icon + title + subtitle)
- **Error states:** Add inline error banners with retry button where data loading can fail
- **Safe areas:** Verify no content clips under sync bar, home indicator, or notch
- **Edge cases:** Test with 0 photos, 1 photo, 1000+ photos. Test with no sync (empty DB).
- **App icon + launch screen:** Verify they look correct

**Files:** All view files — systematic audit

**Commit:** "fix(ios): accessibility labels, error states, edge case handling"

---

## Session Dependency Map

```
Session 1  (Library cleanup + metadata sheet)
Session 2  (Library curation UX)          ← needs Session 1
Session 3  (People redesign)              ← independent
Session 4  (Jobs task cards)              ← independent
Session 5  (Jobs filmstrip + actions)     ← needs Session 4
Session 6  (Activity filters + detail)    ← independent
Session 7  (Search filters)              ← independent
Session 8  (Tab restructure + repos)      ← independent, but do before 9-10
Session 9  (Studio gallery + detail)      ← needs Session 8
Session 10 (PrintLab history + detail)    ← needs Session 8
Session 11 (Skeleton loaders)             ← do after most views exist (after 10)
Session 12 (Context menus + swipes)       ← do after most views exist (after 10)
Session 13 (Dark mode audit)              ← do after all views built (after 12)
Session 14 (Animations)                   ← do after all views built (after 12)
Session 15 (Accessibility + final)        ← last
```

**Parallelizable groups** (sessions you could do in any order):
- Group A: Sessions 1-2 (Library)
- Group B: Session 3 (People)
- Group C: Sessions 4-5 (Jobs)
- Group D: Session 6 (Activity)
- Group E: Session 7 (Search)
- Group F: Sessions 8-10 (Creative tab)
- Group G: Sessions 11-15 (Polish — do last, in order)

---

## Files to Create (all sessions)

```
MobilePhotoMetadataSheet.swift      <- Session 1
MobilePersonDetailView.swift        <- Session 3  (if PersonPhotoListView insufficient)
MobileEventDetailView.swift         <- Session 6
MobileCreativeView.swift            <- Session 8
MobileStudioGalleryView.swift       <- Session 9
MobileStudioDetailView.swift        <- Session 9
MobilePrintLabView.swift            <- Session 10
MobilePrintDetailView.swift         <- Session 10
SkeletonComponents.swift            <- Session 11
```

## Files to Modify (all sessions)

```
MobileLibraryView.swift             <- Sessions 1, 2
MobilePhotoDetailView.swift         <- Sessions 1, 2
MobileJobsView.swift                <- Sessions 4, 5
MobilePeopleView.swift              <- Session 3
MobileActivityView.swift            <- Session 6
MobileSearchView.swift              <- Session 7
MobileTabView.swift                 <- Session 8
MobileSettingsView.swift            <- Session 10
MobileRepositories.swift            <- Session 8
BentoSectionView.swift              <- Session 2
All view files                      <- Sessions 11-15 (polish passes)
```
