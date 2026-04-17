# Session 13: Dark Mode + Color Audit

## Goal
Audit all custom colors, replace hardcoded values with system equivalents, verify curation state colors in both light and dark mode, fix card shadows and backgrounds.

---

## 1. Hardcoded Color Catalog

Every instance of a non-system color or `Color(uiColor:)` that needs review:

### Color(uiColor: .systemBackground)
These are fine -- `.systemBackground` adapts to dark mode automatically.

| File | Line | Current | Action |
|------|------|---------|--------|
| MobileLibraryView.swift | 171 | `Color(uiColor: .systemBackground)` | OK -- adapts |
| MobileLibraryView.swift | 194 | `Color(uiColor: .systemBackground)` | OK -- adapts |
| MobileLibraryView.swift | 345 | `Color(uiColor: .systemBackground)` | OK -- adapts |
| MonthSectionHeader.swift | 18 | `Color(uiColor: .systemBackground)` | OK -- adapts |

### Color(uiColor: .secondarySystemBackground)
These adapt but verify contrast in dark mode:

| File | Line | Current | Action |
|------|------|---------|--------|
| MobilePhotoCell (MobileLibraryView.swift) | 474 | `Color(uiColor: .secondarySystemBackground)` | OK -- adapts |
| MobilePhotoDetailView.swift | 15 | `Color(uiColor: .systemGray6)` | OK -- adapts |
| MobilePhotoDetailView.swift | 59 | `Color(uiColor: .secondarySystemBackground)` | OK -- adapts |
| MobileJobsView.swift | 303 | `Color(uiColor: .secondarySystemBackground)` | OK -- adapts |
| MobileTabView.swift | 76 | `Color(uiColor: .secondarySystemBackground)` | OK -- adapts |
| MobileTabView.swift | 97 | `Color(uiColor: .secondarySystemBackground)` | OK -- adapts |
| MobileTabView.swift | 124 | `Color(uiColor: .secondarySystemBackground)` | OK -- adapts |
| OverflowBadgeTile.swift | 25 | `Color(uiColor: .secondarySystemBackground)` | OK -- adapts |
| MobileSearchView.swift | 80 | `Color(uiColor: .secondarySystemBackground)` | OK -- adapts |
| BentoSkeletonSection.swift | 15 | `Color(uiColor: .systemFill)` | OK -- adapts |
| MobileSettingsView.swift | 70, 149 | `Color(uiColor: .secondarySystemBackground)` | OK -- adapts |
| StudioRevisionCard (MobileStudioHistoryView.swift) | 187 | `Color(uiColor: .secondarySystemBackground)` | OK -- adapts |

### Hardcoded Colors That Need Dark Mode Fixes

| # | File | Line | Current | Replace With | Notes |
|---|------|------|---------|-------------|-------|
| 1 | MobilePhotoDetailView.swift | 140 | `Color.black.ignoresSafeArea()` | Keep -- intentional dark photo viewer | |
| 2 | MobilePhotoDetailView.swift | 182 | `Color.black.opacity(0.5)` | Keep -- overlay on black BG | |
| 3 | MobilePhotoDetailView.swift | 200 | `Color.black.opacity(0.6)` | Keep -- zoom badge on black BG | |
| 4 | MobilePhotoDetailView.swift | 256 | `.background(Color.black)` | Keep -- filmstrip on dark BG | |
| 5 | MobilePhotoDetailView.swift | 30 | `.stroke(Color.white, lineWidth: ...)` | Keep -- filmstrip border on black BG | |
| 6 | MobilePhotoDetailView.swift | 275 | `Circle().fill(Color(uiColor: .systemGray4))` | Keep -- face avatar on dark BG | |
| 7 | OverflowBadgeTile.swift | 31 | `Color.black.opacity(0.55)` | Keep -- scrim on photo tile | |
| 8 | MemoryCardView.swift | 62 | `Color.indigo.opacity(0.6), Color.purple.opacity(0.8)` | **Review** -- gradient placeholder; verify contrast on dark BG | |
| 9 | MemorySlideshowView.swift | 86 | `Color.black.ignoresSafeArea()` | Keep -- slideshow BG | |
| 10 | StudioRevisionDetailView.swift | 280 | `Color.black.ignoresSafeArea()` | Keep -- full-screen preview | |

### Hardcoded .white and .black on adaptive backgrounds

These are the actual problem spots:

| # | File | Line | Current | Fix |
|---|------|------|---------|-----|
| 1 | MobilePhotoCell (MobileLibraryView.swift) | 515 | `Color.black.opacity(0.3)` selection overlay | **OK** -- on photo image, not on adaptive BG |
| 2 | MobilePhotoCell (MobileLibraryView.swift) | 517 | `.foregroundStyle(.white)` checkmark on selection | **OK** -- on black overlay |
| 3 | MobilePhotoDetailView.swift | 211 | `Button("Done") ... .foregroundStyle(.white)` | **OK** -- on black nav bar |

### Opacity-Based Status Colors

| # | File | Line | Current | Fix |
|---|------|------|---------|-----|
| 1 | MobileJobsView.swift | 138-143 | `Color.green.opacity(0.15)` / `Color.orange.opacity(0.15)` | [ ] **Verify contrast in dark mode** -- 0.15 opacity on dark BG may be invisible |
| 2 | MobileJobsView.swift | 279-285 | Same pattern in detail view | [ ] Same fix needed |
| 3 | MobileTabView.swift | 113 | `Color.green.opacity(0.1)` completed sync bar | [ ] Verify visibility in dark mode |
| 4 | MobileTabView.swift | 137 | `Color.orange.opacity(0.1)` pending deltas bar | [ ] Verify visibility in dark mode |

---

## 2. System Color Cheat Sheet

| Pattern | System Equivalent | Notes |
|---------|------------------|-------|
| Page background | `Color(uiColor: .systemBackground)` | Already used correctly |
| Card/section background | `Color(uiColor: .secondarySystemBackground)` | Already used correctly |
| Shimmer/skeleton fill | `Color(uiColor: .systemFill)` / `.secondarySystemFill` | Already used correctly |
| Primary text | `.foregroundStyle(.primary)` | Already used correctly |
| Secondary text | `.foregroundStyle(.secondary)` | Already used correctly |
| Divider | `Divider()` | Already using system divider |
| Navigation bar on dark BG | `.toolbarBackground(.black, ...)` | Used in photo detail -- correct |
| Status pill background | Use `Color(.systemGray5)` instead of color.opacity(0.15) | Better dark mode contrast |

---

## 3. Curation State Colors

Defined in `SharedEnums.swift` (HoehnPhotosCore):

| State | Color | Dark Mode Notes |
|-------|-------|----------------|
| keeper | `.green` | System green adapts automatically |
| archive | `.blue` | System blue adapts automatically |
| needsReview | `.orange` | System orange adapts automatically |
| rejected | `.red` | System red adapts automatically |
| deleted | `.gray` | System gray adapts automatically |

These are all system colors and adapt correctly. The issue is how they are used:

### Curation dot (MobilePhotoCell line 504)
```swift
Circle().fill(state.tint).frame(width: 8, height: 8)
```
- [ ] Verify 8pt dot is visible on dark mode photo cell backgrounds
- [ ] Consider adding a 1pt white stroke for contrast on dark images

### Filter pill (MobileLibraryView.swift line 197-208)
```swift
.background(Capsule().fill(isActive ? color : color.opacity(0.15)))
```
- [ ] Change inactive fill from `color.opacity(0.15)` to `color.opacity(0.2)` for dark mode visibility
- [ ] Alternatively use `Color(.systemGray5)` for inactive pills

### Job status pill (MobileJobsView.swift lines 137-143)
```swift
Capsule().fill(job.status == .complete ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
```
- [ ] Increase opacity to 0.2 or use `Color(.systemGray5)` tinted approach

---

## 4. Shadow Patterns

Currently NO shadows are used anywhere in the mobile app. If adding shadows:

```swift
// Light mode shadow that disappears in dark mode
.shadow(color: Color(.sRGBLinear, white: 0, opacity: 0.1), radius: 4, y: 2)

// Alternative: use .shadow only in light mode
@Environment(\.colorScheme) var colorScheme
.shadow(radius: colorScheme == .dark ? 0 : 4)
```

- [ ] Consider adding subtle shadow to MemoryCardView for depth in light mode
- [ ] Consider adding shadow to batch action bar divider area

---

## 5. Dark Mode Verification Checklist

### Library Tab
- [ ] Filter bar background blends with nav bar in dark mode
- [ ] Inactive filter pills are visible (not washed out)
- [ ] Active filter pills have sufficient contrast
- [ ] Curation dots visible on dark photo cells
- [ ] Selection checkmark overlay visible
- [ ] Batch action bar background matches system
- [ ] Month section headers readable with pinned sticky behavior
- [ ] Skeleton shimmer visible but subtle
- [ ] Empty state icon (`.tertiary`) visible
- [ ] Memory cards: gradient placeholder visible
- [ ] Memory cards: text overlay on gradient readable

### Photo Detail
- [ ] All intentionally dark (black BG) -- verify no regressions
- [ ] Rating bar `.ultraThinMaterial` looks good in dark mode
- [ ] Metadata sheet cards (`secondarySystemBackground`) have contrast
- [ ] Filmstrip thumbnails: white border visible on selected

### Jobs Tab
- [ ] Job status pills visible in dark mode (green/orange on dark BG)
- [ ] CompletenessRing: `ringColor.opacity(0.2)` track visible in dark mode
- [ ] Job info section card background has contrast
- [ ] Empty state visible

### Search Tab
- [ ] Recent search chips visible (`secondarySystemBackground`)
- [ ] Empty state icons visible

### People Tab
- [ ] Person card placeholder (`.accentColor.opacity(0.15)`) visible in dark mode
- [ ] Person name/count text readable

### Activity Tab
- [ ] Event icon circles (`.accentColor.opacity(0.1)`) visible in dark mode
- [ ] Date hierarchy section headers readable

### Sync/Settings
- [ ] Sync status bar backgrounds visible
- [ ] Completed sync bar (`Color.green.opacity(0.1)`) visible
- [ ] Pending deltas bar (`Color.orange.opacity(0.1)`) visible
- [ ] PIN copy button and "Copied!" badge visible
- [ ] Error state (`.red`) visible

### Studio
- [ ] StudioRevisionCard placeholder visible
- [ ] Info overlay gradient works on both light/dark cards
- [ ] StudioRevisionDetailView -- all black BG, verify no issues

---

## 6. Specific Fixes Checklist

- [ ] MobileJobsView.swift:138 -- change `Color.green.opacity(0.15)` to `Color.green.opacity(0.2)`
- [ ] MobileJobsView.swift:140 -- change `Color.orange.opacity(0.15)` to `Color.orange.opacity(0.2)`
- [ ] MobileJobsView.swift:280 -- same fix in detail view
- [ ] MobileJobsView.swift:282 -- same fix in detail view
- [ ] MobileTabView.swift:113 -- change `Color.green.opacity(0.1)` to `Color.green.opacity(0.15)`
- [ ] MobileTabView.swift:137 -- change `Color.orange.opacity(0.1)` to `Color.orange.opacity(0.15)`
- [ ] MobileLibraryView.swift:205 -- change inactive pill `color.opacity(0.15)` to `color.opacity(0.2)`
- [ ] MobileActivityView.swift:66 -- change `Color.accentColor.opacity(0.1)` to `Color.accentColor.opacity(0.15)`
- [ ] MobilePeopleView.swift:139 -- change `Color.accentColor.opacity(0.15)` to `Color.accentColor.opacity(0.2)` for person placeholder
- [ ] MobilePhotoCell (MobileLibraryView.swift):504 -- add `.overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 0.5))` to curation dot for contrast
- [ ] MemoryCardView.swift:62 -- verify indigo/purple gradient doesn't wash out; consider slightly higher opacity
- [ ] CompletenessRing (MobileJobsView.swift):13 -- change `ringColor.opacity(0.2)` to `ringColor.opacity(0.25)` for dark mode track visibility
