import Foundation

/// Routes an agent-mode transcript to one of AgentAction's small, explicit
/// set of actions using LLM tool-calling — the model picks exactly one
/// defined action with structured parameters, rather than either rigid
/// string matching or open-ended free-form interpretation.
///
/// Deliberately does NOT force a tool choice (tool_choice: "auto", not
/// "required"): if the request is out of scope for what's built so far
/// (email, calendar — real, planned, just not yet), the model can decline
/// by replying with no tool call, and we fail safe by doing nothing
/// rather than forcing a bad match into open_app or find_file.
final class AgentRouter {
    enum Provider {
        case groq
        case openAI

        var endpoint: URL {
            switch self {
            case .groq: return URL(string: "https://api.groq.com/openai/v1/chat/completions")!
            case .openAI: return URL(string: "https://api.openai.com/v1/chat/completions")!
            }
        }

        var model: String {
            switch self {
            case .groq: return "llama-3.3-70b-versatile"
            case .openAI: return "gpt-4o-mini"
            }
        }

        var apiKey: String? {
            switch self {
            case .groq: return APIKeyProvider.groqAPIKey
            case .openAI: return APIKeyProvider.openAIAPIKey
            }
        }
    }

    /// **Temporary, and not a product decision.** Switched to OpenAI on
    /// 2026-08-09 purely to stop losing development time: Groq's free tier
    /// caps the 70B router at 100K tokens/day, which normal testing
    /// exhausted three days running, blocking both live verification and
    /// the eval baseline itself.
    ///
    /// The provider comparison is still open and still governed by the
    /// agreed pass bar in BACKLOG.md — accuracy ≥ baseline, 0% syntax
    /// failures, tokens under ~1,800. What is measured so far:
    /// `gpt-4o-mini` scores 28/30 with 0% syntax failures at ~1,518 tokens
    /// and ~966 ms (`eval/results.md`), while Groq has never completed a
    /// scored run. Do not read that as Groq losing — it has never been
    /// measured. Moving day-to-day traffic off Groq is also what finally
    /// frees its daily budget for that baseline run.
    ///
    /// Flip this back to `.groq` to compare, or once a backend proxy makes
    /// rate limits somebody else's problem.
    private let provider: Provider = .openAI

    private var endpoint: URL { provider.endpoint }
    private var model: String { provider.model }

    /// Internal rather than private so `eval/run_eval.py` can read the
    /// real prompt instead of keeping its own copy — a duplicated prompt
    /// would drift from this one and quietly make every eval number a
    /// measurement of the wrong thing.
    let systemPrompt = """
    You route spoken requests to macOS automation actions, or answer \
    factual questions about the Mac's current state. The user is either \
    issuing a command ("open Safari") or asking a question ("what's my \
    battery at") — never dictating text to be typed. Pick the best \
    matching tool(s) and fill in their parameters based on what they \
    said — if the request names more than one distinct action or \
    question (e.g. "open Safari, then what's my battery"), call each \
    tool needed, one per item, in the order they were said. If the \
    request doesn't clearly match any available tool (for example it's \
    about email, calendar, or anything else not covered), do not call \
    any tool for that part — just reply normally.

    General rule for "<X> settings" phrasing: default to \
    open_system_setting (a real pane inside the System Settings app), \
    not to opening a standalone app, whenever a matching pane exists — \
    even if an app with a related name/purpose also exists. Only route \
    to open_app instead when the user explicitly names the app itself \
    (e.g. "open the Passwords app", "open Passwords") rather than \
    "settings". Concretely: "password settings" / "Touch ID and \
    password settings" -> open_system_setting with pane \
    "Touch ID & Password", NOT open_app("Passwords") — confirmed \
    directly by the user, do not second-guess this one.

    That rule is about naming a *specific* pane. If the user just says \
    "open settings" / "open system settings" without naming one, they \
    want the app itself — use open_app with "System Settings", not \
    open_system_setting.

    open_system_setting's pane parameter is free text, not a fixed \
    enum in the tool schema — pick the closest real match from this \
    list of every settings pane actually installed on this Mac, even \
    if the user's phrasing isn't an exact match (e.g. "change my \
    wallpaper" -> "Wallpaper", "trackpad settings" -> "Trackpad"): \
    \(SettingsPaneCatalog.panes.map { $0.displayName }.joined(separator: ", ")).
    """

    /// Internal for the same reason as `systemPrompt` above — the eval
    /// harness derives all three arms' request payloads from this array.
    let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "open_app",
                "description": "Opens/launches a macOS application by name.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "app_name": [
                            "type": "string",
                            "description": "The application name, e.g. 'Finder', 'Safari', 'Mail'.",
                        ]
                    ],
                    "required": ["app_name"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "find_file",
                "description": "Searches for a specific file by name in a folder and reveals it in Finder. Use this only when the user names a particular file (or file-ish query like 'resume' or 'invoice PDF') — not for just browsing a folder in general.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Filename or partial filename to search for, e.g. 'resume'.",
                        ],
                        "folder": [
                            "type": "string",
                            "enum": ["Downloads", "Documents", "Desktop", "Home"],
                            "description": "Which top-level folder to search. Default to Downloads if unclear.",
                        ],
                        "subpath": [
                            "type": "string",
                            "description": "Optional nested subfolder path inside `folder` to narrow the search, one or two levels deep, e.g. 'Codex' or 'Projects/Codex'. Leave unset to search the whole top-level folder.",
                        ],
                    ],
                    "required": ["query"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "open_folder",
                "description": "Opens a specific folder directly in Finder, when the user just wants to browse/view the folder itself rather than find a particular file in it (e.g. 'open my Downloads folder', 'show me Documents', 'open the Codex folder inside Documents').",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "folder": [
                            "type": "string",
                            "enum": ["Downloads", "Documents", "Desktop", "Home"],
                            "description": "Which top-level folder to open, or the top-level folder that contains the target if it's a subfolder.",
                        ],
                        "subpath": [
                            "type": "string",
                            "description": "Optional nested subfolder path inside `folder`, one or two levels deep, e.g. 'Codex' or 'Projects/Codex'. Leave unset if the target is `folder` itself.",
                        ],
                    ],
                    "required": ["folder"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "close_app",
                "description": "Quits/closes a currently running macOS application by name (a normal quit, like Cmd+Q — not a force kill).",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "app_name": [
                            "type": "string",
                            "description": "The application name to close, e.g. 'Calendar', 'Notes'.",
                        ]
                    ],
                    "required": ["app_name"],
                ],
            ],
        ],
        // pane is deliberately plain "type": "string" here, not an "enum"
        // — putting the 49-entry SettingsPaneCatalog list directly into
        // the JSON schema (as it was 2026-08-08) reliably caused Groq's
        // llama-3.3-70b-versatile to emit malformed tool-call syntax
        // specifically for settings requests (confirmed live via a
        // stderr-captured log: `<function=open_app{...}` — missing the
        // closing `>` — which Groq's parser then rejected outright with
        // HTTP 400 "tool_use_failed" before the request ever reached our
        // code). The pane vocabulary now lives as a prose list in
        // systemPrompt instead, which the model handles more reliably;
        // SettingsPaneCatalog.bundleID(forPaneName:) still fuzzy-matches
        // whatever string comes back.
        [
            "type": "function",
            "function": [
                "name": "open_system_setting",
                "description": "Opens/shows a specific pane in the System Settings app so the user can look at or change something themselves — for VIEWING a pane, not for directly changing a value. For \"open Wi-Fi settings\" or \"show Wi-Fi settings\" (they want to see the pane), use this with pane \"Wi-Fi\". For \"turn Wi-Fi on/off\" (they want the actual change made now, no pane needs to open), use set_wifi instead, not this. \"password settings\" / \"Touch ID and password settings\" -> pane \"Touch ID & Password\" (this is the correct target, not the standalone Passwords app).",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "pane": [
                            "type": "string",
                            "description": "Which settings pane to open — see the pane list in the system prompt and pick the closest real match. Not a fixed enum here; free text is fine.",
                        ]
                    ],
                    "required": ["pane"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "open_website",
                "description": "Opens a website in the browser, optionally at its search results. Use for \"open youtube\", \"open toolfolio.com\", \"search kendrick lamar on youtube\", \"look up John Smith on LinkedIn\", \"google swift concurrency\". Put ONLY the site in `site` and ONLY the thing being searched for in `query` — for \"search lo-fi music on youtube\", site is \"YouTube\" and query is \"lo-fi music\". If the user names a site not in the list below, pass exactly what they said and it will be handled. Note \"play <song> on youtube\" is also this tool: it opens the search results, which is as far as a link can go.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "site": [
                            "type": "string",
                            "description": "The website. Known ones: \(WebsiteCatalog.promptVocabulary.joined(separator: ", ")). If the user said a full address like \"toolfolio.com\", pass that instead.",
                        ],
                        "query": [
                            "type": "string",
                            "description": "What to search for on that site. Omit when the user just wants the site opened.",
                        ],
                        "play": [
                            "type": "boolean",
                            "description": "True only when the user said \"play\" rather than \"open\", \"search\" or \"find\" — e.g. \"play a Kendrick Lamar song on YouTube\". Currently honoured for YouTube only, where it opens the top result directly so it starts playing instead of showing a list.",
                        ],
                    ],
                    "required": ["site"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "lock_screen",
                "description": "Locks the Mac's screen immediately.",
                "parameters": ["type": "object", "properties": [:] as [String: Any]],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "set_volume",
                "description": "Mutes, unmutes, or nudges the system output volume up or down by a fixed step.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "change": [
                            "type": "string",
                            "enum": ["Mute", "Unmute", "Up", "Down"],
                            "description": "Which volume change to make.",
                        ]
                    ],
                    "required": ["change"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "set_wifi",
                "description": "Directly turns Wi-Fi on or off right now — only when the user states which (\"turn Wi-Fi on\", \"turn off Wi-Fi\"). If they just want to see/open the Wi-Fi settings pane (\"open Wi-Fi settings\") without saying on or off, use open_system_setting with pane WiFi instead — do not guess a direction here.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "enabled": [
                            "type": "boolean",
                            "description": "true to turn Wi-Fi on, false to turn it off.",
                        ]
                    ],
                    "required": ["enabled"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "set_dark_mode",
                "description": "Switches the system appearance between Dark Mode and Light Mode.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "enabled": [
                            "type": "boolean",
                            "description": "true for Dark Mode, false for Light Mode.",
                        ]
                    ],
                    "required": ["enabled"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "empty_trash",
                "description": "Empties the Trash, permanently deleting everything in it.",
                "parameters": ["type": "object", "properties": [:] as [String: Any]],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "take_screenshot",
                "description": "Takes a full-screen screenshot and saves it to the Desktop.",
                "parameters": ["type": "object", "properties": [:] as [String: Any]],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "answer_system_query",
                "description": "Answers a factual question about the Mac's current state — battery, storage space, memory usage, uptime, volume level, macOS version, or what's currently playing. Use this when the user is ASKING something, not asking for an action to be performed.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "enum": ["Battery", "Storage", "Memory", "Uptime", "VolumeLevel", "MacOSVersion", "NowPlaying"],
                            "description": "Which fact to look up.",
                        ]
                    ],
                    "required": ["query"],
                ],
            ],
        ],
    ]

    /// Groq occasionally emits malformed tool-call syntax (a stochastic
    /// generation slip, not something our request caused) and rejects its
    /// own output with HTTP 400 "tool_use_failed" before anything reaches
    /// us. One silent retry absorbs that — confirmed live (2026-08-08)
    /// that the identical request succeeds on a second attempt.
    private struct RetryableToolFailure: Error {
        let message: String
    }

    func route(_ transcript: String) async throws -> [AgentAction] {
        let actions = try await routeWithRetry(transcript)
        return await resolvePlayback(actions)
    }

    /// Turns any `.playOnYouTube` into a real `/watch` URL, which
    /// autoplays. Done here rather than in the executor because it needs a
    /// network call and `AgentExecutor.execute` is synchronous — and here
    /// the call sits inside the routing wait the user is already expecting,
    /// rather than adding a second visible pause.
    private func resolvePlayback(_ actions: [AgentAction]) async -> [AgentAction] {
        var resolved: [AgentAction] = []
        for action in actions {
            guard case .playOnYouTube(let query) = action else {
                resolved.append(action)
                continue
            }
            if let url = await YouTubeSearch.topVideoURL(for: query) {
                resolved.append(.openWebsite(label: "YouTube — \(query)", url: url))
            } else if case .site(let label, let url) = WebsiteCatalog.resolve("YouTube", query: query) {
                // Key missing, quota gone or network flaky — the search page
                // is exactly what this did before, so degrade to that.
                NSLog("Sayline: couldn't resolve a video, opening YouTube search for \"\(query)\" instead")
                resolved.append(.openWebsite(label: label, url: url))
            }
        }
        return resolved
    }

    private func routeWithRetry(_ transcript: String) async throws -> [AgentAction] {
        do {
            return try await performRoute(transcript, temperature: 0.1)
        } catch let failure as RetryableToolFailure {
            // Retry at a higher temperature, NOT the same 0.1. The first
            // version of this retried identically and was useless:
            // confirmed live (2026-08-09, "Show my screen time") that the
            // retry reproduced a byte-identical malformed generation,
            // because at 0.1 the model is near-deterministic — same input,
            // same broken output. Sampling differently is the whole point.
            NSLog("Sayline: agent router tool call malformed, retrying at higher temperature -> \(failure.message)")
            do {
                return try await performRoute(transcript, temperature: 0.6)
            } catch let secondFailure as RetryableToolFailure {
                throw TranscriptionError.apiError(secondFailure.message)
            }
        }
    }

    /// OpenAI's strict mode is the whole reason arm C measured 0% syntax
    /// failures: the schema is enforced *during* generation rather than
    /// parsed afterwards, so a malformed tool call becomes structurally
    /// impossible instead of merely less likely. It requires every property
    /// listed in `required` plus `additionalProperties: false`, so
    /// genuinely optional parameters (`subpath`, `folder`) become nullable
    /// rather than absent. Mirrors `openai_strict_tools()` in
    /// `eval/run_eval.py` — if you change one, change both, or the eval
    /// stops describing production.
    static func strictTools(_ tools: [[String: Any]]) -> [[String: Any]] {
        tools.map { tool in
            guard var function = tool["function"] as? [String: Any] else { return tool }
            let parameters = function["parameters"] as? [String: Any] ?? [:]
            let properties = parameters["properties"] as? [String: [String: Any]] ?? [:]
            let originallyRequired = Set(parameters["required"] as? [String] ?? [])

            var strictProperties: [String: Any] = [:]
            for (name, spec) in properties {
                var spec = spec
                if !originallyRequired.contains(name) {
                    let base = (spec["type"] as? String) ?? "string"
                    spec["type"] = [base, "null"]
                }
                strictProperties[name] = spec
            }

            function["strict"] = true
            function["parameters"] = [
                "type": "object",
                "properties": strictProperties,
                // Sorted, not raw dictionary order, which Swift does not
                // guarantee between runs. JSON Schema ignores the order of
                // `required`, but a payload that differs run to run defeats
                // provider-side prompt caching and makes captured requests
                // impossible to diff.
                "required": properties.keys.sorted(),
                "additionalProperties": false,
            ] as [String: Any]
            return ["type": "function", "function": function]
        }
    }

    private func performRoute(_ transcript: String, temperature: Double) async throws -> [AgentAction] {
        guard let apiKey = provider.apiKey else {
            throw TranscriptionError.missingAPIKey
        }

        var payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": transcript],
            ],
            "tools": provider == .openAI ? Self.strictTools(tools) : tools,
            "tool_choice": "auto",
        ]
        // Deliberately omitted on OpenAI so production sends exactly what
        // eval/run_eval.py's arm C sent — a config that measured 0% syntax
        // failures is only meaningful if production reproduces it. The
        // temperature knob exists for the malformed-call retry, which
        // strict mode makes unnecessary anyway.
        if provider == .groq {
            payload["temperature"] = temperature
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            if message.contains("tool_use_failed") {
                throw RetryableToolFailure(message: message)
            }
            throw TranscriptionError.apiError(message)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw TranscriptionError.invalidResponse
        }

        guard let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty else {
            NSLog("Sayline: agent router did not match a known action")
            return []
        }

        return correctedSettingsPane(toolCalls.compactMap(parseAction), transcript: transcript)
    }

    /// Deterministic correction for "<X> settings" where X names a real
    /// pane but the model opened the Settings app instead of that pane.
    ///
    /// Measured 2026-08-09 via `eval/`: four of five OpenAI models routed
    /// "open general settings" to `open_app("System Settings")`. It's an
    /// understandable reading — "general" sounds like a hedge rather than
    /// a pane name — but it loses the user's actual target, and prompt
    /// wording did not fix it (two attempts, both measured, both
    /// reverted). The catalog already knows where these go, so the
    /// mapping is enforced here rather than left to model compliance.
    ///
    /// Deliberately narrow: it only fires when the model produced exactly
    /// one action *and* that action was "open the Settings app" or the
    /// no-match fallback — i.e. only when the model already signalled it
    /// couldn't place the request. A model that confidently picked the
    /// wrong pane is left alone, since overriding that would be guessing
    /// against a real decision rather than filling a gap.
    private func correctedSettingsPane(_ actions: [AgentAction], transcript: String) -> [AgentAction] {
        guard actions.count == 1 else { return actions }

        let modelPunted: Bool
        if case .openApp(let name) = actions[0], SettingsPaneCatalog.meansSystemSettingsApp(name) {
            modelPunted = true
        } else if case .openSystemSettingsFallback = actions[0] {
            modelPunted = true
        } else {
            modelPunted = false
        }

        guard modelPunted,
              let phrase = Self.panePhrase(in: transcript),
              let bundleID = SettingsPaneCatalog.bundleID(forPaneName: phrase) else {
            return actions
        }

        NSLog("Sayline: transcript said \"\(phrase) settings\" but the model opened System Settings itself — routing to the \(phrase) pane instead")
        return [.openSystemSetting(paneName: phrase, bundleID: bundleID)]
    }

    /// The words sitting between a lead-in ("open", "show", "my", …) and
    /// the word "settings" — "open general settings." yields "general",
    /// "open touch id and password settings" yields the whole phrase.
    /// Returns nil when nothing meaningful precedes it, which is exactly
    /// the "open settings" / "open system settings" case that legitimately
    /// means the app and must not be corrected.
    /// Internal so `eval/run_eval.py` can apply the same correction the app
    /// applies — otherwise the eval scores wire-level model output and
    /// reports failures production no longer has.
    static func panePhrase(in transcript: String) -> String? {
        let words = transcript.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard let settingsIndex = words.lastIndex(where: { $0 == "settings" || $0 == "setting" }) else {
            return nil
        }
        let leadIns: Set<String> = ["open", "show", "launch", "go", "to", "the", "my", "me", "system", "in", "into", "up", "bring"]
        var start = settingsIndex
        while start > 0, !leadIns.contains(words[start - 1]) {
            start -= 1
        }
        guard start < settingsIndex else { return nil }
        return words[start..<settingsIndex].joined(separator: " ")
    }

    private func parseAction(from toolCall: [String: Any]) -> AgentAction? {
        guard let function = toolCall["function"] as? [String: Any],
              let name = function["name"] as? String,
              let argumentsString = function["arguments"] as? String,
              let argumentsData = argumentsString.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any] else {
            return nil
        }

        switch name {
        case "open_app":
            guard let appName = arguments["app_name"] as? String else { return nil }
            return .openApp(name: appName)
        case "find_file":
            guard let query = arguments["query"] as? String else { return nil }
            let folder = Self.fuzzyMatch(arguments["folder"] as? String, as: AgentAction.SearchFolder.self) ?? .downloads
            let subpath = arguments["subpath"] as? String
            return .findFile(query: query, folder: folder, subpath: subpath)
        case "open_folder":
            let folder = Self.fuzzyMatch(arguments["folder"] as? String, as: AgentAction.SearchFolder.self) ?? .downloads
            let subpath = arguments["subpath"] as? String
            return .openFolder(folder, subpath: subpath)
        case "close_app":
            guard let appName = arguments["app_name"] as? String else { return nil }
            return .closeApp(name: appName)
        case "open_system_setting":
            guard let paneRaw = arguments["pane"] as? String else { return nil }
            if let bundleID = SettingsPaneCatalog.bundleID(forPaneName: paneRaw) {
                return .openSystemSetting(paneName: paneRaw, bundleID: bundleID)
            }
            // "open settings" with no pane named wants the app, not a pane.
            // Handled deterministically here rather than trusting the
            // prompt to always steer the model to open_app, since it
            // demonstrably doesn't.
            if SettingsPaneCatalog.meansSystemSettingsApp(paneRaw) {
                NSLog("Sayline: agent router read pane \"\(paneRaw)\" as the System Settings app itself — opening the app")
                return .openApp(name: "System Settings")
            }
            // Doesn't match anything in the live catalog even after fuzzy
            // normalization — fail visibly (open System Settings + flash
            // a specific message in AppDelegate) rather than silently
            // dropping the action, per the "fail visibly" principle the
            // dynamic catalog was built around.
            NSLog("Sayline: agent router returned unmatched settings pane \"\(paneRaw)\" — no catalog match")
            return .openSystemSettingsFallback(requestedPaneName: paneRaw)
        case "open_website":
            guard let site = arguments["site"] as? String else { return nil }
            let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let wantsPlayback = (arguments["play"] as? Bool) ?? false
            if wantsPlayback, let query, !query.isEmpty,
               WebsiteCatalog.isYouTube(site) {
                return .playOnYouTube(query: query)
            }
            switch WebsiteCatalog.resolve(site, query: query?.isEmpty == true ? nil : query) {
            case .site(let label, let url):
                return .openWebsite(label: query.map { "\(label) — \($0)" } ?? label, url: url)
            case .explicitDomain(let url):
                return .openWebsite(label: url.host ?? site, url: url)
            case .unknown(let requested):
                return .unknownWebsite(requested: requested)
            }
        case "lock_screen":
            return .lockScreen
        case "set_volume":
            let changeRaw = arguments["change"] as? String
            guard let change = Self.fuzzyMatch(changeRaw, as: AgentAction.VolumeChange.self) else {
                NSLog("Sayline: agent router returned unmatched volume change \(changeRaw ?? "nil")")
                return nil
            }
            return .setVolume(change)
        case "set_wifi":
            guard let enabled = arguments["enabled"] as? Bool else { return nil }
            return .setWiFi(enabled: enabled)
        case "set_dark_mode":
            guard let enabled = arguments["enabled"] as? Bool else { return nil }
            return .setDarkMode(enabled: enabled)
        case "empty_trash":
            return .emptyTrash
        case "take_screenshot":
            return .takeScreenshot
        case "answer_system_query":
            let queryRaw = arguments["query"] as? String
            guard let query = Self.fuzzyMatch(queryRaw, as: AgentAction.SystemQuery.self) else {
                NSLog("Sayline: agent router returned unmatched system query \(queryRaw ?? "nil")")
                return nil
            }
            return .answerQuery(query)
        default:
            NSLog("Sayline: agent router returned unknown tool \(name)")
            return nil
        }
    }

    /// Groq's tool-calling doesn't always return an enum parameter in
    /// the exact literal form given in the schema (e.g. "Privacy &
    /// Security" or "privacy security" instead of the schema's exact
    /// "PrivacySecurity") — a strict `RawValue` match against that would
    /// silently fail with no error anywhere, which is exactly what was
    /// happening for "open privacy settings" (traced live: the real
    /// system identifier and URL scheme both work fine in isolation —
    /// the break was here, the model's returned string just not being a
    /// byte-for-byte match). Matches case/space/punctuation-insensitively
    /// against every case's raw value instead of requiring an exact hit.
    private static func fuzzyMatch<T: RawRepresentable & CaseIterable>(
        _ raw: String?, as type: T.Type
    ) -> T? where T.RawValue == String {
        guard let raw else { return nil }
        let normalized = normalize(raw)
        return T.allCases.first { normalize($0.rawValue) == normalized }
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
