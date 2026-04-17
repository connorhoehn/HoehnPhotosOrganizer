import AVFoundation
import Combine
import Foundation

@MainActor
final class VoiceMemoRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var audioURL: URL?

    private var audioRecorder: AVAudioRecorder?
    private var displayLinkTask: Task<Void, Never>?

    func startRecording() async throws {
        // Create temp file for recording
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice_memo_\(UUID().uuidString).m4a")

        // Set up recorder with settings (MPEG4AAC, 16kHz sample rate, mono)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000.0,  // 16kHz suitable for speech recognition
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        let recorder = try AVAudioRecorder(url: tempURL, settings: settings)
        recorder.delegate = self
        recorder.record()

        self.audioRecorder = recorder
        self.audioURL = tempURL
        self.isRecording = true
        self.recordingDuration = 0

        // Update duration every 100ms using async task
        startDurationUpdates()
    }

    func stopRecording() {
        audioRecorder?.stop()
        audioRecorder = nil
        isRecording = false
        displayLinkTask?.cancel()
        displayLinkTask = nil
    }

    private func startDurationUpdates() {
        displayLinkTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                if !Task.isCancelled {
                    recordingDuration = audioRecorder?.currentTime ?? 0
                }
            }
        }
    }

    // MARK: - AVAudioRecorderDelegate
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        // Optional: handle recording finish events
    }
}
