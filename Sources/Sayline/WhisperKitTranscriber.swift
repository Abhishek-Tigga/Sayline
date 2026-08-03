import Foundation
import WhisperKit

/// On-device transcription via WhisperKit (Argmax) — runs entirely locally
/// on Apple Silicon (CoreML/Neural Engine/Metal), no network call, no
/// per-use cost. The model downloads once (via `preload()`, kicked off as
/// soon as the user opts into local transcription rather than lazily on
/// first dictation) and is cached locally after that.
final class WhisperKitTranscriber: Transcriber {
    /// Uses the compressed large-v3 variant — Argmax's own docs list this
    /// as their maximum-accuracy recommendation, at roughly half the
    /// download size of the uncompressed turbo variant WhisperKit's
    /// default device-based selection picked for us.
    private static let modelName = "large-v3-v20240930_626MB"

    /// Guards against overlapping `WhisperKit()` initializations — if
    /// preload and a dictation both trigger loading around the same time,
    /// every caller awaits this same in-flight task instead of each
    /// starting its own concurrent load (which corrupts the on-disk model
    /// cache when two downloads race to write the same file).
    private var loadTask: Task<WhisperKit, Error>?
    private(set) var isReady = false

    /// Starts loading (and downloading, if needed) the model without
    /// transcribing anything. Safe to call redundantly.
    func preload() async {
        _ = try? await loadPipe()
    }

    func transcribe(fileURL: URL) async throws -> String {
        let pipe = try await loadPipe()
        let results = try await pipe.transcribe(audioPath: fileURL.path)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadPipe() async throws -> WhisperKit {
        if let loadTask {
            return try await loadTask.value
        }

        let task = Task<WhisperKit, Error> {
            NSLog("Sayline: loading local WhisperKit model (\(Self.modelName)) — first run downloads it…")
            let pipe = try await WhisperKit(WhisperKitConfig(model: Self.modelName))
            NSLog("Sayline: local WhisperKit model ready")
            return pipe
        }
        loadTask = task

        do {
            let pipe = try await task.value
            isReady = true
            return pipe
        } catch {
            loadTask = nil // allow retry on the next call instead of caching a permanent failure
            throw error
        }
    }
}
