import SwiftUI

// MARK: - ToolbarSliderRow

/// Compact inline slider row for the studio horizontal toolbar.
/// Layout: label (fixed width) | slider | value readout (monospaced).
struct ToolbarSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String
    let onCommit: () -> Void

    init(
        _ label: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double = 1,
        format: String = "%.0f",
        onCommit: @escaping () -> Void
    ) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
        self.format = format
        self.onCommit = onCommit
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
                .lineLimit(1)

            Slider(value: $value, in: range, step: step) {
                EmptyView()
            } onEditingChanged: { editing in
                if !editing { onCommit() }
            }
            .frame(width: 80)
            .controlSize(.mini)

            Text(String(format: format, value))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)
        }
    }
}

// MARK: - ToolbarStepperRow

/// Compact inline stepper row for integer parameters.
struct ToolbarStepperRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            Text("\(value)")
                .font(.system(size: 9, design: .monospaced))
                .frame(width: 20, alignment: .center)

            Stepper("", value: $value, in: range) { editing in
                if !editing { onCommit() }
            }
            .labelsHidden()
            .controlSize(.mini)
        }
    }
}

// MARK: - ThresholdPopoverButton

/// Compact button that shows a popover for editing threshold arrays.
struct ThresholdPopoverButton: View {
    let label: String
    @Binding var thresholds: [Int]
    let valueRange: ClosedRange<Int>
    let onCommit: () -> Void

    @State private var showPopover = false

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)

            Button {
                showPopover.toggle()
            } label: {
                Text(thresholds.map(String.init).joined(separator: ","))
                    .font(.system(size: 9, design: .monospaced))
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .popover(isPresented: $showPopover) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Thresholds")
                        .font(.system(size: 11, weight: .medium))
                    ForEach(thresholds.indices, id: \.self) { i in
                        HStack(spacing: 4) {
                            Text("T\(i + 1)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            Slider(
                                value: Binding(
                                    get: { Double(thresholds[i]) },
                                    set: { thresholds[i] = Int($0) }
                                ),
                                in: Double(valueRange.lowerBound)...Double(valueRange.upperBound),
                                step: 1
                            ) {
                                EmptyView()
                            } onEditingChanged: { editing in
                                if !editing { onCommit() }
                            }
                            .frame(width: 120)
                            .controlSize(.small)

                            Text("\(thresholds[i])")
                                .font(.system(size: 9, design: .monospaced))
                                .frame(width: 28, alignment: .trailing)
                        }
                    }
                }
                .padding(10)
            }
        }
    }
}
