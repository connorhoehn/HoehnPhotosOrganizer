import Foundation

enum PrintType: String, CaseIterable, Identifiable, Codable {
    case inkjetColor = "inkjet_color"
    case inkjetBW = "inkjet_bw"
    case silverGelatinDarkroom = "silver_gelatin_darkroom"
    case platinumPalladium = "platinum_palladium"
    case cyanotype
    case digitalNegative = "digital_negative"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .inkjetColor:
            "Inkjet (Color)"
        case .inkjetBW:
            "Inkjet (B&W)"
        case .silverGelatinDarkroom:
            "Silver Gelatin Darkroom"
        case .platinumPalladium:
            "Platinum-Palladium"
        case .cyanotype:
            "Cyanotype"
        case .digitalNegative:
            "Digital Negative"
        }
    }

    var description: String {
        displayName
    }
}

enum PrintOutcome: String, CaseIterable, Identifiable, Codable {
    case pass
    case fail
    case needsAdjustment = "needs_adjustment"
    case testing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pass:
            "Pass"
        case .fail:
            "Fail"
        case .needsAdjustment:
            "Needs Adjustment"
        case .testing:
            "Testing"
        }
    }
}
