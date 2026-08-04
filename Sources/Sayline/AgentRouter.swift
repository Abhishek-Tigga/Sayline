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
    You route spoken requests to macOS automation actions. The user is \
    speaking a command, not dictating text to be typed. Pick the single \
    best matching tool and fill in its parameters based on what they \
    said. If the request doesn't clearly match any available tool (for \
    example it's about email, calendar, or anything else not covered), \
    do not call any tool — just reply normally.
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
                "description": "Searches for a file by name in a specific folder and reveals it in Finder.",
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
                            "description": "Which folder to search. Default to Downloads if unclear.",
                        ],
                    ],
                    "required": ["query"],
                ],
            ],
        ],
    ]

    func route(_ transcript: String) async throws -> AgentAction? {
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

        guard let toolCalls = message["tool_calls"] as? [[String: Any]],
              let toolCall = toolCalls.first,
              let function = toolCall["function"] as? [String: Any],
              let name = function["name"] as? String,
              let argumentsString = function["arguments"] as? String,
              let argumentsData = argumentsString.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: argumentsData) as? [String: Any] else {
            NSLog("Sayline: agent router did not match a known action")
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
            return .findFile(query: query, folder: folder)
        default:
            NSLog("Sayline: agent router returned unknown tool \(name)")
            return nil
        }
    }
}
