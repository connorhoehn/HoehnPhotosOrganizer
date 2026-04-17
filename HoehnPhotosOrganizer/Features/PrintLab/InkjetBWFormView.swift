import SwiftUI

struct InkjetBWFormView: View {
    @Binding var fields: [String: AnyCodable]

    @State private var burninDodgeNotes: String = ""
    @State private var toner: String = "none"
    @State private var dropSize: String = "medium"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Burn-in / Dodge Notes (optional)", systemImage: "pencil.and.scribble")
                TextField("e.g., dodged highlights 30%", text: $burninDodgeNotes)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: burninDodgeNotes) { _, _ in updateFields() }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Toner", systemImage: "paintpalette")
                Picker("Toner", selection: $toner) {
                    Text("None").tag("none")
                    Text("Selenium").tag("selenium")
                    Text("Gold").tag("gold")
                }
                .pickerStyle(.segmented)
                .onChange(of: toner) { _, _ in updateFields() }
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
        }
        .onAppear { loadFieldsFromBinding() }
    }

    private func loadFieldsFromBinding() {
        if let bdn = fields["burninDodgeNotes"]?.value as? String { burninDodgeNotes = bdn }
        if let t = fields["toner"]?.value as? String { toner = t }
        if let ds = fields["dropSize"]?.value as? String { dropSize = ds }
    }

    private func updateFields() {
        fields["burninDodgeNotes"] = AnyCodable(burninDodgeNotes)
        fields["toner"] = AnyCodable(toner)
        fields["dropSize"] = AnyCodable(dropSize)
    }
}

#Preview {
@Previewable @State var fields: [String: AnyCodable] = [:]
    return InkjetBWFormView(fields: $fields)
}
