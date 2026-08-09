import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private static let useLocalTranscriptionDefaultsKey = "com.abhishektigga.sayline.useLocalTranscription"
    private static let historyDefaultsKey = "com.abhishektigga.sayline.history"
    private static let maxHistoryEntries = 20
    private static let preferredInputDeviceDefaultsKey = "com.abhishektigga.sayline.preferredInputDeviceUID"
    private static let hotkeyOptionDefaultsKey = "com.abhishektigga.sayline.hotkeyOption"

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
    @Published var hotkeyOption: HotkeyOption = {
        let raw = UserDefaults.standard.object(forKey: AppDelegate.hotkeyOptionDefaultsKey) as? Int64
        if let raw, let option = HotkeyOption(rawValue: raw) {
            return option
        }
        return .rightOption
    }() {
        didSet {
            UserDefaults.standard.set(hotkeyOption.rawValue, forKey: Self.hotkeyOptionDefaultsKey)
            hotkeyManager.hotkeyOption = hotkeyOption
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

    /// Captured once at hotkey-down (the moment dictation starts), used
    /// both for the debug readout and for the cleanup context.
    private var capturedFocusedAppInfo: FocusedAppInfo?

    /// Per-hold, not a persistent toggle — reset false on every
    /// hotkey-down, set true only if Space is pressed during that hold.
    private var isAgentModeThisRecording = false

    private let hotkeyManager = HotkeyManager()
    private let audioRecorder = AudioRecorder()
    private let cloudTranscriber = GroqTranscriber()
    private let localTranscriber = WhisperKitTranscriber()
    private let cleaner = TranscriptCleaner()
    private let agentRouter = AgentRouter()
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
        hotkeyManager.hotkeyOption = hotkeyOption
        hotkeyManager.onHotkeyDown = { [weak self] in
            DispatchQueue.main.async { self?.beginRecording() }
        }
        hotkeyManager.onHotkeyUp = { [weak self] in
            DispatchQueue.main.async { self?.handleHotkeyUp() }
        }
        hotkeyManager.onAgentModeRequested = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isAgentModeThisRecording = true
                self.indicatorWindow.updateAgentMode(true)
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

    private func addHistoryEntry(text: String, usedLocal: Bool) {
        let entry = HistoryEntry(id: UUID(), timestamp: Date(), text: text, usedLocal: usedLocal)
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

    private func beginRecording() {
        SoundEffectPlayer.shared.playHotkeyDown()
        isRecording = true
        transcriptionError = nil
        isAgentModeThisRecording = false
        let appInfo = FocusedAppReader.current()
        capturedFocusedAppInfo = appInfo
        NSLog("Sayline: focused app -> \(appInfo.name) [\(appInfo.bundleID ?? "?")] window: \(appInfo.windowTitle ?? "?") -> context: \(appInfo.context.rawValue)")
        audioRecorder.start(preferredDeviceUID: preferredInputDeviceUID)
        indicatorWindow.show(state: .recording)
        indicatorWindow.updateAgentMode(false)
    }

    private func handleHotkeyUp() {
        SoundEffectPlayer.shared.playHotkeyUp()
        isRecording = false
        audioRecorder.stop()
        guard let url = audioRecorder.lastRecordingURL else {
            indicatorWindow.hide()
            return
        }
        lastRecordingPath = url.path

        guard !audioRecorder.isTooShortOrSilent() else {
            NSLog("Sayline: recording too short/silent (\(audioRecorder.lastRecordingDuration)s) -> skipping transcription")
            indicatorWindow.hide()
            return
        }

        if isAgentModeThisRecording {
            handleAgentModeHotkeyUp(url: url)
            return
        }

        let context = capturedFocusedAppInfo?.context ?? .general
        let usingLocal = useLocalTranscription && localTranscriber.isReady

        isTranscribing = true
        transcriptionError = nil
        indicatorWindow.show(state: .transcribing)
        Task {
            do {
                let rawText = try await activeTranscriber.transcribe(fileURL: url)
                NSLog("Sayline: raw transcript (\(usingLocal ? "local" : "cloud")) -> \(rawText)")

                if let command = VoiceCommand.detect(in: rawText) {
                    NSLog("Sayline: voice command detected -> \(command)")
                    await MainActor.run {
                        self.isTranscribing = false
                        self.indicatorWindow.hide()
                        self.runCommand(command)
                    }
                    return
                }

                await MainActor.run {
                    self.isTranscribing = false
                    self.isCleaningUp = true
                    self.indicatorWindow.show(state: .cleaningUp)
                }

                var finalText = rawText
                do {
                    finalText = try await cleaner.clean(rawText, context: context)
                    NSLog("Sayline: cleaned transcript (context: \(context.rawValue)) -> \(finalText)")
                } catch {
                    NSLog("Sayline: cleanup failed, using raw transcript -> \(error.localizedDescription)")
                }

                await MainActor.run {
                    self.isCleaningUp = false
                    self.lastTranscript = finalText
                    self.indicatorWindow.hide()
                    self.addHistoryEntry(text: finalText, usedLocal: usingLocal)
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

    private func handleAgentModeHotkeyUp(url: URL) {
        isTranscribing = true
        transcriptionError = nil
        indicatorWindow.show(state: .transcribing)
        Task {
            do {
                let transcript = try await activeTranscriber.transcribe(fileURL: url)
                NSLog("Sayline: agent transcript -> \(transcript)")

                await MainActor.run {
                    self.isTranscribing = false
                    self.indicatorWindow.showTranscript(transcript)
                    self.indicatorWindow.show(state: .agentRouting)
                }

                let actions = try await agentRouter.route(transcript)

                await MainActor.run {
                    self.indicatorWindow.hide()
                    guard !actions.isEmpty else {
                        NSLog("Sayline: agent could not determine an action for \"\(transcript)\"")
                        self.indicatorWindow.flashMessage("Agent: nothing matched")
                        return
                    }
                    var anyFailed = false
                    for action in actions {
                        NSLog("Sayline: agent executing -> \(action)")
                        if case .answerQuery(let query) = action {
                            let answer = AgentExecutor.answer(query)
                            NSLog("Sayline: agent answered -> \(answer)")
                            self.indicatorWindow.flashMessage(answer, duration: 4.5)
                            continue
                        }
                        if case .openSystemSettingsFallback(let requestedPaneName) = action {
                            AgentExecutor.execute(action)
                            self.indicatorWindow.flashMessage("Couldn't find \"\(requestedPaneName)\" settings", duration: 3.0)
                            continue
                        }
                        if !AgentExecutor.execute(action) {
                            anyFailed = true
                        }
                    }
                    if anyFailed {
                        self.indicatorWindow.flashMessage("Agent: couldn't complete that")
                    }
                }
            } catch {
                await MainActor.run {
                    self.isTranscribing = false
                    self.transcriptionError = error.localizedDescription
                    NSLog("Sayline: agent transcription/routing failed -> \(error.localizedDescription)")
                    self.indicatorWindow.flashMessage("Agent: request failed")
                }
            }
        }
    }

    private func runCommand(_ command: VoiceCommand) {
        switch command {
        case .scratchThat:
            TextInjector.undo()
        case .newParagraph:
            TextInjector.insert("\n\n")
        case .newLine:
            TextInjector.insert("\n")
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
