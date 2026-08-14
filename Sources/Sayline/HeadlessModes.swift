import Foundation
import AVFoundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Command-line modes the app answers before it becomes an app.
///
/// The router eval needs the real system prompt, the real tool schema and
/// the real `parseAction`. It got them by concatenating a hand-maintained
/// list of source files into a throwaway Swift program — which broke three
/// separate times when `AgentRouter` gained a dependency nobody added to
/// the list, twice going unnoticed for a day because a broken harness and
/// an unrun harness look identical.
///
/// Asking the built binary removes the class outright. There is no list to
/// maintain, no reconstruction to drift, and the thing under test is the
/// thing that ships.
///
/// Runs before `NSApplication` exists, so nothing is launched, no menu bar
/// item appears, and no permission is touched.
enum HeadlessModes {
    /// Handles a mode if one was asked for, and exits. Returns normally
    /// when the app should start as an app.
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard arguments.count > 1 else { return }

        switch arguments[1] {
        case "--dump-config":
            dumpConfig()
        case "--parse-actions":
            parseActions()
        case "--work-rewrite":
            workRewrite(arguments: arguments)
        case "--fm-check", "--fm-clean", "--fm-work":
            // Measurement modes for the on-device model experiment. Gated
            // at runtime as well as compile time: the binary must still
            // launch on a Mac that has neither.
            if #available(macOS 26.0, *) {
                switch arguments[1] {
                case "--fm-check":
                    // Two extra arguments compare a language pair instead
                    // of reading the machine's. The mismatch branch is
                    // otherwise only reachable by changing System
                    // Settings, so this is the only way it stays tested.
                    if arguments.count > 3 {
                        emit(["mac": arguments[2], "siri": arguments[3],
                              "same": sameLanguage(arguments[2], arguments[3])])
                    } else {
                        emit(foundationModelAvailability())
                    }
                    exit(0)
                case "--fm-clean": foundationModelBatch(work: false)
                default:           foundationModelBatch(work: true)
                }
            } else {
                emit(["available": false, "reason": "macOSBelow26"]); exit(3)
            }
        case "--selftest-capture":
            let seconds = arguments.count > 2 ? Double(arguments[2]) ?? 3 : 3
            let holds = arguments.count > 3 ? Int(arguments[3]) ?? 1 : 1
            selftestCapture(seconds: seconds, holds: holds)
        default:
            return
        }
    }

    /// The system prompt and tool schema exactly as sent.
    private static func dumpConfig() {
        let router = AgentRouter()
        let payload: [String: Any] = [
            "systemPrompt": router.systemPrompt,
            "tools": router.tools,
            "strictTools": AgentRouter.strictTools(router.tools),
            // Work mode's prompt, so `eval/work-mode/run.py` scores the
            // wording that ships. It kept a hand-pasted copy, which is the
            // second-copy-of-one-truth failure this repo has already paid
            // for twice — and it would have quietly tested the old prompt
            // through the whole taste rebuild.
            "workPrompt": WorkModeCleaner.promptForContext(.general, signOffName: ""),
            "workPromptEmail": WorkModeCleaner.promptForContext(.email, signOffName: "Abhishek"),
            // The few-shot examples, for the same reason as the prompts
            // above: they are now part of every request, so a harness that
            // reads only the system prompt scores a payload production does
            // not send.
            "workExamples": WorkModeCleaner.examples.map {
                ["spoken": $0.spoken, "written": $0.written
                    .trimmingCharacters(in: .whitespacesAndNewlines)]
            },
            // Clean's prompt, for `eval/clean-mode/run.py`. Same reason as
            // the two above: Clean now has a frozen test set and a model
            // A/B, and both would otherwise score a pasted copy.
            "cleanPrompt": TranscriptCleaner.cleanPrompt,
        ]
        emit(payload)
        exit(0)
    }

    /// Reads tool calls from stdin and prints what the app would actually
    /// do with them.
    ///
    /// This is the half the eval could never see. It scored the model's raw
    /// output while production ran the result through pane correction,
    /// search-URL decomposition, invented-due-date stripping and personal
    /// page lookup — so the harness reimplemented some of that in Python
    /// and simply missed the rest. Cases flipped run to run for reasons
    /// that were nothing to do with the model.
    ///
    /// Input: `{"transcript": "...", "toolCalls": [ ... ]}` per line.
    /// Output: one JSON array of resulting actions per line.
    private static func parseActions() {
        let router = AgentRouter()
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let transcript = request["transcript"] as? String ?? ""
            let toolCalls = request["toolCalls"] as? [[String: Any]] ?? []

            // Complain about the wrong shape instead of printing "[]".
            //
            // `parseAction` wants OpenAI's own tool call, where `arguments`
            // is a JSON *string*. Feed it a dict — the obvious mistake, and
            // one made within an hour of this mode existing — and every
            // call parses to nil and this prints an empty array. "The app
            // does nothing" and "you fed me garbage" then look identical,
            // which is the exact confusion this whole mode was built to
            // end. So it is an error, loudly, on stderr.
            for call in toolCalls {
                guard let function = call["function"] as? [String: Any],
                      function["name"] is String,
                      function["arguments"] is String else {
                    FileHandle.standardError.write(Data("""
                        --parse-actions: malformed tool call. Expected OpenAI's shape
                          {"function": {"name": "...", "arguments": "<json string>"}}
                        with `arguments` as a STRING, not an object. Got:
                          \(call)

                        """.utf8))
                    exit(2)
                }
            }

            let actions = router.actionsForEval(fromToolCalls: toolCalls, transcript: transcript)
            emit(actions.map(describe))
        }
        exit(0)
    }

    /// A stable, comparable shape for one action. Deliberately not
    /// `String(describing:)`, whose output is a Swift implementation
    /// detail and would make the test set hostage to enum formatting.
    private static func describe(_ action: AgentAction) -> [String: Any] {
        ["action": name(of: action), "args": args(of: action)]
    }

    private static func name(of action: AgentAction) -> String {
        let described = describeParts(action)
        return described["action"] as? String ?? "?"
    }

    private static func args(of action: AgentAction) -> [String: Any] {
        var parts = describeParts(action)
        parts.removeValue(forKey: "action")
        return parts
    }

    private static func describeParts(_ action: AgentAction) -> [String: Any] {
        switch action {
        case .openApp(let name): return ["action": "openApp", "name": name]
        case .closeApp(let name): return ["action": "closeApp", "name": name]
        case .findFile(let query, let folder, let subpath):
            return ["action": "findFile", "query": query, "folder": folder.rawValue,
                    "subpath": subpath ?? ""]
        case .openFolder(let folder, let subpath):
            return ["action": "openFolder", "folder": folder.rawValue, "subpath": subpath ?? ""]
        case .openSystemSetting(let pane, _): return ["action": "openSystemSetting", "pane": pane]
        case .openSystemSettingsFallback(let requested):
            return ["action": "openSystemSettingsFallback", "requested": requested]
        case .lockScreen: return ["action": "lockScreen"]
        case .controlMedia(let command):
            return ["action": "controlMedia", "command": command.rawValue]
        case .closeCurrentTab: return ["action": "closeCurrentTab"]
        case .askWhatToPlay: return ["action": "askWhatToPlay"]
        case .setVolume(let change): return ["action": "setVolume", "change": change.rawValue]
        case .setWiFi(let on): return ["action": "setWiFi", "enabled": on]
        case .setDarkMode(let on): return ["action": "setDarkMode", "enabled": on]
        case .emptyTrash: return ["action": "emptyTrash"]
        case .takeScreenshot: return ["action": "takeScreenshot"]
        case .openWebsite(let label, let url):
            return ["action": "openWebsite", "label": label, "url": url.absoluteString]
        case .unknownWebsite(let requested):
            return ["action": "unknownWebsite", "requested": requested]
        case .openedSiteButCouldNotSearch(let label, let url, let query):
            return ["action": "openedSiteButCouldNotSearch", "label": label,
                    "url": url.absoluteString, "query": query]
        case .playOnYouTube(let query): return ["action": "playOnYouTube", "query": query]
        case .openDirectPage(let url, let site, let query):
            return ["action": "openDirectPage", "url": url.absoluteString,
                    "site": site, "query": query ?? ""]
        case .answerQuery(let query): return ["action": "answerQuery", "query": query.rawValue]
        case .createReminder(let title, let due):
            return ["action": "createReminder", "title": title,
                    "due": due.map { LocalTimestamp.string(from: $0) } ?? ""]
        case .cancelReminder(let name): return ["action": "cancelReminder", "name": name ?? ""]
        case .joinMeeting: return ["action": "joinMeeting"]
        case .whatsNextMeeting: return ["action": "whatsNextMeeting"]
        }
    }

    private static func emit(_ value: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
    }
}

extension HeadlessModes {
    /// Records for a few seconds through the real `AudioRecorder` and
    /// reports what landed on disk.
    ///
    /// Exists because every dictation regression in this project has been
    /// found by the user holding a key and reporting that nothing happened.
    /// Neither I nor a reviewer can press that key, so the capture path was
    /// the one part of the app nobody could test — which is why three fixes
    /// shipped in a row with a defect each. This makes it runnable:
    ///
    ///     Sayline --selftest-capture 3
    ///
    /// It answers the contract directly: did audio arrive, how fast, how
    /// much of the window was captured, and in what format.
    /// Runs a transcript through the real `WorkModeCleaner` and prints
    /// what work mode would insert.
    ///
    ///     Sayline --work-rewrite "so um I was thinking maybe we ship Tuesday"
    ///     Sayline --work-rewrite --context email --file transcripts.txt
    ///
    /// Exists because work mode is otherwise untestable until the
    /// double-tap gesture ships, and the gesture is the riskiest build in
    /// the feature — it touches the recording path that broke six times in
    /// one day. Being able to judge the *writing* before committing to the
    /// *gesture* separates two decisions that would otherwise arrive
    /// together. It also runs the real class end to end, which no test
    /// did.
    static func workRewrite(arguments: [String]) {
        var context = AppContext.general
        if let index = arguments.firstIndex(of: "--context"), index + 1 < arguments.count,
           let parsed = AppContext(rawValue: arguments[index + 1]) {
            context = parsed
        }
        var inputs: [String] = []
        if let index = arguments.firstIndex(of: "--file"), index + 1 < arguments.count {
            let text = (try? String(contentsOfFile: arguments[index + 1], encoding: .utf8)) ?? ""
            inputs = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        } else {
            // Drop flag VALUES too, not just the flags. "--context chat"
            // left "chat" behind and it was rewritten as a transcript.
            var skipNext = false
            inputs = arguments.dropFirst(2).filter { argument in
                if skipNext { skipNext = false; return false }
                if argument.hasPrefix("--") { skipNext = true; return false }
                return true
            }
        }
        guard !inputs.isEmpty else {
            print("usage: Sayline --work-rewrite \"transcript\" [--context email|chat|code|general]")
            exit(2)
        }

        let cleaner = WorkModeCleaner()
        let done = DispatchSemaphore(value: 0)
        Task {
            for raw in inputs {
                let started = Date()
                do {
                    let outcome = try await cleaner.rewrite(raw, context: context)
                    let ms = Date().timeIntervalSince(started) * 1000
                    print("\nsaid  : \(raw)")
                    switch outcome {
                    case .rewritten(let text):
                        print(String(format: "work  : %@   [clean, %.0f ms]", text, ms))
                    case .rescued(let text, let broke):
                        print(String(format: "work  : %@   [retry rescued %@, %.0f ms]",
                                     text, broke.map(\.kind).joined(separator: "+"), ms))
                    case .fellBack(let reason):
                        print(String(format: "work  : FELL BACK — %@   [%.0f ms]",
                                     WorkModeCleaner.fallbackMessage(for: reason), ms))
                    }
                } catch {
                    print("\nsaid  : \(raw)")
                    print("work  : failed — \(error.localizedDescription)")
                }
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 180)
        exit(0)
    }

    /// Loudest sample in a recorded file. The one number that separates
    /// "we recorded" from "we recorded silence".
    private static func peakAmplitude(of file: AVAudioFile) -> Float {
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channels = buffer.floatChannelData else { return 0 }
        var peak: Float = 0
        for c in 0..<Int(buffer.format.channelCount) {
            for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channels[c][i])) }
        }
        return peak
    }

    static func selftestCapture(seconds: Double, holds: Int = 1) {
        guard AudioRecorder.micAuthorization == .authorized else {
            print("microphone not authorized — grant it and rerun")
            exit(2)
        }

        // `AudioRecorder` hands its results back on the **main queue**, so
        // main has to keep servicing work rather than blocking on a
        // semaphore. Blocking it is why the first version of this reported
        // a 0.00s recording from a 719 KB file: the completions never ran,
        // and the harness read state that had not been finalised.
        //
        // Two probes before this one had the same shape of bug. A harness
        // that lies is worse than no harness, so this one spins the run
        // loop and asserts on what is actually on disk.
        func pump(until predicate: () -> Bool, limit: TimeInterval) {
            let deadline = Date().addingTimeInterval(limit)
            while !predicate() && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }

        // ONE recorder across every hold, exactly as the app does. Holds
        // two onward are what matters: all three regressions were invisible
        // on the first hold and obvious on the second.
        let recorder = AudioRecorder()
        let warmStart = Date()
        recorder.warmUp()
        pump(until: { false }, limit: 2.0)
        print(String(format: "warm-up window: %.0f ms, paid once", Date().timeIntervalSince(warmStart) * 1000))

        // Something for the microphone to hear. Without a sound source the
        // check cannot tell "capture is broken" from "the room is quiet",
        // which is precisely how a converter writing pure silence passed a
        // self-test that only looked at duration and file size.
        let talker = Process()
        talker.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        talker.arguments = ["-r", "170",
                            String(repeating: "Testing one two three four. ",
                                   count: Int(seconds * Double(max(1, holds))) + 6)]
        try? talker.run()
        defer { talker.terminate() }

        var failures = 0
        for hold in 1...max(1, holds) {
            var engineUp: Bool?
            let requested = Date()
            recorder.start { engineUp = $0 }
            pump(until: { engineUp != nil }, limit: 10)
            guard engineUp == true else {
                print("hold \(hold): FAIL — engine did not start")
                failures += 1
                continue
            }
            let latency = Date().timeIntervalSince(requested) * 1000

            pump(until: { false }, limit: seconds)

            var stopped = false
            recorder.stop { stopped = true }
            pump(until: { stopped }, limit: 10)

            guard let url = recorder.lastRecordingURL,
                  let file = try? AVAudioFile(forReading: url) else {
                print("hold \(hold): FAIL — no readable recording")
                failures += 1
                continue
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let kb = ((attrs?[.size] as? Int) ?? 0) / 1024
            let onDisk = Double(file.length) / file.fileFormat.sampleRate
            let peak = peakAmplitude(of: file)
            // The contract: fast to start, nearly all of the window on
            // disk, and actual sound in it.
            // Two populations, not one threshold with judgement calls
            // attached. Cold paths — audio engine, TLS, model load —
            // systematically differ from warm ones, so a first hold at
            // 1696 ms is not an outlier in the warm distribution, it is a
            // sample from a different one. Giving the bin a name means
            // nobody has to decide in the moment whether to believe a
            // number.
            let budget = hold == 1 ? 900.0 : 150.0
            let ok = latency < budget && onDisk > seconds * 0.8 && peak > 0.005
            if !ok { failures += 1 }
            print(String(format: "hold %d: start %3.0f ms · %.2fs of %.1fs · peak %.3f · %d Hz %d ch · %d KB  %@",
                         hold, latency, onDisk, seconds, peak,
                         Int(file.fileFormat.sampleRate), file.fileFormat.channelCount, kb,
                         ok ? "OK" : (peak <= 0.005 ? "<-- SILENT" : "<-- BREAKS THE CONTRACT")))
            recorder.discardRecording(at: url)
        }
        print(failures == 0
              ? "PASS — every hold met the contract (first-of-session < 900ms, warm < 150ms)"
              : "FAIL — \(failures) hold(s) broke the contract")
        exit(failures == 0 ? 0 : 1)
    }
}

// MARK: - Apple on-device Foundation Model, measurement only

/// Batch modes for the FoundationModels experiment (2026-08-14).
///
/// **Measurement only. Nothing here is wired into a production path.**
/// The question is whether macOS 26's built-in on-device model — free,
/// private, no download — can replace the cloud 8B for Clean and/or
/// `gpt-4.1-mini` for Work. The harnesses shell to these modes for the
/// same reason every other harness reads `--dump-config`: the prompt and
/// the guard under test must be the ones that ship, not a copy.
///
/// One deviation from production is unavoidable and is measured as such.
/// Work mode sends its three worked examples as alternating user and
/// assistant chat messages; `LanguageModelSession.respond(to:)` takes
/// instructions and a single prompt, with no assistant-turn equivalent in
/// that path. The examples are therefore folded into the instructions as
/// labelled text. If the Work arm loses on taste, that is one of the
/// candidate reasons and the ledger says so.
@available(macOS 26.0, *)
extension HeadlessModes {

    /// The Mac's language and Siri's language, which must match.
    ///
    /// Apple's `UnavailableReason` has three values and none of them says
    /// "your two language settings disagree" — a mismatch simply reports
    /// `appleIntelligenceNotEnabled`, which reads as "go and switch it
    /// on" and sends the user to a pane where the switch is not there.
    /// Confirmed on this machine 2026-08-14: Mac on English (India), Siri
    /// on English (United States), no toggle shown, no download offered.
    /// Setting Siri to English (India) changed the reason to
    /// `modelNotReady` and the download began.
    ///
    /// Both values are readable, so the app can say the true thing
    /// instead of the API's approximation.
    static func languageMismatch() -> (mac: String, siri: String)? {
        let mac = Locale.preferredLanguages.first ?? Locale.current.identifier
        guard let siri = UserDefaults(suiteName: "com.apple.assistant.backedup")?
                .string(forKey: "Session Language") else { return nil }
        return sameLanguage(mac, siri) ? nil : (mac, siri)
    }

    /// Compares two language tags the way Apple's requirement does:
    /// language *and* region, so en-IN and en-US are different, while
    /// "en_IN" and "en-IN" are the same.
    static func sameLanguage(_ a: String, _ b: String) -> Bool {
        func parts(_ tag: String) -> (String, String?) {
            let bits = tag.replacingOccurrences(of: "_", with: "-")
                .split(separator: "-").map(String.init)
            return (bits.first?.lowercased() ?? "",
                    bits.count > 1 ? bits[1].uppercased() : nil)
        }
        let (langA, regionA) = parts(a), (langB, regionB) = parts(b)
        guard langA == langB else { return false }
        guard let regionA, let regionB else { return true }
        return regionA == regionB
    }

    /// Availability, *which* condition failed, and what the user can
    /// actually do about it.
    static func foundationModelAvailability() -> [String: Any] {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return ["available": true]
        case .unavailable(let reason):
            let name: String
            var diagnosis: String
            switch reason {
            case .deviceNotEligible:
                name = "deviceNotEligible"
                diagnosis = "This Mac cannot run Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                name = "appleIntelligenceNotEnabled"
                // The language check comes FIRST, because a mismatch
                // produces this same reason and the honest instruction is
                // completely different: there is no switch to turn on
                // until the languages agree.
                if let (mac, siri) = languageMismatch() {
                    diagnosis = "Apple Intelligence needs your Mac and Siri set to the "
                        + "same language. Your Mac is \(mac) and Siri is \(siri). "
                        + "Change Siri's language to \(mac) in Settings."
                } else {
                    diagnosis = "Turn on Apple Intelligence in System Settings."
                }
            case .modelNotReady:
                name = "modelNotReady"
                diagnosis = "Apple Intelligence is on and the model is still downloading."
            @unknown default:
                name = "unknown"
                diagnosis = "Apple Intelligence is unavailable."
            }
            var payload: [String: Any] = [
                "available": false, "reason": name, "diagnosis": diagnosis,
                "settingsURL": "x-apple.systempreferences:com.apple.Siri-Settings.extension",
            ]
            if let (mac, siri) = languageMismatch() {
                payload["macLanguage"] = mac
                payload["siriLanguage"] = siri
            }
            return payload
        @unknown default:
            return ["available": false, "reason": "unknown"]
        }
    }

    /// One transcript through the on-device model.
    ///
    /// Returns the text, or a classified failure. A refusal is never
    /// retried into the score — it is a fallback, counted as its own
    /// class, because a model that declines to process ordinary work text
    /// has failed in a way an accuracy number would hide.
    private static func fmRespond(session: LanguageModelSession,
                                  prompt: String) async -> (text: String?, failure: String?) {
        do {
            let options = GenerationOptions(temperature: 0)
            let response = try await session.respond(to: prompt, options: options)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? (nil, "fm-refusal:empty") : (text, nil)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation:        return (nil, "fm-refusal:guardrail")
            case .refusal:                   return (nil, "fm-refusal:refusal")
            case .exceededContextWindowSize: return (nil, "fm-error:context-window")
            case .unsupportedLanguageOrLocale: return (nil, "fm-error:locale")
            case .assetsUnavailable:         return (nil, "fm-error:assets")
            default:                         return (nil, "fm-error:\(error)")
            }
        } catch {
            return (nil, "fm-error:\(error)")
        }
    }

    /// stdin: one `{"id","raw"}` per line. stdout: one result per line.
    ///
    /// `--fm-clean` runs Clean's shipping prompt and leaves validation to
    /// the harness, which applies `TranscriptCleanupValidator` exactly as
    /// production does. `--fm-work` runs the whole work pipeline in here —
    /// prompt, `FactGuard.verify`, one corrective retry, fallback —
    /// because those semantics live in the binary and reproducing them in
    /// Python is the copy-drift failure this project has paid for twice.
    static func foundationModelBatch(work: Bool) {
        let availability = foundationModelAvailability()
        guard availability["available"] as? Bool == true else {
            emit(["fatal": "foundation model unavailable", "availability": availability])
            exit(3)
        }

        let instructions: String
        if work {
            let examples = WorkModeCleaner.examples.map {
                "Spoken:\n\($0.spoken)\n\nWritten:\n\($0.written.trimmingCharacters(in: .whitespacesAndNewlines))"
            }.joined(separator: "\n\n---\n\n")
            instructions = WorkModeCleaner.promptForContext(.general, signOffName: "")
                + "\n\nWorked examples:\n\n" + examples
        } else {
            instructions = TranscriptCleaner.cleanPrompt
        }

        let session = LanguageModelSession(instructions: instructions)

        // On-device models pay a load cost on first use. Measured
        // separately so it does not smear across the per-call
        // distribution, and reported, because a cold first dictation is
        // what a user would actually feel.
        let warmStart = Date()
        session.prewarm()
        let warmup = Date().timeIntervalSince(warmStart) * 1000

        var lines: [(id: String, raw: String)] = []
        while let line = readLine(strippingNewline: true), !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? String, let raw = obj["raw"] as? String else { continue }
            lines.append((id, raw))
        }

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            var first = true
            for entry in lines {
                let started = Date()
                var payload: [String: Any] = ["id": entry.id]

                if work {
                    let pinned = FactGuard.promptBlock(for: FactGuard.extract(from: entry.raw))
                    let prompt = pinned.isEmpty ? entry.raw
                        : "\(entry.raw)\n\n[facts that must survive]\n\(pinned)"
                    let attempt = await fmRespond(session: session, prompt: prompt)

                    if let failure = attempt.failure {
                        payload["outcome"] = "fellBack"
                        payload["failure"] = failure
                    } else if let text = attempt.text {
                        let violations = FactGuard.verify(raw: entry.raw, rewrite: text,
                                                          context: .general)
                        if violations.isEmpty {
                            payload["outcome"] = "rewritten"
                            payload["out"] = text
                        } else {
                            // One corrective retry, naming the broken
                            // fact — the same shape production uses.
                            let why = violations.map(\.explanation).joined(separator: "; ")
                            let retry = await fmRespond(
                                session: session,
                                prompt: "\(entry.raw)\n\nYour previous answer broke a fact: "
                                    + "\(why). Rewrite it again, keeping every fact.")
                            if let retryText = retry.text {
                                let retryViolations = FactGuard.verify(
                                    raw: entry.raw, rewrite: retryText, context: .general)
                                payload["outcome"] = retryViolations.isEmpty ? "rescued" : "fellBack"
                                payload["out"] = retryText
                                payload["firstBroke"] = violations.map(\.kind)
                                if !retryViolations.isEmpty {
                                    payload["violations"] = retryViolations.map(\.kind)
                                }
                            } else {
                                payload["outcome"] = "fellBack"
                                payload["failure"] = retry.failure ?? "unknown"
                                payload["firstBroke"] = violations.map(\.kind)
                            }
                        }
                    }
                } else {
                    let attempt = await fmRespond(session: session, prompt: entry.raw)
                    if let text = attempt.text {
                        payload["out"] = text
                    } else {
                        payload["failure"] = attempt.failure ?? "unknown"
                    }
                }

                payload["ms"] = Date().timeIntervalSince(started) * 1000
                if first { payload["firstCall"] = true; first = false }
                emit(payload)
            }
            emit(["summary": true, "warmupMs": warmup, "count": lines.count])
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }
}
