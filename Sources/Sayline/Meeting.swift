import Foundation

/// A calendar event, reduced to what joining one needs.
///
/// Deliberately not an `EKEvent`. Everything downstream of `MeetingStore`
/// works on this, which is what lets the logic that decides *which meeting
/// the user joins* live in a file with no framework imports and therefore
/// a check suite — see `eval/meeting-checks`.
struct Meeting: Equatable {
    let title: String
    let start: Date
    let end: Date
    /// Extracted once, when the event was mapped. Nil means this event is
    /// real but not joinable — a focus block, a birthday, a room booking.
    let joinURL: URL?
    let isAccepted: Bool

    /// What the pill says. An event with no title is a real thing that
    /// exists on real calendars, and "Joining" followed by nothing reads
    /// as a bug.
    var spokenName: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled meeting" : trimmed
    }
}

/// Which meeting "next" means.
///
/// Pure, with `now` passed in rather than read from the clock. Same reason
/// as `LocalTimestamp.plausibleDueDate`: a test that depends on the wall
/// clock is a test that fails at midnight, and this decides which meeting
/// someone is dropped into.
enum MeetingSelection {
    /// The design's window: running right now, or starting within the next
    /// 30 minutes. Wide enough to work when you are ten minutes late,
    /// narrow enough not to join tomorrow's standup this afternoon.
    static let defaultWindow: TimeInterval = 30 * 60

    /// The meeting to join: soonest start wins, ties break toward the one
    /// you accepted.
    ///
    /// Only considers events with a join link, because an event without one
    /// cannot be joined by definition — that is the design's
    /// no-configuration filter, and it is why a holiday or a focus block
    /// never wins.
    static func nextJoinable(from meetings: [Meeting],
                             now: Date,
                             window: TimeInterval = defaultWindow) -> Meeting? {
        best(from: meetings.filter { $0.joinURL != nil }, now: now, window: window)
    }

    /// The next event in the window whether or not it can be joined.
    ///
    /// "What's my next meeting" answers about the calendar, not about what
    /// happens to be joinable — replying "no meetings" when a meeting is
    /// plainly there, merely linkless, would be false. The caller says so:
    /// "Next: Design review at 3:00 — no join link."
    static func next(from meetings: [Meeting],
                     now: Date,
                     window: TimeInterval = defaultWindow) -> Meeting? {
        best(from: meetings, now: now, window: window)
    }

    private static func best(from meetings: [Meeting],
                             now: Date,
                             window: TimeInterval) -> Meeting? {
        let horizon = now.addingTimeInterval(window)
        let candidates = meetings.filter { meeting in
            // Running now — start has passed, end has not. Being late is
            // the case this feature exists for.
            if meeting.start <= now && meeting.end > now { return true }
            // Or starting soon.
            return meeting.start > now && meeting.start <= horizon
        }
        return candidates.min { a, b in
            if a.start != b.start { return a.start < b.start }
            // Same minute on two calendars, or a genuine double-booking.
            // Prefer the one they said yes to; beyond that it is arbitrary,
            // and the name is announced so a wrong pick is visible.
            return a.isAccepted && !b.isAccepted
        }
    }
}
