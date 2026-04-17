import SwiftUI

struct PrintTypeSelector: View {
    @Binding var selectedType: PrintType

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Print Type", systemImage: "printer")
                .font(.headline)

            Picker("Select Print Type", selection: $selectedType) {
                ForEach(PrintType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)

            // Show description of selected type
            Text(printTypeDescription(selectedType))
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding()
    }

    private func printTypeDescription(_ type: PrintType) -> String {
        switch type {
        case .inkjetColor:
            "Digital color printing on photo paper"
        case .inkjetBW:
            "Digital black & white printing"
        case .silverGelatinDarkroom:
            "Traditional silver gelatin emulsion darkroom printing"
        case .platinumPalladium:
            "Precious metal process with platinum and palladium"
        case .cyanotype:
            "Iron-based blue process"
        case .digitalNegative:
            "Digital negative creation for contact printing"
        }
    }
}

#Preview {
@Previewable @State var type = PrintType.platinumPalladium
    return PrintTypeSelector(selectedType: $type)
}
