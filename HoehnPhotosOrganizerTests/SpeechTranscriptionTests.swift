import XCTest
import Speech
@testable import HoehnPhotosOrganizer

@MainActor
final class SpeechTranscriptionTests: XCTestCase {

    var transcriber: SpeechTranscriptionService!

    override func setUp() {
        super.setUp()
        transcriber = SpeechTranscriptionService()
    }

    override func tearDown() {
        transcriber = nil
        super.tearDown()
    }

    func testSpeechRecognizerAvailability() {
        // SFSpeechRecognizer availability varies per system — just verify it initializes
        XCTAssertNotNil(SFSpeechRecognizer(locale: Locale(identifier: "en-US")))
    }

    func testTranscribeAudioFileReturnsText() throws {
        // AVAudioSession is unavailable on macOS; real transcription tested via integration test
        throw XCTSkip("AVAudioSession unavailable on macOS — audio recording test skipped")
    }

    func testTranscriptionWithUnavailableRecognizer() async throws {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        if let recognizer = recognizer, !recognizer.isAvailable {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("test_\(UUID().uuidString).m4a")

            do {
                _ = try await transcriber.transcribe(audioURL: tempURL)
                XCTFail("Should have thrown recognizerUnavailable")
            } catch TranscriptionError.recognizerUnavailable {
                XCTAssertTrue(true, "Should throw recognizerUnavailable")
            }
        } else {
            throw XCTSkip("Speech recognizer is available on this system")
        }
    }

    func testTranscriptionErrorHandling() async throws {
        let badURL = URL(fileURLWithPath: "/nonexistent/audio.m4a")

        do {
            _ = try await transcriber.transcribe(audioURL: badURL)
            XCTFail("Should have thrown an error for non-existent file")
        } catch {
            XCTAssertTrue(true, "Should throw error for invalid file path")
        }
    }
}
