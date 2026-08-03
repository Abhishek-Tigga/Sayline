import AVFoundation

/// Records microphone audio to a temp .wav file for the duration of a tap-hold.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private(set) var isRecording = false
    private(set) var lastRecordingURL: URL?

    func requestMicPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    func start() {
        guard !isRecording else { return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sayline-\(UUID().uuidString).wav")

        do {
            audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        } catch {
            NSLog("Sayline: failed to create audio file: \(error)")
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let file = self.audioFile else { return }
            do {
                try file.write(from: buffer)
            } catch {
                NSLog("Sayline: failed writing audio buffer: \(error)")
            }
        }

        do {
            try engine.start()
            isRecording = true
            lastRecordingURL = url
            NSLog("Sayline: recording started -> \(url.path)")
        } catch {
            NSLog("Sayline: failed to start audio engine: \(error)")
            input.removeTap(onBus: 0)
            audioFile = nil
        }
    }

    func stop() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil
        isRecording = false
        NSLog("Sayline: recording stopped -> \(lastRecordingURL?.path ?? "?")")
    }
}
