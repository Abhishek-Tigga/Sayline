import Foundation

/// Where history lives in UserDefaults. Here rather than in AppDelegate
/// so `--dump-config` (which runs before any AppDelegate exists) reads
/// the same key the app writes — one truth, no string copy to drift.
enum HistoryStorage {
    static let defaultsKey = "com.abhishektigga.sayline.history"
}

struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let text: String
    let usedLocal: Bool
    /// Which mode produced this text — "clean", "work", "verbatim", or a
    /// work outcome like "work (retry rescued number)".
    ///
    /// Optional so entries written before work mode existed still decode;
    /// a non-optional field would have made every stored history
    /// unreadable on upgrade.
    let mode: String?
}
