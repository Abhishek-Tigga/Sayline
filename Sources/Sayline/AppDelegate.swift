import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private static let dictationStyleDefaultsKey = "com.abhishektigga.sayline.dictationStyle"

    @Published var isRecording = false
    @Published var isAccessibilityTrusted = false
    @Published var isMicAuthorized = false
    @Published var lastRecordingPath: String?
    @Published var isTranscribing = false
    @Published var isCleaningUp = false
    @Published var lastTranscript: String?
    @Published var transcriptionError: String?
    @Published var dictationStyle: DictationStyle = {
        if let raw = UserDefaults.standard.string(forKey: AppDelegate.dictationStyleDefaultsKey),
           let style = DictationStyle(rawValue: raw) {
            return style
        }
        return .clean
    }() {
        didSet {
            UserDefaults.standard.set(dictationStyle.rawValue, forKey: Self.dictationStyleDefaultsKey)
            indicatorWindow.updateStyle(dictationStyle)
        }
    }

    private let hotkeyManager = HotkeyManager()
    private let audioRecorder = AudioRecorder()
    private let transcriber = GroqTranscriber()
    private let cleaner = TranscriptCleaner()
    private let indicatorWindow = FloatingIndicatorWindow()

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotkeyManager.onHotkeyDown = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRecording = true
                self.transcriptionError = nil
                self.audioRecorder.start()
                self.indicatorWindow.show(state: .recording)
                self.indicatorWindow.updateStyle(self.dictationStyle)
            }
        }
        hotkeyManager.onHotkeyUp = { [weak self] in
            DispatchQueue.main.async { self?.handleHotkeyUp() }
        }
        hotkeyManager.onCycleStyleRequested = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.dictationStyle = self.dictationStyle.next()
            }
        }

        refreshAccessibilityStatus()

        audioRecorder.requestMicPermission { [weak self] granted in
            self?.isMicAuthorized = granted
        }
    }

    private func handleHotkeyUp() {
        isRecording = false
        audioRecorder.stop()
        guard let url = audioRecorder.lastRecordingURL else {
            indicatorWindow.hide()
            return
        }
        lastRecordingPath = url.path
        let style = dictationStyle

        isTranscribing = true
        transcriptionError = nil
        indicatorWindow.show(state: .transcribing)
        Task {
            do {
                let rawText = try await transcriber.transcribe(fileURL: url)
                NSLog("Sayline: raw transcript -> \(rawText)")

                await MainActor.run {
                    self.isTranscribing = false
                    self.isCleaningUp = true
                    self.indicatorWindow.show(state: .cleaningUp)
                }

                var finalText = rawText
                do {
                    finalText = try await cleaner.clean(rawText, style: style)
                    NSLog("Sayline: cleaned transcript (\(style.displayName)) -> \(finalText)")
                } catch {
                    NSLog("Sayline: cleanup failed, using raw transcript -> \(error.localizedDescription)")
                }

                await MainActor.run {
                    self.isCleaningUp = false
                    self.lastTranscript = finalText
                    self.indicatorWindow.hide()
                    TextInjector.insert(finalText)
                }
            } catch {
                await MainActor.run {
                    self.isTranscribing = false
                    self.transcriptionError = error.localizedDescription
                    self.indicatorWindow.hide()
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
