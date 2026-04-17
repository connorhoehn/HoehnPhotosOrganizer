# Session 14: Animation + Transitions

## Goal
Add spring animations to filter changes, selection bars, grid changes, expand/collapse, button presses, ring fills, and empty state fade-ins. Keep performance in mind for older devices.

---

## 1. Animation Cheat Sheet

| Animation Type | SwiftUI Modifier | When to Use |
|---------------|-----------------|-------------|
| Spring (bouncy) | `.spring(response: 0.35, dampingFraction: 0.7)` | Selection state changes, bars appearing |
| Spring (snappy) | `.spring(response: 0.25, dampingFraction: 0.85)` | Filter chip toggles, button presses |
| Ease in-out | `.easeInOut(duration: 0.25)` | Expand/collapse, content changes |
| Linear | `.linear(duration: N)` | Progress fills, shimmer |
| Implicit | `.animation(.spring, value: X)` | Attach to view, triggers on value change |
| Explicit | `withAnimation(.spring) { ... }` | Wrap state mutation |
| Transition | `.transition(.X)` | Views appearing/disappearing in if/else |

---

## 2. Animation Targets

### A. Filter Chip Selection Toggle

**File:** `MobileLibraryView.swift`, `filterPill()` function (line 197)

**Current:** No animation on pill state change.

**Fix:** Wrap the filter state changes in `withAnimation` and add implicit animation to the pill.

```swift
// In filterPill(), add to the Button's content:
.animation(.spring(response: 0.25, dampingFraction: 0.85), value: isActive)

// In the filter pill action closures (lines 145, 151, 159, 163), wrap with:
withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
    selectedFilterRaw = state.rawValue
    selectedLocation = nil
}
Task { await resetAndLoad() }  // keep outside withAnimation
```

- [ ] MobileLibraryView.swift: Add `.animation(.spring(...), value: isActive)` to filterPill body
- [ ] MobileLibraryView.swift: Wrap filter state changes in `withAnimation` (lines 145, 151, 159, 163)

---

### B. Batch Action Bar Slide In/Out

**File:** `MobileLibraryView.swift`, line 58-61

**Current:** Has `.transition(.move(edge: .bottom))` but the `withAnimation` wrapping is inconsistent.

**Fix:** Ensure the bar has a spring transition and the controlling state change is always animated.

```swift
// Line 58-61: update transition
if isSelecting && !selectedPhotoIDs.isEmpty {
    batchActionBar
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: selectedPhotoIDs.isEmpty)
}
```

The `handlePhotoTap` function (line 294) should wrap selection changes:
```swift
withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
    if selectedPhotoIDs.contains(photo.id) {
        selectedPhotoIDs.remove(photo.id)
    } else {
        selectedPhotoIDs.insert(photo.id)
    }
}
```

- [ ] MobileLibraryView.swift:60 -- add `.combined(with: .opacity)` to transition
- [ ] MobileLibraryView.swift:294-307 -- wrap selection toggle in `withAnimation(.spring(...))`
- [ ] MobileLibraryView.swift:372 -- already has `withAnimation` for batch complete; verify spring

---

### C. Grid Column Count Change

**Not currently implemented** -- the grid uses fixed 3-column layout. If dynamic column count is added later:

```swift
// Wrap column count change:
withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
    columnCount = newCount
}

// On the LazyVGrid:
.animation(.spring(response: 0.4, dampingFraction: 0.8), value: columnCount)
```

- [ ] Skip for now -- no dynamic column count exists yet

---

### D. Job Child Row Expand/Collapse

**File:** `MobileJobsView.swift`, lines 81-117

**Current:** Job children are always visible in sections. No expand/collapse behavior exists yet.

**To implement expand/collapse:**

```swift
// Add state:
@State private var collapsedParents: Set<String> = []

// Wrap children in a disclosure:
DisclosureGroup(isExpanded: Binding(
    get: { !collapsedParents.contains(parent.id) },
    set: { expanded in
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if expanded {
                collapsedParents.remove(parent.id)
            } else {
                collapsedParents.insert(parent.id)
            }
        }
    }
)) {
    ForEach(children) { child in
        // child rows
    }
} label: {
    jobRow(parent)
}
```

- [ ] MobileJobsView.swift: Add `@State private var collapsedParents: Set<String> = []`
- [ ] MobileJobsView.swift: Wrap child rows in DisclosureGroup with spring animation
- [ ] MobileJobsView.swift: Add chevron rotation indicator to parent rows

---

### E. Curation Button Press (Scale Effect + Spring)

**File:** `MobilePhotoDetailView.swift`, `ratingButton()` function (line 439)

**Current:** No press animation. Only haptic feedback.

**Fix:** Add scale effect on press.

```swift
private func ratingButton(_ state: CurationState, icon: String, label: String, feedbackLabel: String, color: Color) -> some View {
    Button {
        // existing action...
    } label: {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .symbolEffect(.bounce, value: currentState == state)  // iOS 17+
            Text(label)
                .font(.caption2)
        }
        .foregroundStyle(currentState == state ? color : .white.opacity(0.7))
        .frame(width: 60)
        .scaleEffect(currentState == state ? 1.1 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: currentState)
    }
}
```

- [ ] MobilePhotoDetailView.swift:457-465 -- add `.scaleEffect` and `.animation(.spring, value: currentState)`
- [ ] MobilePhotoDetailView.swift:459 -- add `.symbolEffect(.bounce, value: currentState == state)` for icon pop

---

### F. CompletenessRing Fill Animation

**File:** `MobileJobsView.swift`, `CompletenessRing` (lines 6-20)

**Current:** Ring draws at final value immediately with no animation.

**Fix:** Animate the trim on appear.

```swift
private struct CompletenessRing: View {
    let score: Double
    @State private var animatedScore: Double = 0

    var ringColor: Color {
        animatedScore < 0.33 ? .red : animatedScore < 0.66 ? .orange : .green
    }

    var body: some View {
        ZStack {
            Circle().stroke(ringColor.opacity(0.25), lineWidth: 3)
            Circle().trim(from: 0, to: animatedScore)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 28, height: 28)
        .onAppear {
            withAnimation(.easeOut(duration: 0.8).delay(0.2)) {
                animatedScore = score
            }
        }
        .onChange(of: score) { _, newScore in
            withAnimation(.easeOut(duration: 0.5)) {
                animatedScore = newScore
            }
        }
    }
}
```

- [ ] MobileJobsView.swift:6-20 -- add `@State private var animatedScore: Double = 0`
- [ ] MobileJobsView.swift: Replace `score` with `animatedScore` in trim and color
- [ ] MobileJobsView.swift: Add `.onAppear` with delayed animation
- [ ] MobileJobsView.swift: Add `.onChange(of: score)` for live updates

---

### G. Empty State Fade-In

**Files:** All empty states across the app.

**Pattern:** Wrap empty state content in a fade+scale transition.

```swift
// Add to every empty state VStack:
.transition(.opacity.combined(with: .scale(scale: 0.95)))
.animation(.easeOut(duration: 0.4), value: someCondition)
```

Specific locations:

- [ ] MobileLibraryView.swift:225-252 -- wrap `emptyState` body in `.opacity` transition, add `.onAppear` fade
- [ ] MobileJobsView.swift:58-76 -- same pattern
- [ ] MobilePeopleView.swift:60-74 -- same pattern
- [ ] MobileActivityView.swift:45-55 -- same pattern
- [ ] MobileSearchView.swift:94-106 (noQueryEmptyState) -- same pattern
- [ ] MobileSearchView.swift:109-120 (noResultsEmptyState) -- same pattern
- [ ] MobileStudioHistoryView.swift:44-57 -- same pattern
- [ ] MobileStudioHistoryView.swift:130-143 (browse empty) -- same pattern
- [ ] MobileSettingsView.swift:53-63 (print lab empty) -- same pattern
- [ ] MobileSettingsView.swift:134-143 (studio empty) -- same pattern
- [ ] PersonPhotoListView (MobilePeopleView.swift):187-199 -- same pattern
- [ ] MobileJobDetailView (MobileJobsView.swift):207-215 -- same pattern

**Reusable component approach** (recommended):

```swift
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5).delay(0.15)) {
                appeared = true
            }
        }
    }
}
```

- [ ] Create `EmptyStateView.swift` reusable component in HoehnPhotosMobile/Components/
- [ ] Replace all 12 empty states with `EmptyStateView(icon:title:message:)`

---

## 3. matchedGeometryEffect for Grid-to-Detail

**Current:** Photo detail opens as a `.sheet`. No hero transition.

**If converting to NavigationLink or fullScreenCover with hero animation:**

```swift
@Namespace private var photoNamespace

// In grid cell:
MobilePhotoCell(photo: photo)
    .matchedGeometryEffect(id: photo.id, in: photoNamespace)

// In detail view:
Image(uiImage: img)
    .matchedGeometryEffect(id: photo.id, in: photoNamespace)
```

**Warning:** `matchedGeometryEffect` does NOT work across `.sheet` presentations. Would require converting photo detail to a `NavigationLink` or `fullScreenCover` with a custom transition.

- [ ] Defer to future session -- requires architecture change from sheet to navigation
- [ ] If attempted: test on iPhone SE (performance) and verify memory usage with large grids

---

## 4. Existing Animations to Preserve

These already work -- do not regress:

| File | Line | Animation | Status |
|------|------|-----------|--------|
| MobileLibraryView.swift | 88 | `withAnimation` on isSelecting toggle | OK |
| MobileLibraryView.swift | 269 | `.easeInOut(duration: 0.25)` expand months | OK |
| MobileLibraryView.swift | 372 | `withAnimation` on batch curate complete | OK |
| MobilePhotoDetailView.swift | 189 | `.easeOut(duration: 0.5)` info hint fade | OK |
| MobilePhotoDetailView.swift | 244 | `.easeInOut(duration: 0.15)` filmstrip tap | OK |
| MobilePhotoDetailView.swift | 314 | `.spring(response: 0.35)` double-tap zoom | OK |
| MobilePhotoDetailView.swift | 348 | `.easeIn(duration: 0.15)` zoom badge show | OK |
| MobilePhotoDetailView.swift | 414 | `.easeInOut(duration: 0.15)` swipe nav | OK |
| MobilePhotoDetailView.swift | 444 | `.easeIn(duration: 0.3)` curation feedback | OK |
| MobilePeopleView.swift | 159 | `.easeInOut(duration: 0.1)` press effect | OK |
| MobileSyncView.swift | 204 | `.easeInOut(duration: 0.2)` copied badge | OK |
| MemorySlideshowView.swift | 92 | `.opacity.animation(.easeInOut(duration: 0.6))` slide transition | OK |
| ShimmerCell (MobileLibraryView.swift) | 549 | `.linear(duration: 1.4).repeatForever` shimmer | OK |

---

## 5. Performance Notes

### DO animate:
- Opacity transitions (nearly free)
- Scale effects (GPU-composited)
- Offset/position changes (GPU-composited)
- Spring animations with short duration

### DO NOT animate on older devices (iPhone SE, A12):
- Large LazyVGrid relayout (causes frame drops)
- `.matchedGeometryEffect` with 100+ items in view
- Simultaneous animations on 20+ visible cells
- Blur/material transitions

### Safeguards:
```swift
// Check for reduced motion preference
@Environment(\.accessibilityReduceMotion) var reduceMotion

// Use conditional animation:
.animation(reduceMotion ? .none : .spring(response: 0.3), value: someValue)
```

- [ ] Add `@Environment(\.accessibilityReduceMotion) var reduceMotion` to MobileLibraryView
- [ ] Wrap all new spring animations with `reduceMotion ? .none : .spring(...)` pattern
- [ ] Test on iPhone SE simulator with Slow Animations enabled

---

## 6. Full Checklist

### Filter Chips
- [ ] Add spring animation to pill background/foreground on state change
- [ ] Wrap filter state mutations in `withAnimation`

### Batch Action Bar
- [ ] Add `.combined(with: .opacity)` to move transition
- [ ] Wrap selection toggle in `withAnimation(.spring)`

### Job Children
- [ ] Add expand/collapse with DisclosureGroup + spring animation
- [ ] Add chevron rotation animation

### Curation Buttons
- [ ] Add `.scaleEffect` on active state
- [ ] Add `.symbolEffect(.bounce)` on icon (iOS 17+)
- [ ] Verify haptic still fires alongside animation

### Completeness Ring
- [ ] Convert to animated fill with `@State animatedScore`
- [ ] Add `.onAppear` delayed fill animation
- [ ] Add `.onChange` for live score updates

### Empty States
- [ ] Create reusable `EmptyStateView` component
- [ ] Replace all 12 empty states
- [ ] Add fade-in + slight upward offset animation

### Reduce Motion
- [ ] Add `reduceMotion` environment check
- [ ] Gate all new animations behind reduce motion preference
