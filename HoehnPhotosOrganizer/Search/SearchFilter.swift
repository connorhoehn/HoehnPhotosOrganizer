import Foundation

struct SearchFilter: Codable, Equatable {
    var location: String?
    var yearFrom: Int?
    var yearTo: Int?
    var cameraModel: String?
    var fileType: String?
    var curationState: String?    // CurationState.rawValue
    var processingState: String?  // ProcessingState.rawValue
    var keywords: [String]?
    var timeOfDay: String?        // TimeOfDay.rawValue
    // Phase 7 (07-06 SRCH-7): Smart album filter extensions
    var sceneType: String?        // SceneType.rawValue — landscape, portrait, architecture, stillLife, street, documentary, other
    var peopleDetected: Bool?     // true = with people, false = without people
    var printAttempted: Bool?     // true = has print attempts, false = no print attempts

    var isEmpty: Bool {
        location == nil && yearFrom == nil && yearTo == nil &&
        cameraModel == nil && fileType == nil && curationState == nil &&
        processingState == nil && (keywords == nil || keywords!.isEmpty) && timeOfDay == nil &&
        sceneType == nil && peopleDetected == nil && printAttempted == nil
    }
}
