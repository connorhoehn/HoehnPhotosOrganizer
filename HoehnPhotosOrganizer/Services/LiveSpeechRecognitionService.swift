import AVFoundation
import Combine
import Speech

// MARK: - LiveSpeechRecognitionService

/// Captures microphone input and streams on-device transcription via `SFSpeechRecognizer`.
/// Supports automatic stop after a configurable silence timeout.
///
/// Usage:
///   1. Call `requestPermissions()` on appear.
///   2. If `isAvailable`, show the mic button.
///   3. `startRecording()` / `stopRecording()` to toggle.
///   4. Observe `transcript` for streaming text.
@MainActor
final class LiveSpeechRecognitionService: ObservableObject {

    // MARK: - Published State

    @Published var isRecording = false
    @Published var transcript = ""
    @Published var error: String?
    @Published private(set) var permissionStatus: PermissionStatus = .unknown

    enum PermissionStatus { case unknown, authorized, denied }

    /// Whether speech recognition hardware + permissions allow usage.
    var isAvailable: Bool {
        permissionStatus == .authorized && recognizer?.isAvailable == true
    }

    // MARK: - Configuration

    /// Seconds of silence before automatically stopping. Set to 0 to disable.
    var silenceTimeout: TimeInterval = 3.0

    // MARK: - Private

    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var silenceTimer: Task<Void, Never>?

    // MARK: - Permissions

    func requestPermissions() async {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        guard speechStatus == .authorized else {
            permissionStatus = .denied
            return
        }

        // Also check microphone access (macOS 14+)
        let micGranted: Bool
        if #available(macOS 14, *) {
            micGranted = await AVAudioApplication.requestRecordPermission()
        } else {
            micGranted = true // Older macOS doesn't gate mic per-app the same way
        }

        permissionStatus = micGranted ? .authorized : .denied
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording, permissionStatus == .authorized else { return }
        guard let recognizer, recognizer.isAvailable else {
            error = "Speech recognizer unavailable"
            return
        }

        transcript = ""
        error = nil

        do {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true
            recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.recognitionRequest?.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    Task { @MainActor in
                        self.transcript = result.bestTranscription.formattedString
                        self.resetSilenceTimer()
                    }
                }
                if let error {
                    Task { @MainActor in
                        // Ignore cancellation errors from intentional stop
                        if (error as NSError).code != 216 { // 216 = recognition cancelled
                            self.error = error.localizedDescription
                        }
                        self.stopRecording()
                    }
                }
            }

            // Start silence timer
            resetSilenceTimer()
        } catch {
            self.error = error.localizedDescription
            stopRecording()
        }
    }

    func stopRecording() {
        silenceTimer?.cancel()
        silenceTimer = nil

        guard isRecording else { return }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecording = false
    }

    // MARK: - Silence Detection

    private func resetSilenceTimer() {
        silenceTimer?.cancel()
        guard silenceTimeout > 0 else { return }

        silenceTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.silenceTimeout ?? 3.0))
            guard !Task.isCancelled else { return }
            self?.stopRecording()
        }
    }
}
