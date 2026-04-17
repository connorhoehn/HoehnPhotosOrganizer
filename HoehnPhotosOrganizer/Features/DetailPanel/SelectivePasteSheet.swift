import SwiftUI

struct SelectivePasteSheet: View {
    @Binding var options: PasteOptions
    let targetCount: Int
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Paste Adjustments")
                .font(.headline)
            Text("Apply to \(targetCount) selected photo\(targetCount == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
                .font(.subheadline)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Choose what to paste:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Tone (Exposure, Contrast, Highlights, Shadows, Whites, Blacks)", isOn: $options.tone)
                Toggle("Color (Saturation, Vibrance)", isOn: $options.color)
                Toggle("Tone Curve", isOn: $options.curves)
                Toggle("HSL", isOn: $options.hsl)
                Toggle("Color Grading", isOn: $options.colorGrading)
                Toggle("Color Balance", isOn: $options.colorBalance)
                Toggle("Camera Calibration", isOn: $options.calibration)
            }

            HStack {
                Button("Select All") {
                    options = .all
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape)
                Button("Paste Settings", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(!options.anySelected)
                    .keyboardShortcut(.return)
            }
        }
        .padding()
        .frame(minWidth: 380)
    }
}
