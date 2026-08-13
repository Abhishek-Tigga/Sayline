import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private static let useLocalTranscriptionDefaultsKey = "com.abhishektigga.sayline.useLocalTranscription"
    private static let historyDefaultsKey = "com.abhishektigga.sayline.history"
    private static let maxHistoryEntries = 20
    private static let preferredInputDeviceDefaultsKey = "com.abhishektigga.sayline.preferredInputDeviceUID"
    private static let hotkeyOptionDefaultsKey = "com.abhishektigga.sayline.hotkeyOption"
    private static let defaultModeIsWorkKey = "com.abhishektigga.sayline.defaultModeIsWork"
    private static let alwaysVerbatimKey = "com.abhishektigga.sayline.alwaysVerbatim"

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
        indicatorWindow.updateHotkeySymbol(hotkeyOption.shortSymbol)
            indicatorWindow.updateHotkeySymbol(hotkeyOption.shortSymbol)
        }
    }
    /// Flips the gestures for whoever spends their whole day in email:
    /// single press becomes Work, double-tap becomes Clean.
    ///
    /// Decision 6. The gesture always chooses the depth — this only
    /// changes which gesture means which, and the pill still says which
    /// mode is running before the user stops speaking.
    @Published var defaultModeIsWork: Bool =
        UserDefaults.standard.bool(forKey: AppDelegate.defaultModeIsWorkKey) {
        didSet { UserDefaults.standard.set(defaultModeIsWork, forKey: Self.defaultModeIsWorkKey) }
    }

    /// "Always insert my exact words" — the one surviving home of
    /// Verbatim, per decision 4.
    ///
    /// Skips both Clean and Work entirely. The dictation-style picker it
    /// replaces was removed in `abc2bd9` long before work mode, so there
    /// is no stored preference to migrate — checked rather than assumed.
    @Published var alwaysVerbatim: Bool =
        UserDefaults.standard.bool(forKey: AppDelegate.alwaysVerbatimKey) {
        didSet { UserDefaults.standard.set(alwaysVerbatim, forKey: Self.alwaysVerbatimKey) }
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
    /// Decided at hotkey-DOWN, not at release.
    ///
    /// The old check ran at hotkey-up, while the question's twenty-second
    /// countdown kept running through the hold. If it expired mid-sentence,
    /// the answer was no longer an answer: "yes, delete it" went down the
    /// dictation path and was typed into whatever app was focused — the one
    /// outcome the design says must never happen. The hold now claims the
    /// question at the moment it starts.
    private var accessibilityWatchdog: Timer?
    private var isAnsweringFollowUpThisRecording = false
    private var isAgentModeThisRecording = false
    /// Set per-hold by the double-tap, mirroring agent mode exactly.
    /// Routed only on the plain-dictation branch — decision 8: agent
    /// commands and spoken follow-up answers treat a double-tap as a
    /// single press, silently. There is no text to professionalize in
    /// "remind me to call the bank at 4", and touching it could only hurt.
    private var isWorkModeThisRecording = false

    private let hotkeyManager = HotkeyManager()
    @MainActor
    private lazy var turnRunner = AgentTurnRunner(
        indicator: indicatorWindow,
        reminders: reminders,
        meetings: meetings
    )
    @MainActor
    private lazy var meetings = MeetingCoordinator(indicator: indicatorWindow)
    @MainActor
    private lazy var reminders = ReminderCoordinator(
        indicator: indicatorWindow,
        hotkeySymbol: { [weak self] in self?.hotkeyOption.shortSymbol ?? "⌥" }
    )
    private let audioRecorder = AudioRecorder()
    private let cloudTranscriber = GroqTranscriber()
    private let localTranscriber = WhisperKitTranscriber()
    private let cleaner = TranscriptCleaner()
    private let workCleaner = WorkModeCleaner()
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
                SaylineLog.log("failed to toggle launch at login -> \(error.localizedDescription)")
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
        SaylineLog.startSession()
        StallWatchdog.shared.start()
        #if DEBUG
        // SAYLINE_TEST_STALL=3 blocks main for 3s shortly after launch, so
        // the watchdog can be seen firing rather than assumed to work.
        if let seconds = ProcessInfo.processInfo.environment["SAYLINE_TEST_STALL"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                SaylineLog.log("[test] blocking the main thread for \(seconds)s on purpose")
                Thread.sleep(forTimeInterval: seconds)
                SaylineLog.log("[test] main thread released")
            }
        }
        #endif
        AudioRecorder.sweepOrphanedRecordings()
        InstalledAppCatalog.load()
        #if DEBUG
        // Proves the address heuristic finds something on a real machine.
        // EventKit exposes no account address, so this reads calendar
        // titles, and a heuristic that quietly finds nothing would ship a
        // card saying "Google" and nothing else.
        Task { @MainActor in
            let store = MeetingStore()
            // Only meaningful once access exists. At launch it usually does
            // not, and the old unconditional version logged "0 provider(s)"
            // every cold start — which reads as "this user has no calendars"
            // and cost a round of misdiagnosis on 2026-08-12. Nothing in the
            // product computes accounts this early; the setup card builds
            // its list at answer time, after the grant.
            guard store.hasAccess else {
                SaylineLog.log("[accounts] calendar access not granted yet — not counting accounts")
                return
            }
            let accounts = store.connectedAccounts()
            SaylineLog.log("[accounts] \(accounts.count) provider(s): "
                + accounts.map { "\($0.provider)=\($0.addresses.joined(separator: "|"))" }
                    .joined(separator: "  "))
        }
        #endif
        hotkeyManager.hotkeyOption = hotkeyOption
        hotkeyManager.onHotkeyDown = { [weak self] in
            DispatchQueue.main.async { self?.beginRecording() }
        }
        hotkeyManager.onHotkeyUp = { [weak self] in
            DispatchQueue.main.async { self?.handleHotkeyUp() }
        }
        hotkeyManager.onWorkModeHold = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                // Recording is already running by now — the hold started
                // it. This only marks the mode and shows it, so the pill
                // can say "Work" while the user is still talking.
                // With the default flipped, a double-tap means Clean —
                // the second gesture is always "the other one", not always
                // Work.
                // Right Command while a question is on screen is still an
                // answer, not a work dictation. The answer path ignores
                // the flag anyway, but the pill would briefly claim a mode
                // that cannot apply.
                guard !self.indicatorWindow.isAwaitingSpokenAnswer else { return }
                let isWork = !self.defaultModeIsWork
                self.isWorkModeThisRecording = isWork
                self.indicatorWindow.updateWorkMode(isWork)
            }
        }
        // Escape dismisses a pending question. Observed on the tap rather
        // than handled by the panel, which never becomes key window — and
        // deliberately not consumed, so the key still reaches whatever the
        // user is actually working in.
        hotkeyManager.onEscapePressed = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.indicatorWindow.isAwaitingSpokenAnswer else { return }
                self.indicatorWindow.dismissFollowUp()
            }
        }
        // The tap gave up because macOS kept rejecting it. Say so — a
        // hotkey that silently stops working is the failure people cannot
        // report, and this one has a known remedy: relaunch.
        hotkeyManager.onTapGaveUp = { [weak self] in
            DispatchQueue.main.async {
                self?.indicatorWindow.showNotice(
                    "Hotkey turned off",
                    detail: "macOS kept rejecting Sayline's keyboard listener. Quit and reopen Sayline to restore it.",
                    pill: "Sayline", duration: 8.0
                )
            }
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
            // Pay the ~1s voice-processing setup here, once, while nobody
            // is speaking — rather than inside every hold, which is what
            // swallowed the first second of each recording.
            if granted { self?.audioRecorder.warmUp() }
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

    private func addHistoryEntry(text: String, usedLocal: Bool, mode: String) {
        let entry = HistoryEntry(id: UUID(), timestamp: Date(), text: text,
                                 usedLocal: usedLocal, mode: mode)
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

    /// True when we may actually record. Says why when we may not.
    ///
    /// Checked on every hold rather than once at launch. Without this the
    /// app records silence quite happily and then blames the input device,
    /// which is the most misleading thing it can say: the device is fine,
    /// the permission is missing, and the two have completely different
    /// fixes.
    private func microphoneIsUsable() -> Bool {
        switch AudioRecorder.micAuthorization {
        case .authorized:
            return true

        case .notDetermined:
            // Never asked, or the grant was lost with the last rebuild.
            // Ask now; this hold is spent either way, so say so plainly.
            SaylineLog.log("microphone not yet authorized — prompting")
            audioRecorder.requestMicPermission { [weak self] granted in
                guard let self else { return }
                self.isMicAuthorized = granted
                SaylineLog.log("microphone prompt answered -> \(granted ? "granted" : "denied")")
                self.indicatorWindow.showNotice(
                    granted ? "Microphone allowed" : "Microphone denied",
                    detail: granted ? "Hold the key again and speak"
                                    : "Dictation can't work without it",
                    pill: "Microphone", duration: 3.4)
            }
            return false

        default:
            // Denied or restricted. macOS will not show the prompt a second
            // time, so System Settings is the only route left.
            SaylineLog.log("microphone access is off — recording refused")
            isMicAuthorized = false
            indicatorWindow.askFollowUp(
                FollowUpRequest(
                    question: "Microphone access is off",
                    detail: "Sayline can't hear anything until it's turned on in System Settings.",
                    kind: .confirm(primary: "Open Settings", secondary: "Not now")
                )
            ) { answer in
                guard answer == .confirmed,
                      let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                else { return }
                NSWorkspace.shared.open(url)
            }
            return false
        }
    }

    private func beginRecording() {
        // Before anything else, and before the sound: starting a recording
        // we cannot capture wastes the hold and produces a confident,
        // wrong diagnosis at the end of it.
        guard microphoneIsUsable() else {
            // Nothing was started, so make sure the hotkey-up handler does
            // not find a stale file from an earlier hold and try to
            // transcribe it.
            audioRecorder.discardRecording(at: audioRecorder.lastRecordingURL)
            return
        }
        SoundEffectPlayer.shared.playHotkeyDown()
        isRecording = true
        transcriptionError = nil
        isAgentModeThisRecording = false
        // A single press means Work when the default is flipped; the
        // double-tap callback overrides this if one arrives.
        isWorkModeThisRecording = defaultModeIsWork
        indicatorWindow.updateWorkMode(defaultModeIsWork)
        isAnsweringFollowUpThisRecording = indicatorWindow.isAwaitingSpokenAnswer
        // A hold is the opposite of an absent user, and the timeout exists
        // for absence. Stop the clock until they let go.
        indicatorWindow.pauseFollowUpTimeout()
        let appInfo = FocusedAppReader.current()
        capturedFocusedAppInfo = appInfo
        SaylineLog.log("focused app -> \(appInfo.name) [\(appInfo.bundleID ?? "?")] window: \(appInfo.windowTitle ?? "?") -> context: \(appInfo.context.rawValue)")
        // Fire and forget: the engine now comes up on its own queue, so
        // this returns immediately and the pill appears without waiting on
        // CoreAudio. Failure is reported at hotkey-up, where the existing
        // no-audio path already lives.
        audioRecorder.start(preferredDeviceUID: preferredInputDeviceUID) { started in
            if !started { SaylineLog.log("audio engine did not start for this hold") }
        }
        // Open the TLS connection while the user is still speaking.
        //
        // The first rewrite of a session measured 5913 ms against 191-607
        // warm — connection setup, not the model. A hold lasts seconds;
        // the handshake costs nothing if they turn out not to want a
        // rewrite, and there is no keep-alive machinery to maintain.
        ConnectionWarmer.warm()
        indicatorWindow.show(state: .recording)
        // Answering a question is still part of the agent exchange, so the
        // pill keeps its agent styling. Resetting it here made the pill
        // claim to be plain dictation while the next hold was, in fact,
        // going to be routed as an answer.
        if !isAnsweringFollowUpThisRecording {
            indicatorWindow.updateAgentMode(false)
        }
    }

    private func handleHotkeyUp() {
        SoundEffectPlayer.shared.playHotkeyUp()
        isRecording = false
        // Everything below reads state the recorder settles as it shuts the
        // engine down — lastRecordingURL, capturedNoAudio, the duration —
        // so it has to run after that, not merely after asking for it.
        audioRecorder.stop { [weak self] in
            self?.finishRecording()
        }
    }

    /// Runs once the engine is fully stopped and its results are readable.
    private func finishRecording() {
        // The countdown stopped when the hold began, and every path out of
        // here except a delivered answer has to start it again.
        //
        // The first version of this only resumed when the hold was NOT an
        // answer, and the too-short and silent-audio guards return before
        // the answer is ever delivered — so a brief or silent answer hold
        // left the countdown frozen forever. The question then claimed every
        // later hold, and a dictation attempt hours afterwards would route
        // as an answer to a question the user had long forgotten.
        //
        // A defer covers every return, including ones added later.
        // resumeFollowUpTimeout is a no-op when nothing is paused.
        var deliveredAnAnswer = false
        defer {
            if !deliveredAnAnswer { indicatorWindow.resumeFollowUpTimeout() }
        }
        guard let url = audioRecorder.lastRecordingURL else {
            indicatorWindow.hide()
            return
        }
        // Name only. The file is deleted as soon as it has been
        // transcribed, so showing a path would point at nothing.
        lastRecordingPath = url.lastPathComponent

        // Caught before the silence check because it is a different failure
        // with a different fix. Sending a zero-frame file to Groq returns
        // "Audio file is too short", which reads like the user spoke briefly
        // when the real cause is that their input device gave us nothing.
        guard !audioRecorder.capturedNoAudio else {
            let device = audioRecorder.lastInputDeviceName
            // Silence has two causes and they need different fixes. A
            // permission that was revoked mid-session lands here rather
            // than in the guard above, so name it rather than sending
            // someone to check a cable that is fine.
            let authorized = AudioRecorder.micAuthorization == .authorized
            SaylineLog.log("no audio captured from \(device) over \(audioRecorder.lastRecordingDuration)s "
                + "— mic authorized: \(authorized)")
            indicatorWindow.show(state: .message(
                authorized ? "No audio from \(device)" : "Microphone access is off"))
            audioRecorder.discardRecording(at: url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                self?.indicatorWindow.hide()
            }
            return
        }

        guard !audioRecorder.isTooShortOrSilent() else {
            SaylineLog.log("recording too short/silent (\(audioRecorder.lastRecordingDuration)s) -> skipping transcription")
            audioRecorder.discardRecording(at: url)
            indicatorWindow.hide()
            return
        }

        // Decided at hotkey-down, so a timeout expiring mid-hold cannot
        // turn an answer into dictation. Requiring the agent chord again
        // would mean forgetting Space pastes an answer as text.
        if isAnsweringFollowUpThisRecording {
            deliveredAnAnswer = true
            handleSpokenFollowUpAnswer(url: url)
            return
        }

        if isAgentModeThisRecording {
            handleAgentModeHotkeyUp(url: url)
            return
        }

        let context = capturedFocusedAppInfo?.context ?? .general
        let usingLocal = useLocalTranscription && localTranscriber.isReady
        // Captured here, not read inside the Task: the flag is per-hold and
        // a later hold would otherwise change what this one does.
        let workMode = isWorkModeThisRecording

        isTranscribing = true
        transcriptionError = nil
        indicatorWindow.show(state: .transcribing)
        Task {
            do {
                defer { self.audioRecorder.discardRecording(at: url) }
                let rawText = try await activeTranscriber.transcribe(fileURL: url)
                SaylineLog.log("raw transcript (\(usingLocal ? "local" : "cloud")) -> \(rawText)")

                if WhisperHallucination.isLikelyHallucinated(rawText, audioPeak: audioRecorder.lastRecordingPeak) {
                    SaylineLog.log("discarded \"\(rawText)\" — quiet audio (peak \(audioRecorder.lastRecordingPeak)) plus a known Whisper filler phrase")
                    await MainActor.run {
                        self.isTranscribing = false
                        self.indicatorWindow.hide()
                        // Say so rather than doing nothing — a silent drop is
                        // indistinguishable from the app being broken.
                        self.indicatorWindow.flashMessage("Didn't catch that")
                    }
                    return
                }

                if let command = VoiceCommand.detect(in: rawText) {
                    SaylineLog.log("voice command detected -> \(command)")
                    await MainActor.run {
                        self.isTranscribing = false
                        self.indicatorWindow.hide()
                        self.runCommand(command)
                    }
                    return
                }

                // "Always insert my exact words" skips both modes. Nothing
                // is cleaned, nothing is rewritten, and no round trip is
                // paid for either.
                if await MainActor.run(body: { self.alwaysVerbatim }) {
                    SaylineLog.log("verbatim setting on — inserting the raw transcript")
                    await MainActor.run {
                        self.isTranscribing = false
                        self.finishDictation(with: rawText, producedBy: "verbatim", url: url,
                                             usedLocal: usingLocal)
                    }
                    return
                }

                await MainActor.run {
                    self.isTranscribing = false
                    self.isCleaningUp = true
                    self.indicatorWindow.show(state: .cleaningUp)
                }

                var finalText = rawText
                var producedBy = "clean"
                do {
                    // Clean and Work run CONCURRENTLY for a work hold.
                    //
                    // The first version awaited Clean and then started
                    // Work, justified as "Clean's output is the fallback,
                    // so it must exist first". That does not hold: it must
                    // exist before the fallback is *needed*, which is the
                    // rare path. Work needs only the raw transcript. Every
                    // successful work dictation was paying Clean's full
                    // duration for nothing — several hundred ms against a
                    // budget of about a second.
                    let cleanTask = Task { try await self.cleaner.clean(rawText, context: context) }
                    if workMode {
                        let outcome = try await workCleaner.rewrite(rawText, context: context)
                        switch outcome {
                        case .rewritten(let text):
                            cleanTask.cancel()
                            finalText = text
                            producedBy = "work"
                        case .rescued(let text, let broke):
                            cleanTask.cancel()
                            finalText = text
                            producedBy = "work (retry rescued \(broke.map(\.kind).joined(separator: "+")))"
                        case .fellBack(let reason):
                            // The one path that needs Clean, and it is
                            // already in flight rather than starting now.
                            finalText = try await cleanTask.value
                            producedBy = "work → fell back to clean"
                            await MainActor.run {
                                self.indicatorWindow.flashMessage(
                                    WorkModeCleaner.fallbackMessage(for: reason), duration: 3.4)
                            }
                        }
                        SaylineLog.log("[work] \(producedBy) -> \(finalText)")
                    } else {
                        finalText = try await cleanTask.value
                        SaylineLog.log("cleaned transcript (context: \(context.rawValue)) -> \(finalText)")
                    }

                } catch {
                    SaylineLog.log("cleanup failed, using raw transcript -> \(error.localizedDescription)")
                }

                let produced = producedBy
                await MainActor.run {
                    self.isCleaningUp = false
                    self.finishDictation(with: finalText, producedBy: produced, url: url,
                                         usedLocal: usingLocal)
                }
            } catch {
                await MainActor.run {
                    self.isTranscribing = false
                    self.transcriptionError = error.localizedDescription
                    self.indicatorWindow.hide()
                    SaylineLog.log("transcription failed -> \(error.localizedDescription)")
                }
            }
        }
    }

    /// Transcribes a hold made while a question is on screen, and hands the
    /// words to the window rather than pasting them.
    ///
    /// Nothing is ever inserted from this path. Someone answering "yes" to
    /// "delete the dentist reminder?" must not have the word typed into
    /// whatever they had focused.
    private func handleSpokenFollowUpAnswer(url: URL) {
        indicatorWindow.show(state: .transcribing)
        Task {
            defer { self.audioRecorder.discardRecording(at: url) }
            let text = try? await activeTranscriber.transcribe(fileURL: url)
            await MainActor.run {
                guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    // Nothing usable came back. The question stays, so give
                    // it its clock back — otherwise it sits there forever.
                    SaylineLog.log("follow-up answer was empty — leaving the question up")
                    self.indicatorWindow.resumeFollowUpTimeout()
                    return
                }
                SaylineLog.log("follow-up answer heard -> \(text)")
                self.indicatorWindow.answerFollowUp(spoken: text)
            }
        }
    }

    private func handleAgentModeHotkeyUp(url: URL) {
        isTranscribing = true
        transcriptionError = nil
        indicatorWindow.show(state: .transcribing)
        Task {
            do {
                defer { self.audioRecorder.discardRecording(at: url) }
                let transcript = try await activeTranscriber.transcribe(fileURL: url)
                SaylineLog.log("agent transcript -> \(transcript)")

                if WhisperHallucination.isLikelyHallucinated(transcript, audioPeak: audioRecorder.lastRecordingPeak) {
                    SaylineLog.log("discarded agent transcript \"\(transcript)\" — quiet audio (peak \(audioRecorder.lastRecordingPeak)) plus a known Whisper filler phrase")
                    await MainActor.run {
                        self.isTranscribing = false
                        self.indicatorWindow.hide()
                        self.indicatorWindow.flashMessage("Didn't catch that")
                    }
                    return
                }

                await MainActor.run {
                    self.isTranscribing = false
                    self.indicatorWindow.showTranscript(transcript)
                    self.indicatorWindow.show(state: .agentRouting)
                }

                // Try the tables before the model. Anything unambiguous —
                // "open Safari", "lock the screen", "what's my battery" —
                // is a lookup this app can already do, and it currently
                // waits a full round trip for an answer it holds.
                //
                // Feeds the same runner, so nothing downstream changes:
                // Empty Trash still asks, failures still report.
                let actions: [AgentAction]
                if let fast = FastRoute.action(for: transcript) {
                    SaylineLog.log("fast path answered \"\(transcript)\" with no round trip -> \(fast)")
                    actions = [fast]
                } else {
                    actions = try await agentRouter.route(transcript)
                }

                await MainActor.run {
                    // Deliberately NOT hidden here. Tearing the panel down
                    // and building a new one milliseconds later is what made
                    // a follow-up question invisible until the hotkey was
                    // pressed again. The indicator lives for the whole agent
                    // turn, and the runner decides how it ends.
                    guard !actions.isEmpty else {
                        SaylineLog.log("agent could not determine an action for \"\(transcript)\"")
                        self.indicatorWindow.flashMessage("Agent: nothing matched")
                        return
                    }
                    self.turnRunner.run(actions)
                }
            } catch {
                await MainActor.run {
                    self.isTranscribing = false
                    self.transcriptionError = error.localizedDescription
                    SaylineLog.log("agent transcription/routing failed -> \(error.localizedDescription)")
                    self.indicatorWindow.flashMessage("Agent: request failed")
                }
            }
        }
    }

    /// The one place a finished dictation lands, whichever mode produced
    /// it.
    ///
    /// `producedBy` reaches the history so "does anyone use work mode"
    /// becomes a question the data answers — decision 6's telemetry note,
    /// and one field rather than a subsystem.
    @MainActor
    private func finishDictation(with text: String, producedBy: String,
                                 url: URL, usedLocal: Bool) {
        lastTranscript = text
        indicatorWindow.hide()
        addHistoryEntry(text: text, usedLocal: usedLocal, mode: producedBy)
        TextInjector.insert(text)
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
            stopWatchingForAccessibility()
        } else {
            startWatchingForAccessibility()
        }
    }

    /// Polls until Accessibility is granted, then starts the hotkey.
    ///
    /// Trust used to be read at launch and on a menu button, and nowhere
    /// else. Granting it in System Settings therefore did nothing visible
    /// — the app had already decided it was untrusted and would not look
    /// again, so the honest-looking conclusion was "I granted it and the
    /// app is broken". macOS sends no notification when a grant changes,
    /// so polling is the available mechanism.
    ///
    /// Cheap and self-cancelling: `AXIsProcessTrusted()` is a local check,
    /// it runs every two seconds only while untrusted, and the timer stops
    /// the moment the tap installs.
    private func startWatchingForAccessibility() {
        guard accessibilityWatchdog == nil else { return }
        SaylineLog.log("not trusted for Accessibility — watching for the grant")
        accessibilityWatchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard AccessibilityPermission.isTrusted else { return }
            SaylineLog.log("Accessibility granted — starting the hotkey listener")
            self.isAccessibilityTrusted = true
            self.hotkeyManager.start()
            self.stopWatchingForAccessibility()
        }
    }

    private func stopWatchingForAccessibility() {
        accessibilityWatchdog?.invalidate()
        accessibilityWatchdog = nil
    }

#if DEBUG
    /// Blocks the main thread on purpose, to prove the watchdog detects it.
    /// A stall detector that has never been seen to fire is not evidence of
    /// anything.
    func debugStallMainThread() {
        SaylineLog.log("[test] blocking the main thread for 3s on purpose")
        Thread.sleep(forTimeInterval: 3)
        SaylineLog.log("[test] main thread released")
    }

    // MARK: - Follow-up test harness

    func debugAskForValue() {
        indicatorWindow.show(state: .message("Call the bank"))
        indicatorWindow.askFollowUp(
            FollowUpRequest(
                question: "What time should I remind you?",
                kind: .value(hint: "Hold \(hotkeyOption.shortSymbol) and say a time"),
                quickChoices: [
                    QuickChoice(label: "Tomorrow 9am", spoken: "tomorrow at 9am"),
                    QuickChoice(label: "No time", spoken: "no time"),
                ]
            )
        ) { [weak self] answer in
            self?.indicatorWindow.flashMessage("Answer: \(answer)", duration: 2.4)
        }
    }

    func debugAskYesNo() {
        indicatorWindow.show(state: .message("Join my next meeting"))
        indicatorWindow.askFollowUp(
            FollowUpRequest(
                question: "Calendar access is off. Open System Settings?",
                kind: .confirm(primary: "Open Settings", secondary: "Not now")
            )
        ) { [weak self] answer in
            self?.indicatorWindow.flashMessage("Answer: \(answer)", duration: 2.4)
        }
    }

    func debugAskDestructive() {
        indicatorWindow.show(state: .message("Cancel the dentist reminder"))
        indicatorWindow.askFollowUp(
            FollowUpRequest(
                question: "3 reminders match \"dentist\". Delete the closest?",
                detail: "Dentist appointment — Tue 11:00",
                kind: .confirm(primary: "Delete it", secondary: "Keep it"),
                isDestructive: true
            )
        ) { [weak self] answer in
            self?.indicatorWindow.flashMessage("Answer: \(answer)", duration: 2.4)
        }
    }
#endif

    func requestAccessibilityPermission() {
        AccessibilityPermission.requestIfNeeded()
    }
}
