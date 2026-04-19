import SwiftUI

struct MetadataRow: View {
    var label: String
    var value: String?
    var systemImage: String? = nil
    var valueStyle: ValueStyle = .standard
    var copyable: Bool = true

    enum ValueStyle { case standard, mono, emphasis, muted }

    @State private var copied = false

    private var displayValue: String { value?.isEmpty == false ? value! : "—" }

    private var valueFont: Font {
        switch valueStyle {
        case .standard: return HPFont.metaValue
        case .mono: return .caption.weight(.medium).monospaced()
        case .emphasis: return HPFont.cardTitle
        case .muted: return HPFont.metaValue
        }
    }

    private var valueColor: Color {
        switch valueStyle {
        case .muted: return .secondary
        case .emphasis: return .primary
        default: return .primary
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HPSpacing.sm) {
            HStack(spacing: HPSpacing.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                }
                Text(label.uppercased())
                    .font(HPFont.metaLabel)
                    .foregroundStyle(.secondary)
                    .kerning(0.4)
            }
            Spacer(minLength: HPSpacing.sm)

            Text(copied ? "Copied" : displayValue)
                .font(valueFont)
                .foregroundStyle(copied ? HPColor.keeper : valueColor)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
                .contentTransition(.numericText())
        }
        .padding(.vertical, HPSpacing.xs)
        .contentShape(Rectangle())
        .onTapGesture {
            guard copyable, let value, !value.isEmpty else { return }
            UIPasteboard.general.string = value
            HPHaptic.selection()
            withAnimation(HPMotion.snappy) { copied = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                withAnimation(HPMotion.fadeSlow) { copied = false }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(displayValue)
        .accessibilityHint(copyable && value?.isEmpty == false ? "Double tap to copy" : "")
    }
}

#Preview("Metadata Rows") {
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
    }
    .padding()
}
