import XCTest
@testable import HoehnPhotosOrganizer

@MainActor
final class VoiceMemoTests: XCTestCase {

    func testVoiceMemoRecorderInitialState() {
        let recorder = VoiceMemoRecorder()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.recordingDuration, 0)
        XCTAssertNil(recorder.audioURL)
    }

    func testStartRecordingCreatesAudioFile() async throws {
        let recorder = VoiceMemoRecorder()
        try await recorder.startRecording()

        XCTAssertTrue(recorder.isRecording)
        XCTAssertNotNil(recorder.audioURL)

        let audioURL = try XCTUnwrap(recorder.audioURL)
        let fileExists = FileManager.default.fileExists(atPath: audioURL.path)
        XCTAssertTrue(fileExists, "Temporary audio file should exist")

        recorder.stopRecording()
    }

    func testStopRecordingPreservesAudio() async throws {
        let recorder = VoiceMemoRecorder()
        try await recorder.startRecording()

        let audioURL = try XCTUnwrap(recorder.audioURL)

        // Let it record briefly
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        recorder.stopRecording()

        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))

        let fileSize = try FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int
        XCTAssertGreaterThan(fileSize ?? 0, 0, "Audio file should have content")

        // Cleanup
        try? FileManager.default.removeItem(at: audioURL)
    }

    func testRecordingDurationUpdates() async throws {
        let recorder = VoiceMemoRecorder()
        try await recorder.startRecording()

        let initialDuration = recorder.recordingDuration

        // Wait for duration to update
        try await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds

        let updatedDuration = recorder.recordingDuration
        XCTAssertGreaterThan(updatedDuration, initialDuration, "Duration should increase while recording")

        recorder.stopRecording()

        // Cleanup
        if let audioURL = recorder.audioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
    }
}
