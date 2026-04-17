# Session 11: Skeleton Loaders

## Goal
Replace all `ProgressView("Loading...")` spinners with shimmer skeleton placeholders across every tab. Create a reusable `SkeletonComponents.swift` file in `HoehnPhotosMobile/Components/`.

---

## Existing Pattern: BentoSkeletonSection

The Library tab already has a working skeleton pattern. Use this as the reference for style, animation timing, and colors.

**File:** `HoehnPhotosMobile/Features/Library/BentoSkeletonSection.swift`

```swift
struct BentoSkeletonSection: View {
    private let spacing: CGFloat = 2

    var body: some View {
        VStack(spacing: 0) {
            // Skeleton header placeholder
            HStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(uiColor: .systemFill))
                    .frame(width: 160, height: 20)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityHidden(true)

            // Skeleton bento rows
            GeometryReader { geo in
                let totalWidth = geo.size.width
                let largeWidth = (totalWidth - spacing) * 2.0 / 3.0
                let smallWidth = totalWidth - largeWidth - spacing
                let largeHeight = largeWidth * 3.0 / 4.0
                let smallHeight = (largeHeight - spacing) / 2.0
                let equalWidth = (totalWidth - spacing * 2) / 3.0

                VStack(spacing: spacing) {
                    HStack(spacing: spacing) {
                        ShimmerCell()
                            .frame(width: largeWidth, height: largeHeight)
                        VStack(spacing: spacing) {
                            ShimmerCell().frame(width: smallWidth, height: smallHeight)
                            ShimmerCell().frame(width: smallWidth, height: smallHeight)
                        }
                    }
                    HStack(spacing: spacing) {
                        ShimmerCell().frame(width: equalWidth, height: equalWidth)
                        ShimmerCell().frame(width: equalWidth, height: equalWidth)
                        ShimmerCell().frame(width: equalWidth, height: equalWidth)
                    }
                }
            }
            .frame(height: skeletonHeight)
        }
        .accessibilityHidden(true)
    }
}
```

**File:** `MobileLibraryView.swift` (ShimmerCell already exists at bottom of file)

```swift
struct ShimmerCell: View {
    @State private var shimmerPhase: CGFloat = -1

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: Color(uiColor: .systemFill), location: shimmerPhase - 0.3),
                        .init(color: Color(uiColor: .secondarySystemFill), location: shimmerPhase),
                        .init(color: Color(uiColor: .systemFill), location: shimmerPhase + 0.3),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    shimmerPhase = 2
                }
            }
    }
}
```

---

## Step 1: Create SkeletonComponents.swift

**New file:** `HoehnPhotosMobile/Components/SkeletonComponents.swift`

```swift
import SwiftUI

// MARK: - Shimmer Animation Modifier

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: phase - 0.3),
                        .init(color: .white.opacity(0.4), location: phase),
                        .init(color: .clear, location: phase + 0.3),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .blendMode(.overlay)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 2
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}

// MARK: - Skeleton Primitives

/// Rectangular skeleton placeholder (photo tiles, text lines, cards)
struct SkeletonRect: View {
    var width: CGFloat? = nil
    var height: CGFloat = 20
    var cornerRadius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color(uiColor: .systemFill))
            .frame(width: width, height: height)
            .shimmer()
    }
}

/// Circular skeleton placeholder (avatars, completeness rings)
struct SkeletonCircle: View {
    var size: CGFloat = 40

    var body: some View {
        Circle()
            .fill(Color(uiColor: .systemFill))
            .frame(width: size, height: size)
            .shimmer()
    }
}

/// A row skeleton: circle + two text lines (good for list rows)
struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 12) {
            SkeletonCircle(size: 28)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonRect(width: 140, height: 14)
                SkeletonRect(width: 80, height: 10)
            }
            Spacer()
            SkeletonRect(width: 60, height: 20, cornerRadius: 10)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Grid of square shimmer cells (for photo grids — people photos, search results, job photos)
struct SkeletonPhotoGrid: View {
    var rows: Int = 4
    var columns: Int = 3
    var spacing: CGFloat = 2

    var body: some View {
        let gridColumns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns)
        LazyVGrid(columns: gridColumns, spacing: spacing) {
            ForEach(0..<(rows * columns), id: \.self) { _ in
                ShimmerCell()
                    .aspectRatio(1, contentMode: .fill)
            }
        }
        .accessibilityHidden(true)
    }
}

/// People grid skeleton: 2-column grid of person card placeholders
struct SkeletonPeopleGrid: View {
    var count: Int = 6
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(0..<count, id: \.self) { _ in
                    VStack(spacing: 8) {
                        SkeletonRect(height: 100, cornerRadius: 12)
                            .frame(width: 100, height: 100)
                        SkeletonRect(width: 80, height: 14)
                        SkeletonRect(width: 50, height: 10)
                    }
                }
            }
            .padding(12)
        }
        .accessibilityHidden(true)
    }
}

/// Activity list skeleton: icon circle + text lines grouped in sections
struct SkeletonActivityList: View {
    var sectionCount: Int = 2
    var rowsPerSection: Int = 3

    var body: some View {
        List {
            ForEach(0..<sectionCount, id: \.self) { _ in
                Section {
                    ForEach(0..<rowsPerSection, id: \.self) { _ in
                        HStack(spacing: 12) {
                            SkeletonCircle(size: 28)
                            VStack(alignment: .leading, spacing: 4) {
                                SkeletonRect(width: 180, height: 14)
                                SkeletonRect(width: 120, height: 10)
                                SkeletonRect(width: 80, height: 8)
                            }
                        }
                    }
                } header: {
                    SkeletonRect(width: 80, height: 12)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Job list skeleton: rows with completeness ring + title + status pill
struct SkeletonJobsList: View {
    var count: Int = 5

    var body: some View {
        List {
            ForEach(0..<count, id: \.self) { _ in
                SkeletonRow()
                    .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityHidden(true)
    }
}
```

---

## Step 2: Replacements Per Tab

### 2A. Library Tab (already done -- no changes needed)

**File:** `MobileLibraryView.swift` (lines 46-48)

The Library tab already uses `BentoSkeletonSection` correctly:

```swift
if isLoading && monthSections.isEmpty {
    skeletonGrid   // <-- already renders BentoSkeletonSection x2
}
```

No changes needed here.

---

### 2B. Jobs Tab

**File:** `HoehnPhotosMobile/Features/Jobs/MobileJobsView.swift` (lines 41-43)

**Before:**
```swift
if isLoading && jobs.isEmpty {
    ProgressView("Loading jobs...")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
}
```

**After:**
```swift
if isLoading && jobs.isEmpty {
    SkeletonJobsList(count: 5)
}
```

---

### 2C. People Tab

**File:** `HoehnPhotosMobile/Features/People/MobilePeopleView.swift` (lines 20-23)

**Before:**
```swift
if isLoading && people.isEmpty {
    Spacer()
    ProgressView("Loading people...")
    Spacer()
}
```

**After:**
```swift
if isLoading && people.isEmpty {
    SkeletonPeopleGrid(count: 6)
}
```

---

### 2D. Person Photo List

**File:** `HoehnPhotosMobile/Features/People/MobilePeopleView.swift` (lines 183-185 in `PersonPhotoListView`)

**Before:**
```swift
if isLoading {
    ProgressView("Loading \(person.name)...")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
}
```

**After:**
```swift
if isLoading {
    SkeletonPhotoGrid(rows: 4, columns: 3)
}
```

---

### 2E. Activity Tab

**File:** `HoehnPhotosMobile/Features/Activity/MobileActivityView.swift` (lines 42-43)

**Before:**
```swift
if isLoading {
    ProgressView("Loading activity...")
}
```

**After:**
```swift
if isLoading {
    SkeletonActivityList(sectionCount: 2, rowsPerSection: 3)
}
```

---

### 2F. Search Tab

**File:** `HoehnPhotosMobile/Features/Search/MobileSearchView.swift` (lines 37-39)

**Before:**
```swift
} else if results.isEmpty && isSearching {
    ProgressView("Searching...")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
}
```

**After:**
```swift
} else if results.isEmpty && isSearching {
    SkeletonPhotoGrid(rows: 4, columns: 3)
        .padding(.top, 8)
}
```

---

## Step 3: Move ShimmerCell to SkeletonComponents

`ShimmerCell` is currently defined at the bottom of `MobileLibraryView.swift` (line 532). Move it into `SkeletonComponents.swift` so all skeleton/shimmer primitives live together. `BentoSkeletonSection` already references `ShimmerCell`, so it just needs to be in the same module.

Remove the `ShimmerCell` struct from `MobileLibraryView.swift` (lines 532-554) after adding it to `SkeletonComponents.swift`.

---

## Alternative: .redacted(reason: .placeholder)

For simpler cases where you want to show a placeholder version of the real view (e.g., a single text label), you can use SwiftUI's built-in redaction:

```swift
Text("Some placeholder text")
    .redacted(reason: .placeholder)
```

This grays out the text with a rounded rect. It works well for individual text elements but does NOT produce shimmer animation. Use it only for trivial placeholders where the shimmer skeleton approach is overkill (e.g., a single label that loads in <200ms). For all tab-level loading states, use the shimmer skeletons above.

---

## Checklist

- [ ] Create `HoehnPhotosMobile/Components/SkeletonComponents.swift` with all primitives
- [ ] Move `ShimmerCell` from `MobileLibraryView.swift` into `SkeletonComponents.swift`
- [ ] Replace `ProgressView("Loading jobs...")` in `MobileJobsView.swift`
- [ ] Replace `ProgressView("Loading people...")` in `MobilePeopleView.swift`
- [ ] Replace `ProgressView("Loading \(person.name)...")` in `PersonPhotoListView`
- [ ] Replace `ProgressView("Loading activity...")` in `MobileActivityView.swift`
- [ ] Replace `ProgressView("Searching...")` in `MobileSearchView.swift`
- [ ] Verify all skeletons have `.accessibilityHidden(true)`
- [ ] Build and test each tab transition from loading to loaded state
