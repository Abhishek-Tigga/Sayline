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

extension LocalTimestamp {
    /// Rejects a due date that cannot be what the user meant.
    ///
    /// Three ways it can be wrong. A time already gone, or a year that is
    /// a transcription artefact — both obvious.
    ///
    /// The third took two failed prompt rewrites to accept. Asked to remind
    /// someone "tomorrow", with no hour said, the model answers with
    /// tomorrow *at the current time of day*: a reminder spoken at 4:36am
    /// came back set for 4:36am the next morning, an hour nobody chose and
    /// would sleep through. The tool description now says plainly that a
    /// bare day is not a time, and the model still does it. That is the
    /// house rule in CLAUDE.md arriving on schedule — deterministic rules
    /// beat prompt engineering, so this is a rule.
    ///
    /// The signature is unmistakable: a due date on a later day whose clock
    /// time matches right now. Dropping it sends the request to the
    /// follow-up question, which is what should have happened.
    ///
    /// Costs a question to anyone who genuinely wants tomorrow at this
    /// exact minute. A rare sentence, and a cheap price.
    ///
    /// Lives here rather than in AgentRouter so it can be tested without
    /// compiling the site and settings catalogs — the router eval scores
    /// what the model emits and structurally cannot see this rule at all.
    /// `now` is injectable for the same reason: a test that depends on the
    /// wall clock is a test that fails at midnight.
    static func plausibleDueDate(_ date: Date, now: Date = Date()) -> Date? {
        let ahead = date.timeIntervalSince(now)
        guard ahead > -60, ahead < 366 * 24 * 3600 else { return nil }

        let calendar = Calendar.current
        guard !calendar.isDate(date, inSameDayAs: now) else { return date }

        let due = calendar.dateComponents([.hour, .minute], from: date)
        let current = calendar.dateComponents([.hour, .minute], from: now)
        if due.hour == current.hour,
           let a = due.minute, let b = current.minute, abs(a - b) <= 2 {
            return nil
        }
        return date
    }
}

extension LocalTimestamp {
    /// Did the speaker actually name a time of day?
    ///
    /// The question the timestamp cannot answer. Asked to remind someone
    /// "tomorrow", the model first answered with tomorrow at the current
    /// time of day; told that a bare day is not a time and that morning
    /// means 09:00, it answered with tomorrow at 09:00 instead. Both are
    /// invented, and the second is indistinguishable from a genuine
    /// "tomorrow morning" by looking at the timestamp — which is why two
    /// prompt rewrites and a clock-comparison rule all failed.
    ///
    /// The evidence lives in the sentence, and we have the sentence. If
    /// nothing in it names an hour or a part of the day, any time the model
    /// supplies is its own invention and the app should ask instead.
    ///
    /// Errs toward believing a time was said: a false positive keeps the
    /// model's answer, which is the behaviour we already had, while a false
    /// negative costs one unnecessary question.
    static func namesATimeOfDay(_ transcript: String) -> Bool {
        let text = transcript.lowercased()

        // "at 4", "4pm", "4:30", "16:00", "half past four"
        let patterns = [
            #"\b\d{1,2}\s*[:.]\s*\d{2}\b"#,
            #"\b\d{1,2}\s*(am|pm|a\.m|p\.m)\b"#,
            #"\bat\s+\d{1,2}\b"#,
            #"\bin\s+(a|an|\d+)\s+(minute|minutes|hour|hours|min|mins)\b"#,
            #"\b(half|quarter)\s+(past|to)\b"#,
            #"\d{1,2}\s*o'?clock\b"#,
        ]
        for pattern in patterns where text.range(of: pattern, options: .regularExpression) != nil {
            return true
        }

        let words: Set<String> = [
            "morning", "afternoon", "evening", "night", "tonight", "noon",
            "midday", "midnight", "lunchtime", "breakfast", "dinner",
            "dawn", "dusk", "sunrise", "sunset", "now", "shortly", "soon",
            "later", "o'clock", "oclock",
        ]
        let spoken = Set(text.split(whereSeparator: { !$0.isLetter }).map(String.init))
        return !spoken.isDisjoint(with: words)
    }
}
