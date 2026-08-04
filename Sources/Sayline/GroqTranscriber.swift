import Foundation

enum TranscriptionError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Groq API key set — add one in Settings"
        case .invalidResponse:
            return "Unexpected response from Groq"
        case .apiError(let message):
            return message
        }
    }
}

/// Sends recorded audio to Groq's OpenAI-compatible Whisper endpoint and
/// returns the transcript text.
final class GroqTranscriber: Transcriber {
    private let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    private let model = "whisper-large-v3-turbo"

    func transcribe(fileURL: URL) async throws -> String {
        guard let apiKey = APIKeyProvider.groqAPIKey else {
            throw TranscriptionError.missingAPIKey
        }

        let audioData = try Data(contentsOf: fileURL)
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = makeBody(audioData: audioData, filename: fileURL.lastPathComponent, boundary: boundary)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw TranscriptionError.apiError(message)
        }

        struct TranscriptionResponse: Decodable { let text: String }
        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeBody(audioData: Data, filename: String, boundary: String) -> Data {
        var body = Data()

        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendField(name: "model", value: model)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        return body
    }
}
