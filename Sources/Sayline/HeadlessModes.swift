import Foundation
import AVFoundation

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
            // The contract: fast to start, and nearly all of the window
            // actually on disk.
            let ok = latency < 150 && onDisk > seconds * 0.8
            if !ok { failures += 1 }
            print(String(format: "hold %d: start %3.0f ms · on disk %.2fs of %.1fs · %d Hz %d ch · %d KB  %@",
                         hold, latency, onDisk, seconds,
                         Int(file.fileFormat.sampleRate), file.fileFormat.channelCount, kb,
                         ok ? "OK" : "<-- BREAKS THE CONTRACT"))
            recorder.discardRecording(at: url)
        }
        print(failures == 0 ? "PASS — every hold met the contract"
                            : "FAIL — \(failures) hold(s) broke the contract")
        exit(failures == 0 ? 0 : 1)
    }
}
