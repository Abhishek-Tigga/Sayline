import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private static let dictationStyleDefaultsKey = "com.abhishektigga.sayline.dictationStyle"
    private static let useLocalTranscriptionDefaultsKey = "com.abhishektigga.sayline.useLocalTranscription"
    private static let historyDefaultsKey = "com.abhishektigga.sayline.history"
    private static let maxHistoryEntries = 20
    private static let preferredInputDeviceDefaultsKey = "com.abhishektigga.sayline.preferredInputDeviceUID"

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
    @Published private(set) var historyEntries: [HistoryEntry] = []
    @Published var preferredInputDeviceUID: String? = UserDefaults.standard.string(forKey: AppDelegate.preferredInputDeviceDefaultsKey) {
        didSet {
            UserDefaults.standard.set(preferredInputDeviceUID, forKey: Self.preferredInputDeviceDefaultsKey)
        }
    }
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
    private lazy var historyWindowController = HistoryWindowController(appDelegate: self)

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
                self.audioRecorder.start(preferredDeviceUID: self.preferredInputDeviceUID)
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

        loadHistory()
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: Self.historyDefaultsKey) else { return }
        historyEntries = (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(historyEntries) else { return }
        UserDefaults.standard.set(data, forKey: Self.historyDefaultsKey)
    }

    private func addHistoryEntry(text: String, style: DictationStyle, usedLocal: Bool) {
        let entry = HistoryEntry(id: UUID(), timestamp: Date(), text: text, style: style, usedLocal: usedLocal)
        historyEntries.insert(entry, at: 0)
        if historyEntries.count > Self.maxHistoryEntries {
            historyEntries.removeLast(historyEntries.count - Self.maxHistoryEntries)
        }
        saveHistory()
    }

    func clearHistory() {
        historyEntries.removeAll()
        saveHistory()
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
                    self.addHistoryEntry(text: finalText, style: style, usedLocal: usingLocal)
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

    func showHistory() {
        historyWindowController.show()
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
