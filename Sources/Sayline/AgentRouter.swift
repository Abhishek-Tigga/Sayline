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
    private let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    private let model = "llama-3.3-70b-versatile"

    private let systemPrompt = """
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
    """

    private let tools: [[String: Any]] = [
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
        [
            "type": "function",
            "function": [
                "name": "open_system_setting",
                "description": "Opens a specific pane in macOS System Settings, e.g. Privacy & Security, Notifications, Wi-Fi.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "pane": [
                            "type": "string",
                            "enum": ["PrivacySecurity", "Notifications", "General", "Displays", "Sound", "Network", "Bluetooth", "WiFi", "Users"],
                            "description": "Which settings pane to open.",
                        ]
                    ],
                    "required": ["pane"],
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
                "description": "Turns Wi-Fi on or off.",
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

    func route(_ transcript: String) async throws -> [AgentAction] {
        guard let apiKey = APIKeyProvider.groqAPIKey else {
            throw TranscriptionError.missingAPIKey
        }

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": transcript],
            ],
            "tools": tools,
            "tool_choice": "auto",
            "temperature": 0.1,
        ]

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

        return toolCalls.compactMap(parseAction)
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
            let folderRaw = arguments["folder"] as? String
            let folder = AgentAction.SearchFolder(rawValue: folderRaw ?? "") ?? .downloads
            let subpath = arguments["subpath"] as? String
            return .findFile(query: query, folder: folder, subpath: subpath)
        case "open_folder":
            let folderRaw = arguments["folder"] as? String
            let folder = AgentAction.SearchFolder(rawValue: folderRaw ?? "") ?? .downloads
            let subpath = arguments["subpath"] as? String
            return .openFolder(folder, subpath: subpath)
        case "close_app":
            guard let appName = arguments["app_name"] as? String else { return nil }
            return .closeApp(name: appName)
        case "open_system_setting":
            guard let paneRaw = arguments["pane"] as? String,
                  let pane = AgentAction.SettingsPane(rawValue: paneRaw) else { return nil }
            return .openSystemSetting(pane)
        case "lock_screen":
            return .lockScreen
        case "set_volume":
            guard let changeRaw = arguments["change"] as? String,
                  let change = AgentAction.VolumeChange(rawValue: changeRaw) else { return nil }
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
            guard let queryRaw = arguments["query"] as? String,
                  let query = AgentAction.SystemQuery(rawValue: queryRaw) else { return nil }
            return .answerQuery(query)
        default:
            NSLog("Sayline: agent router returned unknown tool \(name)")
            return nil
        }
    }
}
