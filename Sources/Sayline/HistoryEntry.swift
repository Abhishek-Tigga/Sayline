import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let text: String
    let style: DictationStyle
    let usedLocal: Bool
}
