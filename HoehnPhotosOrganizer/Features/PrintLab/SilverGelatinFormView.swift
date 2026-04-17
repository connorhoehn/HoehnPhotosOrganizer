import SwiftUI

struct SilverGelatinFormView: View {
    @Binding var fields: [String: AnyCodable]

    @State private var paperBrand: String = ""
    @State private var developerType: String = "D-76"
    @State private var tempC: String = "20"
    @State private var developmentTime: String = "90"
    @State private var fixerTime: String = "120"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Paper Brand", systemImage: "doc")
                TextField("e.g., Ilford MultiGrade FB", text: $paperBrand)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: paperBrand) { _, _ in updateFields() }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Developer Type", systemImage: "flask")
                Picker("Developer", selection: $developerType) {
                    Text("D-76").tag("D-76")
                    Text("D-23").tag("D-23")
                    Text("HC-110").tag("HC-110")
                    Text("Microdol-X").tag("Microdol-X")
                }
                .pickerStyle(.menu)
                .onChange(of: developerType) { _, _ in updateFields() }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Temperature (°C)", systemImage: "thermometer")
                TextField("e.g., 20", text: $tempC)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: tempC) { _, _ in updateFields() }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Development Time (seconds)", systemImage: "timer")
                TextField("e.g., 90", text: $developmentTime)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: developmentTime) { _, _ in updateFields() }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Fixer Time (seconds)", systemImage: "timer")
                TextField("e.g., 120", text: $fixerTime)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: fixerTime) { _, _ in updateFields() }
            }
        }
        .onAppear { loadFieldsFromBinding() }
    }

    private func loadFieldsFromBinding() {
        if let pb = fields["paperBrand"]?.value as? String { paperBrand = pb }
        if let dt = fields["developerType"]?.value as? String { developerType = dt }
        if let t = fields["tempC"]?.value as? String { tempC = t }
        if let devt = fields["developmentTime"]?.value as? String { developmentTime = devt }
        if let ft = fields["fixerTime"]?.value as? String { fixerTime = ft }
    }

    private func updateFields() {
        fields["paperBrand"] = AnyCodable(paperBrand)
        fields["developerType"] = AnyCodable(developerType)
        fields["tempC"] = AnyCodable(tempC)
        fields["developmentTime"] = AnyCodable(developmentTime)
        fields["fixerTime"] = AnyCodable(fixerTime)
    }
}

#Preview {
@Previewable @State var fields: [String: AnyCodable] = [:]
    return SilverGelatinFormView(fields: $fields)
}
