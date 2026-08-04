import Foundation

/// Runs a raw Whisper transcript through a fast Groq-hosted LLM to strip
/// filler words and fix grammar/punctuation before it gets inserted.
final class TranscriptCleaner {
    private let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    private let model = "llama-3.1-8b-instant"

    /// Combines the fidelity style (Verbatim/Clean/Concise) with the
    /// tone context (Email/Chat/Code/General) detected from the focused
    /// app. Code context always forces verbatim regardless of the chosen
    /// style — rewriting text dictated into a code editor or terminal
    /// risks silently corrupting something precise (a variable name, an
    /// exact string), which is a correctness risk worth being
    /// conservative about, not a stylistic choice to leave to the user.
    func clean(_ rawText: String, style: DictationStyle, context: AppContext) async throws -> String {
        if context == .code {
            return rawText
        }

        guard let basePrompt = style.systemPrompt else {
            return rawText // Verbatim style, skip LLM
        }
        let systemPrompt = context.promptFragment.map { "\(basePrompt)\n\n\($0)" } ?? basePrompt

        guard let apiKey = APIKeyProvider.groqAPIKey else {
            throw TranscriptionError.missingAPIKey
        }

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": rawText]
            ],
            "temperature": 0.2
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

        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw TranscriptionError.invalidResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
