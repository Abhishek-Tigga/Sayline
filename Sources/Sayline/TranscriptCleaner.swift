import Foundation

/// Runs a raw Whisper transcript through a fast Groq-hosted LLM to strip
/// filler words and fix grammar/punctuation before it gets inserted.
final class TranscriptCleaner {
    private let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    private let model = "llama-3.1-8b-instant"

    private let systemPrompt = """
    You clean up raw speech-to-text transcripts for dictation. Remove filler \
    words (um, uh, like, you know), fix grammar, punctuation, and \
    capitalization, and remove false starts or repeated words. Preserve the \
    speaker's meaning, tone, and intent exactly — do not add information, do \
    not answer questions, do not add commentary. Output ONLY the cleaned \
    text, nothing else.
    """

    func clean(_ rawText: String) async throws -> String {
        guard let apiKey = ProcessInfo.processInfo.environment["GROQ_API_KEY"], !apiKey.isEmpty else {
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
