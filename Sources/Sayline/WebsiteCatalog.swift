import Foundation

/// The sites Sayline knows by name, and how to search them.
///
/// Deliberately a curated list rather than domain guessing. "Open
/// toolfolio" could be toolfolio.com, .io, .app or nothing at all, and
/// opening the wrong site is more annoying than refusing — so an unknown
/// bare word is rejected with a message asking for the full address,
/// while anything containing a dot is treated as a real domain and opened
/// as typed.
///
/// Search is a URL, not automation. Most sites put the query straight in
/// the address, so "search X on LinkedIn" is the same mechanism as
/// opening the site with one extra field — no page driving, nothing to
/// break when a layout changes. Every template below was checked with a
/// live request on 2026-08-09 rather than written from memory.
enum WebsiteCatalog {
    struct Site {
        let label: String
        /// Everything a person might say for this site, normalized.
        let aliases: [String]
        let home: String
        /// `%@` is replaced with the percent-encoded query. Nil means the
        /// site has no useful search, so a query falls back to the home
        /// page.
        let searchTemplate: String?
    }

    static let sites: [Site] = [
        // Search / reference
        Site(label: "Google", aliases: ["google"], home: "https://www.google.com",
             searchTemplate: "https://www.google.com/search?q=%@"),
        Site(label: "DuckDuckGo", aliases: ["duckduckgo", "duck duck go", "ddg"], home: "https://duckduckgo.com",
             searchTemplate: "https://duckduckgo.com/?q=%@"),
        Site(label: "Wikipedia", aliases: ["wikipedia", "wiki"], home: "https://en.wikipedia.org",
             searchTemplate: "https://en.wikipedia.org/w/index.php?search=%@"),
        Site(label: "Google Maps", aliases: ["maps", "google maps"], home: "https://www.google.com/maps",
             searchTemplate: "https://www.google.com/maps/search/%@"),

        // Video / music
        // "music" points here on purpose: all music requests default to
        // YouTube for now (2026-08-09). Apple Music was removed — see
        // BACKLOG.md for what that gave up and how to bring it back.
        Site(label: "YouTube", aliases: ["youtube", "you tube", "yt", "music", "apple music", "spotify music"], home: "https://www.youtube.com",
             searchTemplate: "https://www.youtube.com/results?search_query=%@"),
        Site(label: "Netflix", aliases: ["netflix"], home: "https://www.netflix.com",
             searchTemplate: "https://www.netflix.com/search?q=%@"),
        Site(label: "Spotify", aliases: ["spotify"], home: "https://open.spotify.com",
             searchTemplate: "https://open.spotify.com/search/%@"),

        // Work
        Site(label: "Gmail", aliases: ["gmail", "google mail"], home: "https://mail.google.com",
             searchTemplate: "https://mail.google.com/mail/u/0/#search/%@"),
        Site(label: "Google Drive", aliases: ["drive", "google drive"], home: "https://drive.google.com",
             searchTemplate: "https://drive.google.com/drive/search?q=%@"),
        Site(label: "Google Calendar", aliases: ["calendar", "google calendar"], home: "https://calendar.google.com",
             searchTemplate: nil),
        Site(label: "Google Docs", aliases: ["docs", "google docs"], home: "https://docs.google.com", searchTemplate: nil),
        Site(label: "Notion", aliases: ["notion"], home: "https://www.notion.so", searchTemplate: nil),
        Site(label: "Slack", aliases: ["slack"], home: "https://app.slack.com", searchTemplate: nil),
        Site(label: "Zoom", aliases: ["zoom"], home: "https://zoom.us", searchTemplate: nil),
        Site(label: "Figma", aliases: ["figma"], home: "https://www.figma.com", searchTemplate: nil),
        Site(label: "Linear", aliases: ["linear"], home: "https://linear.app", searchTemplate: nil),
        Site(label: "Jira", aliases: ["jira"], home: "https://www.atlassian.com/software/jira", searchTemplate: nil),

        // Social
        Site(label: "LinkedIn", aliases: ["linkedin", "linked in"], home: "https://www.linkedin.com",
             searchTemplate: "https://www.linkedin.com/search/results/all/?keywords=%@"),
        Site(label: "X", aliases: ["x", "twitter"], home: "https://x.com",
             searchTemplate: "https://x.com/search?q=%@"),
        Site(label: "Instagram", aliases: ["instagram", "insta"], home: "https://www.instagram.com", searchTemplate: nil),
        Site(label: "Facebook", aliases: ["facebook", "fb"], home: "https://www.facebook.com", searchTemplate: nil),
        Site(label: "Reddit", aliases: ["reddit"], home: "https://www.reddit.com",
             searchTemplate: "https://www.reddit.com/search/?q=%@"),
        Site(label: "WhatsApp Web", aliases: ["whatsapp web", "web whatsapp"], home: "https://web.whatsapp.com", searchTemplate: nil),

        // Dev / maker
        Site(label: "GitHub", aliases: ["github", "git hub"], home: "https://github.com",
             searchTemplate: "https://github.com/search?q=%@"),
        Site(label: "Stack Overflow", aliases: ["stack overflow", "stackoverflow"], home: "https://stackoverflow.com",
             searchTemplate: "https://stackoverflow.com/search?q=%@"),
        Site(label: "Hacker News", aliases: ["hacker news", "hackernews", "hn"], home: "https://news.ycombinator.com",
             searchTemplate: "https://hn.algolia.com/?q=%@"),
        Site(label: "Product Hunt", aliases: ["product hunt", "producthunt"], home: "https://www.producthunt.com",
             searchTemplate: "https://www.producthunt.com/search?q=%@"),
        Site(label: "Dribbble", aliases: ["dribbble", "dribble"], home: "https://dribbble.com",
             searchTemplate: "https://dribbble.com/search/%@"),
        Site(label: "Amazon", aliases: ["amazon"], home: "https://www.amazon.com",
             searchTemplate: "https://www.amazon.com/s?k=%@"),
    ]

    /// What the router model is offered. It can only pick a name it has
    /// been shown — a lesson from the settings catalog, where a missing
    /// word sent requests to the wrong place entirely.
    static var promptVocabulary: [String] {
        sites.map { $0.label }
    }

    /// Whether what the user said means YouTube — used to decide if a
    /// "play" request can be upgraded to a real video.
    static func isYouTube(_ requested: String) -> Bool {
        let n = normalize(requested)
        guard let site = sites.first(where: { $0.label == "YouTube" }) else { return false }
        return site.aliases.contains { normalize($0) == n } || normalize(site.label) == n
    }

    enum Resolution {
        case site(label: String, url: URL)
        /// Contains a dot, so treat it as a real address the user spelled out.
        case explicitDomain(url: URL)
        /// Neither known nor a domain — refuse rather than guess.
        case unknown(String)
    }

    static func resolve(_ requested: String, query: String?) -> Resolution {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalize(trimmed)

        if let site = sites.first(where: { $0.aliases.contains(where: { normalize($0) == normalized }) })
            ?? sites.first(where: { normalize($0.label) == normalized }) {
            if let query, !query.isEmpty, let template = site.searchTemplate,
               let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed),
               let url = URL(string: String(format: template, encoded)) {
                return .site(label: site.label, url: url)
            }
            if let url = URL(string: site.home) {
                return .site(label: site.label, url: url)
            }
        }

        // A dot means the user spelled out an address, which is exactly
        // what we ask for when a name isn't recognised.
        if let address = spokenDomain(trimmed), let url = URL(string: address) {
            return .explicitDomain(url: url)
        }

        return .unknown(trimmed)
    }

    /// Turns what was said into a URL, or nil if it isn't an address.
    ///
    /// Two bugs the first version had, both caught by testing rather than
    /// review: "toolfolio dot com" validated as a domain but then built
    /// the URL from the *original* text, producing `toolfoliodotcom`; and
    /// a full URL like `https://example.org/path` was rejected, because
    /// the last dot-separated piece was `org/path`, which isn't all
    /// letters. Scheme and path are now stripped before the check, and the
    /// URL is built from the same normalized string that passed it.
    private static func spokenDomain(_ text: String) -> String? {
        let normalized = text.lowercased()
            .replacingOccurrences(of: " dot ", with: ".")
            .replacingOccurrences(of: " ", with: "")

        var host = normalized
        if let schemeEnd = host.range(of: "://") {
            host = String(host[schemeEnd.upperBound...])
        }
        host = host.split(separator: "/").first.map(String.init) ?? host

        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."),
              let tld = host.split(separator: ".").last.map(String.init),
              tld.count >= 2, tld.allSatisfy({ $0.isLetter }) else {
            return nil
        }
        return normalized.contains("://") ? normalized : "https://\(normalized)"
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

private extension CharacterSet {
    /// `urlQueryAllowed` leaves `&` and `+` intact, which corrupts a query
    /// containing either.
    static let urlQueryValueAllowed = CharacterSet.urlQueryAllowed
        .subtracting(CharacterSet(charactersIn: "&+=?"))
}
