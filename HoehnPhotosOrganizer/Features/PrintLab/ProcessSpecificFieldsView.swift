import SwiftUI

struct ProcessSpecificFieldsView: View {
    @Binding var printType: PrintType
    @Binding var processFields: [String: AnyCodable]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Process-Specific Fields")
                .font(.headline)

            switch printType {
            case .platinumPalladium:
                PlatinumPalladiumFormView(fields: $processFields)
            case .cyanotype:
                CyanotypeFormView(fields: $processFields)
            case .inkjetColor:
                InkjetColorFormView(fields: $processFields)
            case .inkjetBW:
                InkjetBWFormView(fields: $processFields)
            case .silverGelatinDarkroom:
                SilverGelatinFormView(fields: $processFields)
            case .digitalNegative:
                DigitalNegativeFormView(fields: $processFields)
            }
        }
        .padding()
        .transition(.opacity)
    }
}

#Preview {
@Previewable @State var type = PrintType.platinumPalladium
@Previewable @State var fields: [String: AnyCodable] = [:]
    return ProcessSpecificFieldsView(printType: $type, processFields: $fields)
}
