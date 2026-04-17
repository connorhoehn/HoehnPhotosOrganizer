import SwiftUI

// MARK: - MaskAdjustmentPanel

/// Per-layer adjustment sliders — shown when an adjustment layer is selected.
struct MaskAdjustmentPanel: View {

    @Binding var layer: AdjustmentLayer
    let onDelete: () -> Void
    var onAddLinearGradient: (() -> Void)? = nil
    var onAddRadialGradient: (() -> Void)? = nil
    var onAddMaskSource: ((MaskSourceType) -> Void)? = nil

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: layer.sources.isEmpty ? "slider.horizontal.3" : (layer.sources.first?.typeIcon ?? "circle.dashed"))
                    .font(.title3)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Label", text: $layer.label)
                        .font(.headline)
                        .textFieldStyle(.plain)
                    if !layer.adjustments.isIdentity {
                        Text(layer.adjustmentSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()

                // Add Mask inline
                Menu {
                    Button { onAddLinearGradient?() } label: {
                        Label("Linear Gradient", systemImage: "line.diagonal")
                    }
                    Button { onAddRadialGradient?() } label: {
                        Label("Radial Gradient", systemImage: "circle.and.line.horizontal")
                    }
                    Divider()
                    Button {
                        onAddMaskSource?(.rectangle(normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)))
                    } label: {
                        Label("Rectangle", systemImage: "rectangle.dashed")
                    }
                    Button {
                        onAddMaskSource?(.ellipse(normalizedRect: CGRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7)))
                    } label: {
                        Label("Ellipse", systemImage: "circle.dashed")
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                        Text("Mask")
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Add mask to this layer")

                Button("Reset") {
                    layer.adjustments = PhotoAdjustments()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(layer.adjustments.isIdentity)
            }

            Divider()

            // Mask Sources
            if !layer.sources.isEmpty {
                maskSourcesSection
                Divider()
            }

            // Opacity
            HStack {
                sliderRow("Opacity", value: $layer.opacity, range: 0...1, step: 0.01, format: "%.0f%%") {
                    layer.opacity * 100
                }
            }

            Divider()

            // White Balance
            whiteBalanceSection

            Divider()

            // Levels
            levelsSection

            Divider()

            // Color
            colorSection
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    // MARK: - Mask Sources Section

    private var maskSourcesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mask Sources")
                .font(.subheadline.weight(.semibold))

            ForEach($layer.sources) { $source in
                HStack(spacing: 6) {
                    Image(systemName: source.typeIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    Text(source.typeLabel)
                        .font(.caption)
                        .lineLimit(1)

                    Spacer()

                    // Combine mode
                    if layer.sources.count > 1 {
                        Picker("", selection: $source.combineMode) {
                            Text("Add").tag(MaskCombineMode.add)
                            Text("Sub").tag(MaskCombineMode.subtract)
                            Text("Int").tag(MaskCombineMode.intersect)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 100)
                        .controlSize(.mini)
                    }

                    // Invert toggle
                    Toggle("", isOn: $source.isInverted)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .fixedSize()
                        .help("Invert this mask source")

                    // Delete source
                    Button {
                        layer.sources.removeAll { $0.id == source.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)

                // Per-source edge controls (compact)
                HStack(spacing: 4) {
                    Text("Edge").font(.caption2).foregroundStyle(.quaternary).frame(width: 30)
                    Slider(value: $source.feather, in: 0...20, step: 0.5)
                        .frame(width: 60)
                    Text("F").font(.caption2).foregroundStyle(.quaternary)
                    Slider(value: $source.erode, in: 0...10, step: 0.5)
                        .frame(width: 40)
                    Text("E").font(.caption2).foregroundStyle(.quaternary)
                    Slider(value: $source.dilate, in: 0...10, step: 0.5)
                        .frame(width: 40)
                    Text("D").font(.caption2).foregroundStyle(.quaternary)
                }
                .controlSize(.mini)

                if source.id != layer.sources.last?.id {
                    Divider().padding(.leading, 22)
                }
            }
        }
    }

    // MARK: - Levels & Color

    private var whiteBalanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("White Balance").font(.subheadline.weight(.semibold))
            sliderRow("Temperature", value: temperatureBinding, range: -100...100)
            sliderRow("Tint",        value: tintBinding,        range: -100...100)
        }
    }

    private var levelsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Levels").font(.subheadline.weight(.semibold))
            sliderRow("Exposure",   value: exposureBinding,   range: -5...5, step: 0.05, format: "%+.2f")
            sliderRow("Contrast",   value: contrastBinding,   range: -100...100)
            sliderRow("Highlights", value: highlightsBinding, range: -100...100)
            sliderRow("Shadows",    value: shadowsBinding,    range: -100...100)
            sliderRow("Whites",     value: whitesBinding,     range: -100...100)
            sliderRow("Blacks",     value: blacksBinding,     range: -100...100)
            Divider().padding(.vertical, 2)
            sliderRow("Clarity",    value: clarityBinding,    range: -100...100)
            sliderRow("Dehaze",     value: dehazeBinding,     range: -100...100)
        }
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Color").font(.subheadline.weight(.semibold))
            sliderRow("Saturation", value: saturationBinding, range: -100...100)
            sliderRow("Vibrance",   value: vibranceBinding,   range: -100...100)
        }
    }

    // MARK: - Binding Adapters

    private var temperatureBinding: Binding<Double> {
        Binding(get: { layer.adjustments.temperature }, set: { layer.adjustments.temperature = $0 })
    }
    private var tintBinding: Binding<Double> {
        Binding(get: { layer.adjustments.tint }, set: { layer.adjustments.tint = $0 })
    }
    private var clarityBinding: Binding<Double> {
        Binding(get: { layer.adjustments.clarity }, set: { layer.adjustments.clarity = $0 })
    }
    private var dehazeBinding: Binding<Double> {
        Binding(get: { layer.adjustments.dehaze }, set: { layer.adjustments.dehaze = $0 })
    }
    private var exposureBinding: Binding<Double> {
        Binding(get: { layer.adjustments.exposure }, set: { layer.adjustments.exposure = $0 })
    }
    private var contrastBinding: Binding<Double> {
        Binding(get: { Double(layer.adjustments.contrast) }, set: { layer.adjustments.contrast = Int($0) })
    }
    private var highlightsBinding: Binding<Double> {
        Binding(get: { Double(layer.adjustments.highlights) }, set: { layer.adjustments.highlights = Int($0) })
    }
    private var shadowsBinding: Binding<Double> {
        Binding(get: { Double(layer.adjustments.shadows) }, set: { layer.adjustments.shadows = Int($0) })
    }
    private var whitesBinding: Binding<Double> {
        Binding(get: { Double(layer.adjustments.whites) }, set: { layer.adjustments.whites = Int($0) })
    }
    private var blacksBinding: Binding<Double> {
        Binding(get: { Double(layer.adjustments.blacks) }, set: { layer.adjustments.blacks = Int($0) })
    }
    private var saturationBinding: Binding<Double> {
        Binding(get: { Double(layer.adjustments.saturation) }, set: { layer.adjustments.saturation = Int($0) })
    }
    private var vibranceBinding: Binding<Double> {
        Binding(get: { Double(layer.adjustments.vibrance) }, set: { layer.adjustments.vibrance = Int($0) })
    }

    // MARK: - Slider Row

    @ViewBuilder
    private func sliderRow(
        _ label: String, value: Binding<Double>, range: ClosedRange<Double>,
        step: Double = 1, format: String = "%.0f",
        defaultValue: Double? = nil, displayValue: (() -> Double)? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 80, alignment: .leading)
                .foregroundStyle(.secondary)
                .onTapGesture(count: 2) {
                    value.wrappedValue = defaultValue ?? (range.lowerBound < 0 ? 0 : range.lowerBound)
                }
            Slider(value: value, in: range, step: step)
            Text(String(format: format, displayValue?() ?? value.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: 40, alignment: .trailing)
        }
    }
}
