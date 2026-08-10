import Foundation

/// Local wall-clock timestamps, both directions.
///
/// Replaces ISO8601DateFormatter, which looks right for this and is not:
/// it requires seconds, so "2026-08-12T12:00" parses as nil. The tool
/// description hands the model an example without seconds, so every
/// explicit time was silently dropped and the user was asked for a time
/// they had already said. Parsing here accepts what the model actually
/// writes rather than what a strict reading of the spec demands.
///
/// No timezone suffix in either direction. The model is told the local
/// time and answers in the same shape, so nothing has to agree about
/// offsets — the one mistake most likely to put a reminder twelve hours
/// out without anyone noticing.
enum LocalTimestamp {
    /// Ordered most specific first; the first that parses wins.
    private static let patterns = [
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd",
    ]

    private static let formatters: [DateFormatter] = patterns.map { pattern in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX") // never the user's calendar
        f.timeZone = .current
        f.dateFormat = pattern
        return f
    }

    static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for formatter in formatters {
            if let date = formatter.date(from: trimmed) { return date }
        }
        // A model that volunteers an offset or a Z is still answering the
        // question; accept it rather than losing the time on a formality.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: trimmed)
    }

    /// What goes into the system prompt, and the shape the model copies.
    static func string(from date: Date) -> String {
        formatters[0].string(from: date)
    }
}
