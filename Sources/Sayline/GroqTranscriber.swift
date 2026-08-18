import Foundation

enum TranscriptionError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return APIKeyProvider.lastFailureWasUnreadable
                ? "Your Groq key can't be read after the last rebuild — re-enter it in Settings"
                : "No Groq API key set — add one in Settings"
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

    /// Confidence for the most recent transcription, for the choke-point
    /// guards. Same pattern as `AudioRecorder.lastRecordingPeak`: the
    /// caller that awaited `transcribe` reads it immediately after, on
    /// the same task — no concurrent holds exist, one hold at a time is
    /// the app's whole model.
    private(set) var lastStats: [WhisperHallucination.DecodeStats]?
    /// How many junk segments were cut from the last transcript. The
    /// caller surfaces this — a partial transcript must never be silent.
    private(set) var lastTrimmedSegments = 0

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

        // Segments are optional at every level, deliberately: if the API
        // stops sending them the transcript still flows and the guard
        // fails open — a missing number must never cost a dictation.
        struct Segment: Decodable {
            let text: String?
            let avg_logprob: Double?
            let no_speech_prob: Double?
            let compression_ratio: Double?
        }
        struct TranscriptionResponse: Decodable {
            let text: String
            let segments: [Segment]?
        }
        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)

        lastTrimmedSegments = 0
        let segments = decoded.segments ?? []
        let stats = segments.compactMap { s -> WhisperHallucination.DecodeStats? in
            guard let logprob = s.avg_logprob, let noSpeech = s.no_speech_prob,
                  let compression = s.compression_ratio else { return nil }
            return .init(avgLogprob: logprob, noSpeechProb: noSpeech,
                        compressionRatio: compression)
        }
        lastStats = stats.isEmpty ? nil : stats
        if let worst = stats.min(by: { $0.avgLogprob < $1.avgLogprob }) {
            SaylineLog.log(String(format:
                "[conf] %d segment(s), worst: logprob %.2f no_speech %.2f compression %.2f",
                stats.count, worst.avgLogprob, worst.noSpeechProb, worst.compressionRatio))
        } else {
            SaylineLog.log("[conf] no segment stats in response — confidence guard inactive this turn")
        }

        // Junk segments are cut, good ones kept — per-segment, because a
        // real 40 s dictation once carried one invented sentence at
        // logprob −3.91 and all-or-nothing let the good segments carry
        // the invention through. Partial beats poisoned: typing a
        // sentence the user never said is the worse failure, and the
        // caller shows a visible notice whenever this trims (never a
        // silent partial). All-junk is left intact for the caller's
        // whole-transcript discard, so "everything was noise" stays a
        // clean "didn't catch that" rather than an empty paste.
        if stats.count == segments.count, !stats.isEmpty,
           !WhisperHallucination.isLowConfidence(stats) {
            let kept = zip(segments, stats).filter { !$0.1.isJunk }
            if kept.count < segments.count {
                lastTrimmedSegments = segments.count - kept.count
                SaylineLog.log("[conf] cut \(lastTrimmedSegments) junk segment(s), kept \(kept.count) — the caller announces the trim")
                return kept.compactMap { $0.0.text }.joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
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
        // Segment confidence rides along — see the decode below. The
        // plain format returns text alone, which is how gibberish got
        // typed with the decoder's own doubts thrown away unread.
        appendField(name: "response_format", value: "verbose_json")
        // Pinned rather than left to auto-detect — Whisper models can
        // hallucinate garbled/wrong-language output specifically when
        // language auto-detection misfires on short or ambiguous audio.
        // Forcing English removes that failure mode outright, no
        // latency cost.
        appendField(name: "language", value: "en")
        // The vocabulary hint (DESIGN-vocabulary-biasing.md). Absent
        // entirely when there is nothing to send — fail open, never
        // block: a biasing failure must not cost a dictation.
        if let glossary = VocabularyBiasBuilder.currentGlossary {
            appendField(name: "prompt", value: glossary)
        }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        return body
    }
}
