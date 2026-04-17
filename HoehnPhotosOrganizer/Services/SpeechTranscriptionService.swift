import Speech
import Foundation

enum TranscriptionError: LocalizedError {
    case recognizerUnavailable
    case permissionDenied
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognizer is not available on this system"
        case .permissionDenied:
            return "Microphone access permission denied"
        case .processingFailed(let message):
            return "Speech processing failed: \(message)"
        }
    }
}

@MainActor
final class SpeechTranscriptionService {
    private let speechRecognizer: SFSpeechRecognizer?

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)

        return try await withCheckedThrowingContinuation { continuation in
            _ = recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    let transcriptionError = TranscriptionError.processingFailed(error.localizedDescription)
                    continuation.resume(throwing: transcriptionError)
                    return
                }

                if let result = result {
                    if result.isFinal {
                        let transcription = result.bestTranscription.formattedString
                        continuation.resume(returning: transcription)
                    }
                }
            }
        }
    }
}
