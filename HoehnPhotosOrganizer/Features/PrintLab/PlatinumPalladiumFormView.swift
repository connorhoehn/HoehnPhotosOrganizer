import SwiftUI

struct PlatinumPalladiumFormView: View {
    @Binding var fields: [String: AnyCodable]

    @State private var platinumPercent: Double = 95
    @State private var palladiumPercent: Double = 5
    @State private var ferricOxalateDrops: Int = 15
    @State private var chemistryDrops: Int = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Platinum/Palladium ratio
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Platinum %")
                    Spacer()
                    Text("\(Int(platinumPercent))%")
                }
                Slider(value: $platinumPercent, in: 0...100, step: 1)
                    .onChange(of: platinumPercent) { old, new in
                        // Keep palladium complementary
                        palladiumPercent = max(0, 100 - new)
                        updateFields()
                    }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Palladium %")
                    Spacer()
                    Text("\(Int(palladiumPercent))%")
                }
                Slider(value: $palladiumPercent, in: 0...100, step: 1)
                    .onChange(of: palladiumPercent) { old, new in
                        platinumPercent = max(0, 100 - new)
                        updateFields()
                    }
            }

            // Chemistry parameters
            VStack(alignment: .leading, spacing: 8) {
                Text("Ferric Oxalate Drops").font(.subheadline)
                Stepper(value: $ferricOxalateDrops, in: 0...50, step: 1) {
                    Text("\(ferricOxalateDrops) drops")
                }
                .onChange(of: ferricOxalateDrops) { _, _ in updateFields() }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Chemistry Drops").font(.subheadline)
                Stepper(value: $chemistryDrops, in: 0...50, step: 1) {
                    Text("\(chemistryDrops) drops")
                }
                .onChange(of: chemistryDrops) { _, _ in updateFields() }
            }
        }
        .onAppear {
            loadFieldsFromBinding()
        }
    }

    private func loadFieldsFromBinding() {
        if let pt = fields["platinumPercent"]?.value as? Double {
            platinumPercent = pt
        }
        if let pd = fields["palladiumPercent"]?.value as? Double {
            palladiumPercent = pd
        }
        if let ox = fields["ferricOxalateDrops"]?.value as? Int {
            ferricOxalateDrops = ox
        }
        if let ch = fields["chemistryDrops"]?.value as? Int {
            chemistryDrops = ch
        }
    }

    private func updateFields() {
        fields["platinumPercent"] = AnyCodable(platinumPercent)
        fields["palladiumPercent"] = AnyCodable(palladiumPercent)
        fields["ferricOxalateDrops"] = AnyCodable(ferricOxalateDrops)
        fields["chemistryDrops"] = AnyCodable(chemistryDrops)
    }
}

#Preview {
@Previewable @State var fields: [String: AnyCodable] = [:]
    return PlatinumPalladiumFormView(fields: $fields)
}
