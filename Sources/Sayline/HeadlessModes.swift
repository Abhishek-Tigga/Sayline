import Foundation

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
