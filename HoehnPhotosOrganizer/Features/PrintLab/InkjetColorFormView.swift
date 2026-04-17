import SwiftUI

struct InkjetColorFormView: View {
    @Binding var fields: [String: AnyCodable]

    @State private var colorSpace: String = "RGB"
    @State private var iccProfile: String = ""
    @State private var dropSize: String = "medium"
    @State private var printSpeed: Int = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Color Space", systemImage: "paintpalette")
                Picker("Color Space", selection: $colorSpace) {
                    Text("sRGB").tag("RGB")
                    Text("Adobe RGB").tag("AdobeRGB")
                    Text("ProPhoto RGB").tag("ProPhoto")
                }
                .pickerStyle(.segmented)
                .onChange(of: colorSpace) { _, _ in updateFields() }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("ICC Profile (optional)", systemImage: "doc.text")
                TextField("e.g., ColorLogic_RGB.icc", text: $iccProfile)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: iccProfile) { _, _ in updateFields() }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Drop Size", systemImage: "option")
                Picker("Drop Size", selection: $dropSize) {
                    Text("Small").tag("small")
                    Text("Medium").tag("medium")
                    Text("Large").tag("large")
                }
                .pickerStyle(.segmented)
                .onChange(of: dropSize) { _, _ in updateFields() }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Print Speed (ppm)").font(.subheadline)
                Stepper(value: $printSpeed, in: 1...12, step: 1) {
                    Text("\(printSpeed) ppm")
                }
                .onChange(of: printSpeed) { _, _ in updateFields() }
            }
        }
        .onAppear { loadFieldsFromBinding() }
    }

    private func loadFieldsFromBinding() {
        if let cs = fields["colorSpace"]?.value as? String { colorSpace = cs }
        if let ip = fields["iccProfile"]?.value as? String { iccProfile = ip }
        if let ds = fields["dropSize"]?.value as? String { dropSize = ds }
        if let ps = fields["printSpeed"]?.value as? Int { printSpeed = ps }
    }

    private func updateFields() {
        fields["colorSpace"] = AnyCodable(colorSpace)
        fields["iccProfile"] = AnyCodable(iccProfile)
        fields["dropSize"] = AnyCodable(dropSize)
        fields["printSpeed"] = AnyCodable(printSpeed)
    }
}

#Preview {
@Previewable @State var fields: [String: AnyCodable] = [:]
    return InkjetColorFormView(fields: $fields)
}
