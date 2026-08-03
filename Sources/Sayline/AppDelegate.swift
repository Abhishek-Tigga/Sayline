import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var isRecording = false
    @Published var isAccessibilityTrusted = false
    @Published var isMicAuthorized = false
    @Published var lastRecordingPath: String?
    @Published var isTranscribing = false
    @Published var lastTranscript: String?
    @Published var transcriptionError: String?

    private let hotkeyManager = HotkeyManager()
    private let audioRecorder = AudioRecorder()
    private let transcriber = GroqTranscriber()

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotkeyManager.onHotkeyDown = { [weak self] in
            DispatchQueue.main.async {
                self?.isRecording = true
                self?.transcriptionError = nil
                self?.audioRecorder.start()
            }
        }
        hotkeyManager.onHotkeyUp = { [weak self] in
            DispatchQueue.main.async { self?.handleHotkeyUp() }
        }

        refreshAccessibilityStatus()

        audioRecorder.requestMicPermission { [weak self] granted in
            self?.isMicAuthorized = granted
        }
    }

    private func handleHotkeyUp() {
        isRecording = false
        audioRecorder.stop()
        guard let url = audioRecorder.lastRecordingURL else { return }
        lastRecordingPath = url.path

        isTranscribing = true
        Task {
            do {
                let text = try await transcriber.transcribe(fileURL: url)
                await MainActor.run {
                    self.lastTranscript = text
                    self.isTranscribing = false
                    NSLog("Sayline: transcript -> \(text)")
                    TextInjector.insert(text)
                }
            } catch {
                await MainActor.run {
                    self.isTranscribing = false
                    self.transcriptionError = error.localizedDescription
                    NSLog("Sayline: transcription failed -> \(error.localizedDescription)")
                }
            }
        }
    }

    func refreshAccessibilityStatus() {
        isAccessibilityTrusted = AccessibilityPermission.isTrusted
        if isAccessibilityTrusted {
            hotkeyManager.start()
        }
    }

    func requestAccessibilityPermission() {
        AccessibilityPermission.requestIfNeeded()
    }
}
