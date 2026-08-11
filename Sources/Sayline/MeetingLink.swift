import Foundation

/// Where calendar text stops.
///
/// Event titles, locations and notes are written by other people. Anyone
/// who can send you an invite can put words in them, and a voice command
/// opens whatever comes out of here — so this is the trust boundary from
/// `DESIGN-meetings-reminders.md`, made mechanical.
///
/// **Known providers only.** Never "the first URL in the notes". That rule
/// is the whole point: a notes field is attacker-writable, and a matcher
/// that took any URL would let an invite plant an arbitrary link that
/// Sayline then opens on command. The costs are asymmetric — a provider we
/// have not listed degrades to the honest "no join link" answer and earns
/// a line in the manual checklist, while a pattern that is too loose opens
/// a stranger's URL. This errs on the cheap side.
///
/// The residual risk, stated rather than hidden: an extracted link is still
/// chosen by whoever sent the invite. The whitelist caps that at "a real
/// meeting on a real provider", which is the feature working.
enum MeetingLink {
    /// Providers we will open, as host + path shapes. Matched against the
    /// host specifically, not anywhere in the string, so
    /// `evil.com/?x=zoom.us/j/1` cannot pass by containing a good name.
    private static let providers: [(host: String, path: String?)] = [
        ("zoom.us", "/j/"),              // zoom.us/j/123, subdomains included
        ("zoom.us", "/my/"),
        ("meet.google.com", nil),
        ("teams.microsoft.com", nil),    // /l/meetup-join/… monstrosities
        ("teams.live.com", nil),
        ("webex.com", nil),              // company.webex.com/meet|join/…
        ("meet.jit.si", nil),
        ("whereby.com", nil),
        ("chime.aws", nil),
        ("bluejeans.com", nil),
        ("gotomeeting.com", nil),
        ("meetings.hubspot.com", nil),
    ]

    /// The join link, or nil.
    ///
    /// Field order is the design's: `url`, then `location`, then `notes`.
    /// Zoom usually fills the first two; Google Meet usually writes into
    /// notes. First match wins, which is why order matters — a notes field
    /// holding both a feedback survey and a Meet link must yield the Meet
    /// link, and it does because only one of them is a provider at all.
    static func extract(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, isProvider(url) { return url }
        for text in [location, notes] {
            guard let text else { continue }
            if let found = firstProviderURL(in: text) { return found }
        }
        return nil
    }

    static func isProvider(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        return providers.contains { provider in
            // Suffix match so subdomains count — acme.zoom.us is Zoom —
            // while "notzoom.us" is not, because the boundary must be a dot.
            let hostMatches = host == provider.host || host.hasSuffix("." + provider.host)
            guard hostMatches else { return false }
            guard let required = provider.path else { return true }
            return path.hasPrefix(required)
        }
    }

    /// Scans free text for the first URL that belongs to a known provider.
    /// Non-provider URLs are skipped rather than ending the search, so a
    /// survey link before a Meet link does not hide it.
    private static func firstProviderURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url, isProvider(url) else { continue }
            return url
        }
        return nil
    }
}
