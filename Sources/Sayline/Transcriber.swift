import Foundation

/// Common interface for anything that can turn a recorded audio file into
/// text, so AppDelegate can swap between cloud (Groq) and on-device
/// (WhisperKit) transcription without caring which one it's talking to.
protocol Transcriber {
    func transcribe(fileURL: URL) async throws -> String
}
