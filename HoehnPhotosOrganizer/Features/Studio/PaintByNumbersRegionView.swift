import SwiftUI

// MARK: - PBNPaletteStripView

/// Horizontal strip of color swatches with region numbers, used as a compact palette preview.
struct PBNPaletteStripView: View {

    let palette: PBNPalette
    var selectedIndex: Int?
    var selectedIndices: Set<Int> = []

    var body: some View {
        GeometryReader { geometry in
            let count = palette.colors.count
            let swatchWidth = count > 0 ? geometry.size.width / CGFloat(count) : 0

            HStack(spacing: 0) {
                ForEach(Array(palette.colors.enumerated()), id: \.element.id) { index, color in
                    ZStack {
                        Rectangle()
                            .fill(color.color)
                            .opacity(selectedIndices.isEmpty || selectedIndices.contains(index) ? 1.0 : 0.3)

                        Text("\(index + 1)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(contrastingTextColor(for: color))
                    }
                    .frame(width: swatchWidth)
                    .overlay(
                        RoundedRectangle(cornerRadius: 1)
                            .strokeBorder(Color.white, lineWidth: selectedIndex == index ? 2 : 0)
                    )
                }
            }
        }
        .frame(height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// Returns white for dark colors, black for light ones.
    private func contrastingTextColor(for color: PBNColor) -> Color {
        let luminance = 0.299 * color.red + 0.587 * color.green + 0.114 * color.blue
        return luminance > 0.5 ? .black : .white
    }
}

// MARK: - PBNRegionRow

/// A single row in the region list showing selection state, color swatch, name, recipe, and coverage.
struct PBNRegionRow: View {

    let region: PBNRegion
    let index: Int
    let palette: PBNPalette
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    /// Display number: use recipe's displayNumber when available, otherwise index + 1.
    private var displayNumber: Int {
        region.recipe?.displayNumber ?? (index + 1)
    }

    /// Label for the color name column: pure = palette name, mix = "Mix".
    private var colorLabel: String {
        if let recipe = region.recipe {
            return recipe.isPure ? recipe.components[0].colorName : "Mix"
        }
        return region.color.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // Selection indicator
                Image(systemName: isSelected ? "circle.fill" : "circle")
                    .font(.system(size: 8))
                    .foregroundStyle(isSelected ? region.color.color : .secondary)

                // Region number
                Text("\(displayNumber)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(width: 20, alignment: .trailing)

                // Color swatch
                RoundedRectangle(cornerRadius: 2)
                    .fill(region.color.color)
                    .frame(width: 14, height: 14)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                    )

                // Color name / "Mix"
                Text(colorLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                // Coverage bar + percentage
                HStack(spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color.primary.opacity(0.08))
                                .frame(height: 3)

                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(region.color.color)
                                .frame(width: geo.size.width * min(region.coveragePercent / 100.0, 1.0), height: 3)
                        }
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(width: 30, height: 14)

                    Text(String(format: "%.1f%%", region.coveragePercent))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
            }

            // Mix recipe detail (shown below main row for non-pure recipes)
            if let recipe = region.recipe {
                RecipeDetailRow(recipe: recipe, palette: palette)
                    .padding(.leading, 34) // align under color swatch
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected
                      ? region.color.color.opacity(0.12)
                      : isHovered
                          ? Color.primary.opacity(0.04)
                          : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { hovering in isHovered = hovering }
    }
}

// MARK: - RecipeDetailRow

/// Renders mix components as a row of mini swatches with percentage labels.
/// Only shows content for non-pure (mixed) recipes.
private struct RecipeDetailRow: View {
    let recipe: ColorMixRecipe
    let palette: PBNPalette

    var body: some View {
        if !recipe.isPure {
            HStack(spacing: 4) {
                ForEach(Array(recipe.components.enumerated()), id: \.element.paletteIndex) { offset, component in
                    if offset > 0 {
                        Text("+").font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 2) {
                        Circle()
                            .fill(palette.colors[safe: component.paletteIndex]?.color ?? .gray)
                            .frame(width: 8, height: 8)
                        Text("\(Int(component.fraction * 100))%")
                            .font(.system(size: 9, design: .monospaced))
                    }
                }
            }
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - PaintByNumbersRegionPanel

/// Region inspector panel for Paint by Numbers mode (right side, 280px wide).
struct PaintByNumbersRegionPanel: View {

    let regions: [PBNRegion]
    let palette: PBNPalette
    @Binding var selectedRegionIndex: Int?
    @Binding var selectedRegionIndices: Set<Int>
    let onToggleRegion: (Int) -> Void             // toggle highlight on canvas
    let onColorChange: (Int, PBNColor) -> Void    // regionIndex, newColor
    let onExportMask: (Int) -> Void               // regionIndex
    let onExportAllMasks: () -> Void
    let onExportPalette: () -> Void
    let onExportFullKit: () -> Void

    // Color editor state
    @State private var isEditingColor = false
    @State private var editColorName: String = ""
    @State private var editColor: Color = .white

    // MARK: - Computed

    private var selectedRegion: PBNRegion? {
        guard let idx = selectedRegionIndex, regions.indices.contains(idx) else { return nil }
        return regions[idx]
    }

    // MARK: - Body

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                palettePreviewSection
                Divider()
                regionsSection
                if selectedRegion != nil {
                    Divider()
                    selectedRegionSection
                }
                if isEditingColor {
                    Divider()
                    colorEditorSection
                }
                Divider()
                exportSection
            }
            .padding(12)
        }
        .frame(width: 280)
    }

    // MARK: - Sections

    private var palettePreviewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("PALETTE PREVIEW")

            PBNPaletteStripView(palette: palette, selectedIndex: selectedRegionIndex, selectedIndices: selectedRegionIndices)

            Text(palette.name)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var regionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader("REGIONS")

            VStack(spacing: 1) {
                ForEach(Array(regions.enumerated()), id: \.element.id) { index, region in
                    PBNRegionRow(
                        region: region,
                        index: index,
                        palette: palette,
                        isSelected: selectedRegionIndices.contains(index),
                        onSelect: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                // Toggle canvas highlight (instant LUT path)
                                onToggleRegion(index)
                                // Update detail panel selection
                                if selectedRegionIndex == index {
                                    selectedRegionIndex = nil
                                } else {
                                    selectedRegionIndex = index
                                }
                                isEditingColor = false
                            }
                        }
                    )
                }
            }
            .padding(4)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(6)
        }
    }

    private var selectedRegionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("SELECTED REGION")

            if let region = selectedRegion, let idx = selectedRegionIndex {
                VStack(alignment: .leading, spacing: 6) {
                    // Title
                    Text("Region \(idx + 1): \"\(region.color.name)\"")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)

                    // Range
                    HStack(spacing: 4) {
                        Text("Range:")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text("\(region.thresholdBounds.lower) – \(region.thresholdBounds.upper)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary)
                    }

                    // Coverage
                    HStack(spacing: 4) {
                        Text("Coverage:")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.1f%%", region.coveragePercent))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary)
                    }

                    // Color swatch + Edit button
                    HStack(spacing: 8) {
                        Text("Color:")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(region.color.color)
                            .frame(width: 20, height: 14)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5)
                            )

                        Button("Edit") {
                            editColorName = region.color.name
                            editColor = region.color.color
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isEditingColor = true
                            }
                        }
                        .controlSize(.mini)
                        .font(.system(size: 11))
                    }

                    // Export region mask shortcut
                    Button {
                        onExportMask(idx)
                    } label: {
                        Label("Export Mask", systemImage: "square.and.arrow.up")
                            .font(.system(size: 11))
                    }
                    .controlSize(.mini)
                }
                .padding(8)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(6)
            }
        }
    }

    private var colorEditorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("COLOR EDITOR")

            VStack(alignment: .leading, spacing: 8) {
                // Name field
                HStack(spacing: 6) {
                    Text("Name:")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("Color name", text: $editColorName)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.mini)
                        .font(.system(size: 11))
                }

                // Color picker
                ColorPicker("Color:", selection: $editColor, supportsOpacity: false)
                    .controlSize(.mini)
                    .font(.system(size: 11))

                // Apply / Cancel
                HStack(spacing: 8) {
                    Button("Apply") {
                        applyColorEdit()
                    }
                    .controlSize(.mini)
                    .font(.system(size: 11))
                    .buttonStyle(.borderedProminent)

                    Button("Cancel") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isEditingColor = false
                        }
                    }
                    .controlSize(.mini)
                    .font(.system(size: 11))
                }
            }
            .padding(8)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(6)
        }
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("EXPORT")

            VStack(spacing: 4) {
                if let idx = selectedRegionIndex {
                    exportButton("Export Selected Region Mask", icon: "square.dashed") {
                        onExportMask(idx)
                    }
                }

                exportButton("Export All Region Masks", icon: "square.grid.3x3") {
                    onExportAllMasks()
                }

                exportButton("Export Palette Swatch", icon: "paintpalette") {
                    onExportPalette()
                }

                exportButton("Export Full Kit (ZIP)", icon: "doc.zipper") {
                    onExportFullKit()
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func exportButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 11))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func applyColorEdit() {
        guard let idx = selectedRegionIndex else { return }

        // Resolve Color to RGB components via NSColor
        let resolved = NSColor(editColor)
        let r = Double(resolved.redComponent)
        let g = Double(resolved.greenComponent)
        let b = Double(resolved.blueComponent)

        let newColor = PBNColor(
            id: regions[idx].color.id,
            red: r,
            green: g,
            blue: b,
            name: editColorName.trimmingCharacters(in: .whitespaces).isEmpty
                ? regions[idx].color.name
                : editColorName.trimmingCharacters(in: .whitespaces)
        )

        onColorChange(idx, newColor)

        withAnimation(.easeInOut(duration: 0.15)) {
            isEditingColor = false
        }
    }
}

// MARK: - Safe Array Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
