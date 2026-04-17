import Foundation
import SwiftUI
import Combine
import GRDB

@MainActor
final class PrintTimelineViewModel: ObservableObject {
    @Published var timelineEntries: [PrintAttempt] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let repository: PrintAttemptRepository

    init(_ db: any DatabaseWriter) {
        self.repository = PrintAttemptRepository(db)
    }

    func loadTimeline(for photoId: String) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let entries = try await repository.fetchTimelineForPhoto(photoId)

            // Decode each ThreadEntry to PrintAttempt
            var attempts: [PrintAttempt] = []
            for entry in entries {
                if let attempt = try? decodeAttempt(from: entry.contentJson) {
                    attempts.append(attempt)
                }
            }

            self.timelineEntries = attempts
        } catch {
            self.errorMessage = "Failed to load timeline: \(error.localizedDescription)"
        }
    }

    private func decodeAttempt(from json: String) throws -> PrintAttempt {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PrintAttempt.self, from: json.data(using: .utf8)!)
    }
}
