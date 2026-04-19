import SwiftUI

struct DesignSystemGallery: View {
    var body: some View {
        List {
            Section("Tokens") {
                NavigationLink("Spacing & Radius") { SpacingGallery() }
                NavigationLink("Typography") { TypographyGallery() }
                NavigationLink("Semantic Colors") { ColorGallery() }
            }

            Section("Primitives") {
                NavigationLink("GlassPanel") { GlassPanelGallery() }
                NavigationLink("PhotoTile") { PhotoTileGallery() }
                NavigationLink("FaceChip") { FaceChipGallery() }
                NavigationLink("FilterPill") { FilterPillGallery() }
                NavigationLink("SearchScopeBar") { SearchScopeBarGallery() }
                NavigationLink("MetadataRow") { MetadataRowGallery() }
                NavigationLink("MeshBackdrop") { MeshBackdropGallery() }
                NavigationLink("ShimmerPlaceholder") { ShimmerGallery() }
                NavigationLink("HapticToast") { ToastGallery() }
                NavigationLink("FaceReviewCard") { ReviewCardGallery() }
            }

            Section {
                Text("These components power Library, Search, People, and Photo Detail. Tap each to preview in isolation.")
                    .font(HPFont.cardSubtitle)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Design System")
    }
}

// MARK: - Token galleries

private struct SpacingGallery: View {
    private let pairs: [(String, CGFloat)] = [
        ("xxs", HPSpacing.xxs), ("xs", HPSpacing.xs), ("sm", HPSpacing.sm),
        ("md", HPSpacing.md), ("base", HPSpacing.base), ("lg", HPSpacing.lg),
        ("xl", HPSpacing.xl), ("xxl", HPSpacing.xxl), ("xxxl", HPSpacing.xxxl)
    ]
    private let radii: [(String, CGFloat)] = [
        ("small", HPRadius.small), ("medium", HPRadius.medium),
        ("large", HPRadius.large), ("card", HPRadius.card)
    ]
    var body: some View {
        List {
            Section("Spacing") {
                ForEach(pairs, id: \.0) { (name, v) in
                    HStack {
                        Text(name).font(HPFont.cardTitle).frame(width: 50, alignment: .leading)
                        RoundedRectangle(cornerRadius: 2).fill(HPColor.chipActive).frame(width: v, height: 14)
                        Text("\(Int(v))pt").font(HPFont.metaValue.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
            Section("Corner Radius") {
                ForEach(radii, id: \.0) { (name, v) in
                    HStack {
                        Text(name).font(HPFont.cardTitle).frame(width: 80, alignment: .leading)
                        RoundedRectangle(cornerRadius: v, style: .continuous)
                            .fill(HPColor.cardBackground)
                            .frame(width: 48, height: 48)
                            .overlay(RoundedRectangle(cornerRadius: v, style: .continuous).stroke(.secondary))
                        Text("\(Int(v))pt").font(HPFont.metaValue.monospaced()).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("Spacing & Radius")
    }
}

private struct TypographyGallery: View {
    var body: some View {
        List {
            row("Screen Title", HPFont.screenTitle)
            row("Section Header", HPFont.sectionHeader)
            row("Card Title", HPFont.cardTitle)
            row("Card Subtitle", HPFont.cardSubtitle)
            row("Chip Label", HPFont.chipLabel)
            row("Chip Label (active)", HPFont.chipLabelActive)
            row("Badge Label", HPFont.badgeLabel)
            row("Meta Label", HPFont.metaLabel)
            row("Meta Value", HPFont.metaValue)
            row("Body", HPFont.body)
            row("Body Strong", HPFont.bodyStrong)
        }
        .navigationTitle("Typography")
    }
    private func row(_ label: String, _ font: Font) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(HPFont.metaLabel).foregroundStyle(.secondary)
            Text("The quick brown fox").font(font)
        }
    }
}

private struct ColorGallery: View {
    private let colors: [(String, Color)] = [
        ("keeper", HPColor.keeper), ("archive", HPColor.archive),
        ("needsReview", HPColor.needsReview), ("reject", HPColor.reject),
        ("chipActive", HPColor.chipActive), ("chipInactive", HPColor.chipInactive),
        ("cardBackground", HPColor.cardBackground), ("canvasBackground", HPColor.canvasBackground)
    ]
    var body: some View {
        List {
            ForEach(colors, id: \.0) { (name, color) in
                HStack {
                    RoundedRectangle(cornerRadius: HPRadius.small).fill(color).frame(width: 44, height: 28)
                        .overlay(RoundedRectangle(cornerRadius: HPRadius.small).stroke(.secondary.opacity(0.4)))
                    Text(name).font(HPFont.cardTitle)
                    Spacer()
                }
            }
        }
        .navigationTitle("Colors")
    }
}

// MARK: - Primitive galleries

private struct GlassPanelGallery: View {
    var body: some View {
        ZStack {
            MeshBackdrop(palette: .dusk)
            VStack(spacing: HPSpacing.base) {
                GlassPanel(tone: .chrome) { Text("Chrome — nav bars").padding() }
                GlassPanel(tone: .sheet) { Text("Sheet — modals").padding() }
                GlassPanel(tone: .overlay) { Text("Overlay — toasts").padding() }
                GlassPanel(tone: .card) { Text("Card — content").padding() }
            }
            .padding()
        }
        .navigationTitle("GlassPanel")
    }
}

private struct PhotoTileGallery: View {
    var body: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: HPGrid.photoGutter), count: 3)
        ScrollView {
            LazyVGrid(columns: cols, spacing: HPGrid.photoGutter) {
                PhotoTile(image: nil).aspectRatio(1, contentMode: .fit)
                PhotoTile(image: nil, curationColor: HPColor.keeper).aspectRatio(1, contentMode: .fit)
                PhotoTile(image: nil, isSelected: true).aspectRatio(1, contentMode: .fit)
                PhotoTile(image: nil, curationColor: HPColor.needsReview, overlayBadge: "RAW").aspectRatio(1, contentMode: .fit)
                PhotoTile(image: nil, curationColor: HPColor.reject).aspectRatio(1, contentMode: .fit)
                PhotoTile(image: nil, overlayBadge: "+12").aspectRatio(1, contentMode: .fit)
            }
            .padding(HPSpacing.base)
        }
        .navigationTitle("PhotoTile")
    }
}

private struct FaceChipGallery: View {
    @State var selected = "mom"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HPSpacing.xl) {
                section("Sizes") {
                    HStack(alignment: .top, spacing: HPSpacing.lg) {
                        FaceChip(image: nil, name: "Connor", size: .small) {}
                        FaceChip(image: nil, name: "Taylor", size: .medium) {}
                        FaceChip(image: nil, name: "Alex", size: .large) {}
                    }
                }
                section("States") {
                    HStack(spacing: HPSpacing.md) {
                        FaceChip(image: nil, name: "Mom", isSelected: selected == "mom") { selected = "mom" }
                        FaceChip(image: nil, name: "Dad", isSelected: selected == "dad") { selected = "dad" }
                        FaceChip(image: nil, name: nil, isSelected: selected == "q") { selected = "q" }
                        FaceChip(image: nil, name: "", isSelected: selected == "q2") { selected = "q2" }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("FaceChip")
    }
    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: HPSpacing.sm) {
            Text(title).font(HPFont.metaLabel).foregroundStyle(.secondary)
            content()
        }
    }
}

private struct FilterPillGallery: View {
    @State var active: Set<String> = ["Keep"]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HPSpacing.sm) {
                FilterPill(label: "All", count: 2431, isActive: active.contains("All")) { toggle("All") }
                FilterPill(label: "Keep", systemImage: "hand.thumbsup", count: 186, isActive: active.contains("Keep")) { toggle("Keep") }
                FilterPill(label: "Archive", systemImage: "archivebox", count: 45, isActive: active.contains("Archive")) { toggle("Archive") }
                FilterPill(label: "Reject", systemImage: "trash", count: 12, isActive: active.contains("Reject")) { toggle("Reject") }
                FilterPill(label: "Needs review", systemImage: "questionmark.circle", count: 89, isActive: active.contains("Needs")) { toggle("Needs") }
            }
            .padding()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .navigationTitle("FilterPill")
    }
    func toggle(_ k: String) { if active.contains(k) { active.remove(k) } else { active.insert(k) } }
}

private struct SearchScopeBarGallery: View {
    @Namespace var ns
    @State var scope: SearchScope = .all
    var body: some View {
        VStack(spacing: HPSpacing.xl) {
            SearchScopeBar(selection: $scope, namespaceID: ns)
            Text("Scope: \(scope.title)")
                .font(HPFont.sectionHeader)
                .foregroundStyle(scope.accent)
                .contentTransition(.interpolate)
            Spacer()
        }
        .padding(.top, HPSpacing.lg)
        .navigationTitle("SearchScopeBar")
    }
}

private struct MetadataRowGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MetadataRow(label: "Camera", value: "Fujifilm X-T5", systemImage: "camera")
                Divider()
                MetadataRow(label: "Lens", value: "XF 35mm f/1.4 R", systemImage: "camera.macro")
                Divider()
                MetadataRow(label: "Exposure", value: "1/250 · f/2.8 · ISO 400", systemImage: "timer", valueStyle: .mono)
                Divider()
                MetadataRow(label: "Captured", value: "Apr 18, 2026 · 14:32:07", systemImage: "calendar")
                Divider()
                MetadataRow(label: "Location", value: "48.8566° N, 2.3522° E", systemImage: "mappin", valueStyle: .mono)
                Divider()
                MetadataRow(label: "File", value: "IMG_4832.raf — 48.2 MB · 16-bit", systemImage: "doc", valueStyle: .muted)
                Divider()
                MetadataRow(label: "Missing", value: nil, systemImage: "questionmark")
            }
            .padding()
        }
        .navigationTitle("MetadataRow")
    }
}

private struct MeshBackdropGallery: View {
    @State var palette: MeshBackdrop.Palette = .dusk
    var body: some View {
        ZStack {
            MeshBackdrop(palette: palette)
            VStack {
                Text("MeshBackdrop").font(HPFont.screenTitle).foregroundStyle(.white)
                Text("Animated · Liquid-Glass ready").font(HPFont.cardSubtitle).foregroundStyle(.white.opacity(0.85))
                Spacer()
                Picker("Palette", selection: $palette) {
                    Text("Warm").tag(MeshBackdrop.Palette.warm)
                    Text("Cool").tag(MeshBackdrop.Palette.cool)
                    Text("Dusk").tag(MeshBackdrop.Palette.dusk)
                    Text("Mono").tag(MeshBackdrop.Palette.mono)
                }
                .pickerStyle(.segmented)
                .padding()
            }
            .padding(.top, HPSpacing.xxxl)
        }
        .navigationTitle("MeshBackdrop")
    }
}

private struct ShimmerGallery: View {
    var body: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: HPGrid.photoGutter), count: 3)
        LazyVGrid(columns: cols, spacing: HPGrid.photoGutter) {
            ForEach(0..<12, id: \.self) { _ in
                ShimmerPlaceholder().aspectRatio(1, contentMode: .fit)
            }
        }
        .padding()
        .navigationTitle("Shimmer")
    }
}

private struct ToastGallery: View {
    @State var toast: ToastMessage?
    var body: some View {
        VStack(spacing: HPSpacing.base) {
            Button("Success") { toast = .init(.success, "Named as Taylor", subtitle: "3 more faces updated") }
            Button("Info") { toast = .init(.info, "Preparing export") }
            Button("Warning") { toast = .init(.warning, "Slow sync", subtitle: "Check Wi-Fi") }
            Button("Error") { toast = .init(.error, "Couldn't save", subtitle: "Try again") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hapticToast($toast)
        .navigationTitle("HapticToast")
    }
}

private struct ReviewCardGallery: View {
    @State var actions: [String] = []
    @State var idx = 0
    let models: [FaceReviewCard.Model] = [
        .init(id: "1", faceImage: nil, contextImage: nil, suggestedName: "Taylor", photoDateText: "Aug 4, 2024"),
        .init(id: "2", faceImage: nil, contextImage: nil, suggestedName: nil, photoDateText: "Dec 12, 2023"),
        .init(id: "3", faceImage: nil, contextImage: nil, suggestedName: "Alex", photoDateText: "May 22, 2025")
    ]
    var body: some View {
        VStack(spacing: HPSpacing.base) {
            if idx < models.count {
                FaceReviewCard(model: models[idx]) { action in
                    switch action {
                    case .name(let n): actions.append("Named \(models[idx].id) → \(n)")
                    case .reject: actions.append("Rejected \(models[idx].id)")
                    case .merge: actions.append("Merge \(models[idx].id)")
                    }
                    idx += 1
                }
                .padding(HPSpacing.lg)
            } else {
                Button("Reset") { actions.removeAll(); idx = 0 }
                    .buttonStyle(.borderedProminent)
            }
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(actions, id: \.self) { Text($0).font(HPFont.cardSubtitle) }
                }
                .padding()
            }
            .frame(height: 100)
        }
        .navigationTitle("FaceReviewCard")
    }
}

#Preview {
    NavigationStack {
        DesignSystemGallery()
    }
}
