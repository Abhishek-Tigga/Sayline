import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var isRecording = false
    @Published var isAccessibilityTrusted = false
    @Published var isMicAuthorized = false
    @Published var lastRecordingPath: String?
    @Published var isTranscribing = false
    @Published var isCleaningUp = false
    @Published var lastTranscript: String?
    @Published var transcriptionError: String?

    private let hotkeyManager = HotkeyManager()
    private let audioRecorder = AudioRecorder()
    private let transcriber = GroqTranscriber()
    private let cleaner = TranscriptCleaner()

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
        transcriptionError = nil
        Task {
            do {
                let rawText = try await transcriber.transcribe(fileURL: url)
                NSLog("Sayline: raw transcript -> \(rawText)")

                await MainActor.run {
                    self.isTranscribing = false
                    self.isCleaningUp = true
                }

                var finalText = rawText
                do {
                    finalText = try await cleaner.clean(rawText)
                    NSLog("Sayline: cleaned transcript -> \(finalText)")
                } catch {
                    NSLog("Sayline: cleanup failed, using raw transcript -> \(error.localizedDescription)")
                }

                await MainActor.run {
                    self.isCleaningUp = false
                    self.lastTranscript = finalText
                    TextInjector.insert(finalText)
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
