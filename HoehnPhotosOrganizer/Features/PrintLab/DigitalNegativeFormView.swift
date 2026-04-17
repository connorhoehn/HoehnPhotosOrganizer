import SwiftUI

struct DigitalNegativeFormView: View {
    @Binding var fields: [String: AnyCodable]

    @State private var inkjetType: String = "Epson"
    @State private var targetDensity: String = "3.0"
    @State private var transparentFilmBrand: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Inkjet Printer Type", systemImage: "printer")
                Picker("Printer", selection: $inkjetType) {
                    Text("Epson").tag("Epson")
                    Text("Canon").tag("Canon")
                    Text("HP").tag("HP")
                    Text("Other").tag("Other")
                }
                .pickerStyle(.segmented)
                .onChange(of: inkjetType) { _, _ in updateFields() }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Target Density", systemImage: "chart.bar.xaxis")
                TextField("e.g., 3.0", text: $targetDensity)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: targetDensity) { _, _ in updateFields() }
                Text("Range: 0.0 (clear) to 4.0 (max black)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Transparent Film Brand (optional)", systemImage: "doc")
                TextField("e.g., Pictorico OHP", text: $transparentFilmBrand)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: transparentFilmBrand) { _, _ in updateFields() }
            }
        }
        .onAppear { loadFieldsFromBinding() }
    }

    private func loadFieldsFromBinding() {
        if let ijt = fields["inkjetType"]?.value as? String { inkjetType = ijt }
        if let td = fields["targetDensity"]?.value as? String { targetDensity = td }
        if let tfb = fields["transparentFilmBrand"]?.value as? String { transparentFilmBrand = tfb }
    }

    private func updateFields() {
        fields["inkjetType"] = AnyCodable(inkjetType)
        fields["targetDensity"] = AnyCodable(targetDensity)
        fields["transparentFilmBrand"] = AnyCodable(transparentFilmBrand)
    }
}

#Preview {
@Previewable @State var fields: [String: AnyCodable] = [:]
    return DigitalNegativeFormView(fields: $fields)
}
