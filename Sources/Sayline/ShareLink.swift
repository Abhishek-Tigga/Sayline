import Foundation

/// The deterministic half of "share this page" — recipient resolution,
/// number preference, encoding, and URL construction.
///
/// Pure Foundation on purpose. Contacts and NSSharingService live in the
/// executor; everything here is a function of its inputs, so
/// `eval/whatsapp-checks` can compile it without a framework and the
/// parts most likely to be wrong are the parts most cheaply tested.
///
/// The design is `DESIGN-whatsapp-share.md`; the decisions cited below
/// are its numbering.
enum ShareLink {

    /// Who the page is going to, exactly as the router may express it.
    enum Recipient: Equatable {
        case named(String)
        /// "save this to my WhatsApp" — the user's own number.
        case selfTarget
        /// "share this" — no person named; the app asks the target.
        case unnamed
    }

    enum Target: String, Equatable {
        case whatsapp
        case airdrop
    }

    // MARK: - Recipient resolution

    /// One contact card, reduced to what the decision needs.
    struct Candidate: Equatable {
        let name: String
        /// Label as Contacts reports it, and the number as written there.
        let numbers: [(label: String, number: String)]

        static func == (a: Candidate, b: Candidate) -> Bool {
            a.name == b.name && a.numbers.map { $0.number } == b.numbers.map { $0.number }
        }
    }

    enum Resolution: Equatable {
        case resolved(name: String, number: String)
        /// Two or more people, or two or more numbers for one person.
        /// Decision 5: ambiguity is asked, never guessed.
        case ambiguous(name: String, options: [String])
        case notFound(spoken: String)
        /// A number with no country code cannot be dialled by `wa.me`.
        /// Decision's failure table: ask once, remember per contact.
        case needsCountryCode(name: String, number: String)
    }

    /// Fuzzy first-name match, then the number choice.
    ///
    /// Deliberately not ranked by recency. Decision 5 rejected
    /// most-recently-contacted tiebreaking: it is invisible state
    /// pretending to be smart, and the cost of being wrong is asymmetric
    /// — the user reviews a prefilled message, but only if they notice.
    static func resolve(spoken: String, in candidates: [Candidate]) -> Resolution {
        let hits = candidates.filter { matches(spoken: spoken, name: $0.name) }
        guard !hits.isEmpty else { return .notFound(spoken: spoken) }
        guard hits.count == 1 else {
            return .ambiguous(name: spoken, options: hits.map { $0.name })
        }

        let person = hits[0]
        guard !person.numbers.isEmpty else { return .notFound(spoken: spoken) }

        // One number, or a single mobile among several — decision 5's
        // "prefer the mobile label, else ask".
        let chosen: String
        if person.numbers.count == 1 {
            chosen = person.numbers[0].number
        } else {
            let mobiles = person.numbers.filter { isMobile($0.label) }
            guard mobiles.count == 1 else {
                return .ambiguous(name: person.name,
                                  options: person.numbers.map { $0.number })
            }
            chosen = mobiles[0].number
        }

        let digits = normalize(chosen)
        guard hasCountryCode(digits) else {
            return .needsCountryCode(name: person.name, number: digits)
        }
        return .resolved(name: person.name, number: digits)
    }

    /// A spoken first name against a full contact name.
    ///
    /// Case- and diacritic-insensitive, matching any whole name part, so
    /// "Priya" finds "Priya Sharma" and "Sharma" finds her too. Substring
    /// matching is deliberately NOT used: "Ann" would otherwise match
    /// "Joanna", and a wrong recipient is the worst outcome this feature
    /// can produce (decision 5).
    static func matches(spoken: String, name: String) -> Bool {
        let needle = fold(spoken)
        guard !needle.isEmpty else { return false }
        let parts = fold(name).split(separator: " ").map(String.init)
        if parts.contains(needle) { return true }
        // The whole spoken string against the whole name, for "Priya Sharma".
        return fold(name) == needle
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Labels Contacts uses for a mobile line, across locales we can see.
    /// `_$!<Mobile>!$_` is the raw form CNContact stores.
    static func isMobile(_ label: String) -> Bool {
        let l = label.lowercased()
        return l.contains("mobile") || l.contains("iphone") || l.contains("cell")
    }

    /// Digits and a leading `+` only. Contacts stores "+91 98765 43210",
    /// "(555) 010-9999", "+91-98765-43210" — all the same number.
    static func normalize(_ number: String) -> String {
        var digits = number.filter { $0.isNumber }
        if number.trimmingCharacters(in: .whitespaces).hasPrefix("+") {
            digits = "+" + digits
        }
        return digits
    }

    /// `wa.me` requires a full international number. A leading `+`, or a
    /// length that cannot be a local number, is the only signal available
    /// locally — anything less certain asks rather than guesses.
    static func hasCountryCode(_ normalized: String) -> Bool {
        if normalized.hasPrefix("+") { return normalized.count >= 8 }
        return false
    }

    // MARK: - Message and URL construction

    /// Note on one line, URL on its own.
    ///
    /// Decision 12: WhatsApp's link preview works best with the URL
    /// alone on its line, and decision 9 keeps the note the user's own
    /// cleaned words. No note means the message is the bare URL — never
    /// a generated sentence about the page.
    static func message(note: String?, url: URL) -> String {
        guard let note = note?.trimmingCharacters(in: .whitespacesAndNewlines),
              !note.isEmpty else { return url.absoluteString }
        return "\(note)\n\(url.absoluteString)"
    }

    /// Percent-encoding for a query value.
    ///
    /// `urlQueryAllowed` leaves `&`, `+`, `=`, `#` and `?` intact, which
    /// is right for a whole query string and wrong for one value inside
    /// it: a shared URL carrying `?utm=a&b=c` would otherwise split into
    /// extra parameters and the tail would vanish from the message.
    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// `whatsapp://send?...` — the desktop app, opened directly.
    ///
    /// Prefill only. There is no parameter here that sends, and decision
    /// 4 says there never will be on any path.
    static func whatsappURL(number: String?, message: String) -> URL? {
        var query = "text=\(encode(message))"
        if let number, !number.isEmpty {
            // The scheme wants digits without the +.
            query = "phone=\(encode(number.replacingOccurrences(of: "+", with: "")))&" + query
        }
        return URL(string: "whatsapp://send?\(query)")
    }

    /// `https://wa.me/...` — the fallback when the desktop app is absent.
    static func waMeURL(number: String?, message: String) -> URL? {
        let path = (number ?? "").replacingOccurrences(of: "+", with: "")
        return URL(string: "https://wa.me/\(path)?text=\(encode(message))")
    }
}
