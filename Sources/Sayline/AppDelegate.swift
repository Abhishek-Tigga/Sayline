import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private static let dictationStyleDefaultsKey = "com.abhishektigga.sayline.dictationStyle"
    private static let useLocalTranscriptionDefaultsKey = "com.abhishektigga.sayline.useLocalTranscription"

    @Published var isRecording = false
    @Published var isAccessibilityTrusted = false
    @Published var isMicAuthorized = false
    @Published var lastRecordingPath: String?
    @Published var isTranscribing = false
    @Published var isCleaningUp = false
    @Published var lastTranscript: String?
    @Published var transcriptionError: String?
    @Published var isLocalModelDownloading = false
    @Published var isLocalModelReady = false
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
    @Published var useLocalTranscription: Bool = {
        UserDefaults.standard.bool(forKey: AppDelegate.useLocalTranscriptionDefaultsKey)
    }() {
        didSet {
            UserDefaults.standard.set(useLocalTranscription, forKey: Self.useLocalTranscriptionDefaultsKey)
            if useLocalTranscription {
                startLocalModelPreloadIfNeeded()
            }
        }
    }

    private let hotkeyManager = HotkeyManager()
    private let audioRecorder = AudioRecorder()
    private let cloudTranscriber = GroqTranscriber()
    private let localTranscriber = WhisperKitTranscriber()
    private let cleaner = TranscriptCleaner()
    private let indicatorWindow = FloatingIndicatorWindow()
    private lazy var settingsWindowController = SettingsWindowController(appDelegate: self)

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Sayline: failed to toggle launch at login -> \(error.localizedDescription)")
            }
        }
    }

    /// Local only once it's actually ready — while it's still
    /// downloading/loading, dictation silently keeps working via cloud
    /// instead of blocking on a multi-minute first-time download.
    private var activeTranscriber: Transcriber {
        (useLocalTranscription && localTranscriber.isReady) ? localTranscriber : cloudTranscriber
    }

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

        if useLocalTranscription {
            startLocalModelPreloadIfNeeded()
        }
    }

    /// Kicks off the local model download/load in the background, decoupled
    /// from any actual dictation attempt. Safe to call redundantly.
    private func startLocalModelPreloadIfNeeded() {
        guard !localTranscriber.isReady, !isLocalModelDownloading else { return }
        isLocalModelDownloading = true
        Task {
            await localTranscriber.preload()
            await MainActor.run {
                self.isLocalModelDownloading = false
                self.isLocalModelReady = self.localTranscriber.isReady
            }
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
        let usingLocal = useLocalTranscription && localTranscriber.isReady

        isTranscribing = true
        transcriptionError = nil
        indicatorWindow.show(state: .transcribing)
        Task {
            do {
                let rawText = try await activeTranscriber.transcribe(fileURL: url)
                NSLog("Sayline: raw transcript (\(usingLocal ? "local" : "cloud")) -> \(rawText)")

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

    func showSettings() {
        settingsWindowController.show()
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
