import SwiftUI

struct CyanotypeFormView: View {
    @Binding var fields: [String: AnyCodable]

    @State private var ferricAmmoniumCitrate: String = ""
    @State private var potassiumFerricyanide: String = ""
    @State private var exposureTime: String = ""
    @State private var negativeType: String = "transparent_negative"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Ferric Ammonium Citrate", systemImage: "flask")
                TextField("e.g., 12ml of 20% solution", text: $ferricAmmoniumCitrate)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: ferricAmmoniumCitrate) { _, _ in updateFields() }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Potassium Ferricyanide", systemImage: "flask")
                TextField("e.g., 3ml of 8% solution", text: $potassiumFerricyanide)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: potassiumFerricyanide) { _, _ in updateFields() }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Exposure Time (minutes)", systemImage: "timer")
                TextField("e.g., 12.5", text: $exposureTime)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: exposureTime) { _, _ in updateFields() }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Negative Type", systemImage: "photo")
                Picker("Negative Type", selection: $negativeType) {
                    Text("Direct Positive").tag("direct_positive")
                    Text("Transparent Negative").tag("transparent_negative")
                    Text("Printed Transparency").tag("printed_transparency")
                }
                .pickerStyle(.segmented)
                .onChange(of: negativeType) { _, _ in updateFields() }
            }
        }
        .onAppear { loadFieldsFromBinding() }
    }

    private func loadFieldsFromBinding() {
        if let fac = fields["ferricAmmoniumCitrate"]?.value as? String {
            ferricAmmoniumCitrate = fac
        }
        if let kf = fields["potassiumFerricyanide"]?.value as? String {
            potassiumFerricyanide = kf
        }
        if let et = fields["exposureTime"]?.value as? String {
            exposureTime = et
        }
        if let nt = fields["negativeType"]?.value as? String {
            negativeType = nt
        }
    }

    private func updateFields() {
        fields["ferricAmmoniumCitrate"] = AnyCodable(ferricAmmoniumCitrate)
        fields["potassiumFerricyanide"] = AnyCodable(potassiumFerricyanide)
        fields["exposureTime"] = AnyCodable(exposureTime)
        fields["negativeType"] = AnyCodable(negativeType)
    }
}

#Preview {
@Previewable @State var fields: [String: AnyCodable] = [:]
    return CyanotypeFormView(fields: $fields)
}
