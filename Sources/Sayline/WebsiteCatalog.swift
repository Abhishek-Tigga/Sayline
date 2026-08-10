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
        /// page — and the caller says so rather than silently dropping it.
        let searchTemplate: String?
        /// Per-country overrides, keyed by ISO region code. Amazon changes
        /// its whole domain per country, Apple changes a path segment, so
        /// this stores complete replacements rather than trying to patch
        /// one part of the URL.
        /// Pages that belong to the signed-in user, keyed by the bare word
        /// left after "open my ... on <site>" is stripped down. Paths, not
        /// full URLs, so the regional home applies to them for free.
        var personalPages: [String: String] = [:]
        var regional: [String: Variant] = [:]
        /// Separate search tabs, each its own URL. "People from Razorpay"
        /// and "Razorpay jobs" are different pages on LinkedIn, not the
        /// same page filtered — sending both to the default search buries
        /// the answer under unrelated results.
        var verticals: [String: String] = [:]
    }

    struct Variant {
        let home: String
        let search: String?
    }

    /// Where the Mac says it is. Not hardcoded: a user in the US should
    /// get amazon.com and a user in India amazon.in, from the same build.
    /// Falls back to the default (US/global) entries when a country has no
    /// override, which is most of them — YouTube and Wikipedia are the same
    /// everywhere.
    static var region: String {
        Locale.current.region?.identifier.uppercased() ?? "US"
    }

    static let sites: [Site] = [
        // Search / reference
        Site(label: "Google", aliases: ["google"], home: "https://www.google.com",
             searchTemplate: "https://www.google.com/search?q=%@",
             verticals: [
                "images": "https://www.google.com/search?q=%@&tbm=isch",
                "news": "https://news.google.com/search?q=%@",
                "videos": "https://www.google.com/search?q=%@&tbm=vid",
                "maps": "https://www.google.com/maps/search/%@",
                "shopping": "https://www.google.com/search?q=%@&tbm=shop",
             ]),
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
             searchTemplate: "https://www.youtube.com/results?search_query=%@",
             personalPages: [
                             "subscriptions": "/feed/subscriptions",
                             "history": "/feed/history",
                             "watch later": "/playlist?list=WL",
                             "liked videos": "/playlist?list=LL",
                             "playlists": "/feed/playlists",
                            ]),
        Site(label: "Netflix", aliases: ["netflix"], home: "https://www.netflix.com",
             searchTemplate: "https://www.netflix.com/search?q=%@",
             personalPages: [
                             "my list": "/browse/my-list",
                             "list": "/browse/my-list",
                            ]),
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
             searchTemplate: "https://www.linkedin.com/search/results/all/?keywords=%@",
             personalPages: [
                             "messages": "/messaging/",
                             "messaging": "/messaging/",
                             "inbox": "/messaging/",
                             "notifications": "/notifications/",
                             "profile": "/in/me/",
                             "invitations": "/mynetwork/invitation-manager/",
                             "network": "/mynetwork/",
                             "saved jobs": "/my-items/saved-jobs/",
                             "saved items": "/my-items/",
                            ],
             verticals: [
                "people": "https://www.linkedin.com/search/results/people/?keywords=%@",
                "companies": "https://www.linkedin.com/search/results/companies/?keywords=%@",
                "jobs": "https://www.linkedin.com/jobs/search/?keywords=%@",
                "posts": "https://www.linkedin.com/search/results/content/?keywords=%@",
             ]),
        Site(label: "X", aliases: ["x", "twitter"], home: "https://x.com",
             searchTemplate: "https://x.com/search?q=%@"),
        Site(label: "Instagram", aliases: ["instagram", "insta"], home: "https://www.instagram.com", searchTemplate: nil),
        Site(label: "Facebook", aliases: ["facebook", "fb"], home: "https://www.facebook.com", searchTemplate: nil),
        Site(label: "Reddit", aliases: ["reddit"], home: "https://www.reddit.com",
             searchTemplate: "https://www.reddit.com/search/?q=%@",
             personalPages: [
                             "saved": "/user/me/saved",
                             "profile": "/user/me/",
                            ]),
        Site(label: "WhatsApp Web", aliases: ["whatsapp web", "web whatsapp"], home: "https://web.whatsapp.com", searchTemplate: nil),

        // Dev / maker
        Site(label: "GitHub", aliases: ["github", "git hub"], home: "https://github.com",
             searchTemplate: "https://github.com/search?q=%@",
             personalPages: [
                             "notifications": "/notifications",
                             "pull requests": "/pulls",
                             "issues": "/issues",
                             "repositories": "/settings/repositories",
                             "repos": "/settings/repositories",
                            ],
             verticals: [
                "repositories": "https://github.com/search?q=%@&type=repositories",
                "users": "https://github.com/search?q=%@&type=users",
                "issues": "https://github.com/search?q=%@&type=issues",
             ]),
        Site(label: "Stack Overflow", aliases: ["stack overflow", "stackoverflow"], home: "https://stackoverflow.com",
             searchTemplate: "https://stackoverflow.com/search?q=%@"),
        Site(label: "Hacker News", aliases: ["hacker news", "hackernews", "hn"], home: "https://news.ycombinator.com",
             searchTemplate: "https://hn.algolia.com/?q=%@"),
        Site(label: "Product Hunt", aliases: ["product hunt", "producthunt"], home: "https://www.producthunt.com",
             searchTemplate: "https://www.producthunt.com/search?q=%@"),
        Site(label: "Dribbble", aliases: ["dribbble", "dribble"], home: "https://dribbble.com",
             searchTemplate: "https://dribbble.com/search/%@"),
        Site(label: "Amazon", aliases: ["amazon"], home: "https://www.amazon.com",
             searchTemplate: "https://www.amazon.com/s?k=%@",
             personalPages: [
                             "orders": "/gp/css/order-history",
                             "cart": "/gp/cart/view.html",
                             "basket": "/gp/cart/view.html",
                             "wishlist": "/hz/wishlist/ls",
                             "returns": "/spr/returns/list",
                            ],
             regional: [
                "IN": Variant(home: "https://www.amazon.in", search: "https://www.amazon.in/s?k=%@"),
                "GB": Variant(home: "https://www.amazon.co.uk", search: "https://www.amazon.co.uk/s?k=%@"),
                "DE": Variant(home: "https://www.amazon.de", search: "https://www.amazon.de/s?k=%@"),
                "FR": Variant(home: "https://www.amazon.fr", search: "https://www.amazon.fr/s?k=%@"),
                "IT": Variant(home: "https://www.amazon.it", search: "https://www.amazon.it/s?k=%@"),
                "ES": Variant(home: "https://www.amazon.es", search: "https://www.amazon.es/s?k=%@"),
                "CA": Variant(home: "https://www.amazon.ca", search: "https://www.amazon.ca/s?k=%@"),
                "AU": Variant(home: "https://www.amazon.com.au", search: "https://www.amazon.com.au/s?k=%@"),
                "JP": Variant(home: "https://www.amazon.co.jp", search: "https://www.amazon.co.jp/s?k=%@"),
                "BR": Variant(home: "https://www.amazon.com.br", search: "https://www.amazon.com.br/s?k=%@"),
                "MX": Variant(home: "https://www.amazon.com.mx", search: "https://www.amazon.com.mx/s?k=%@"),
                "AE": Variant(home: "https://www.amazon.ae", search: "https://www.amazon.ae/s?k=%@"),
             ]),
        // Apple keeps one domain and switches a path segment; the US site
        // has no segment at all, which is why the default differs in shape.
        Site(label: "Apple", aliases: ["apple", "apple store", "apple website"],
             home: "https://www.apple.com",
             searchTemplate: "https://www.apple.com/search/%@",
             regional: [
                "IN": Variant(home: "https://www.apple.com/in", search: "https://www.apple.com/in/search/%@"),
                "GB": Variant(home: "https://www.apple.com/uk", search: "https://www.apple.com/uk/search/%@"),
                "DE": Variant(home: "https://www.apple.com/de", search: "https://www.apple.com/de/search/%@"),
                "FR": Variant(home: "https://www.apple.com/fr", search: "https://www.apple.com/fr/search/%@"),
                "CA": Variant(home: "https://www.apple.com/ca", search: "https://www.apple.com/ca/search/%@"),
                "AU": Variant(home: "https://www.apple.com/au", search: "https://www.apple.com/au/search/%@"),
                "JP": Variant(home: "https://www.apple.com/jp", search: "https://www.apple.com/jp/search/%@"),
             ]),
    ]

    /// What the router model is offered. It can only pick a name it has
    /// been shown — a lesson from the settings catalog, where a missing
    /// word sent requests to the wrong place entirely.
    static var promptVocabulary: [String] {
        sites.map { $0.label }
    }

    /// Every vertical any site supports, for the tool schema. The model
    /// picks a name; resolve() only honours it if that site actually has
    /// one, so an irrelevant pairing degrades to normal search rather than
    /// failing.
    static var verticalVocabulary: [String] {
        Array(Set(sites.flatMap { $0.verticals.keys })).sorted()
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
        /// The site is known but has no search URL, so the query could not
        /// be used. Carried explicitly so the caller can say so — silently
        /// opening the home page made the app look like it half-listened.
        case siteWithoutSearch(label: String, url: URL, droppedQuery: String)
        /// Contains a dot, so treat it as a real address the user spelled out.
        case explicitDomain(url: URL)
        /// Neither known nor a domain — refuse rather than guess.
        case unknown(String)
    }

    /// Country words people attach to a site name, mapped to region codes.
    /// Saying "amazon india" should reach amazon.in even from a Mac set to
    /// the US — an explicit country beats the detected one, because the
    /// user just told us which they meant.
    private static let countryWords: [String: String] = [
        "india": "IN", "indian": "IN",
        "us": "US", "usa": "US", "america": "US", "american": "US",
        "uk": "GB", "britain": "GB", "british": "GB", "england": "GB",
        "canada": "CA", "canadian": "CA",
        "australia": "AU", "australian": "AU",
        "germany": "DE", "german": "DE",
        "france": "FR", "french": "FR",
        "japan": "JP", "japanese": "JP",
        "uae": "AE", "emirates": "AE",
    ]

    /// Splits "apple india" into ("apple", "IN"). Returns nil for the
    /// region when no country was named, so the detected one is used.
    private static func splitCountry(_ text: String) -> (name: String, region: String?) {
        var words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        // Only strip a trailing country word, and only if something is left
        // — "india" alone is not a site name with the country removed.
        if let last = words.last, let code = countryWords[last], words.count > 1 {
            words.removeLast()
            return (words.joined(separator: " "), code)
        }
        return (text, nil)
    }

    /// Words that carry no meaning once we know the site and are looking
    /// for a bare intent: "open my saved items on LinkedIn" -> "saved items".
    private static let personalFiller: Set<String> = [
        "my", "mine", "the", "a", "an", "on", "in", "at", "of", "for", "to",
        "page", "pages", "tab", "section", "list", "show", "open", "see",
        "view", "get", "go", "me", "all", "please",
    ]

    /// The catalog entry for a spoken site name, country word and all.
    static func site(matching requested: String) -> Site? {
        let (baseName, _) = splitCountry(requested.trimmingCharacters(in: .whitespacesAndNewlines))
        let n = normalize(baseName)
        return sites.first { $0.aliases.contains { normalize($0) == n } }
            ?? sites.first { normalize($0.label) == n }
    }

    /// A page belonging to the signed-in user, when the query reduces to a
    /// bare intent word this site knows.
    ///
    /// Exists because the model cannot supply these reliably. It has no
    /// idea which region this Mac is in, so every URL it offers is
    /// region-blind — "my Amazon orders" came back as amazon.com. And when
    /// it offered no URL at all, the query fell through to the ordinary
    /// search template, which is how "open my LinkedIn messages" ended up
    /// searching LinkedIn for the phrase "my LinkedIn messages".
    ///
    /// Deliberately strict. The query must reduce to a known intent and
    /// nothing else, so "wireless mouse on Amazon" cannot be captured by
    /// this table on its way to a perfectly good product search.
    static func personalPage(site: Site, query: String, region overrideRegion: String? = nil) -> URL? {
        guard !site.personalPages.isEmpty else { return nil }
        let siteWords = Set((site.aliases + [site.label]).flatMap {
            $0.lowercased().split(separator: " ").map(String.init)
        })
        let remaining = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !personalFiller.contains($0) && !siteWords.contains($0) }
            .joined(separator: " ")
        guard !remaining.isEmpty,
              let path = site.personalPages[remaining] else { return nil }

        let home = site.regional[overrideRegion ?? region]?.home ?? site.home
        return URL(string: home + path)
    }

    /// Moves a URL the model supplied onto the regional domain when the
    /// site has one. The model writes amazon.com and apple.com because it
    /// has no way to know better; this is the single place that knowledge
    /// lives, so it belongs here rather than in the prompt.
    static func regionalized(_ url: URL, siteHint: String?) -> URL {
        let absolute = url.absoluteString
        let candidates = siteHint
            .map { hint -> [Site] in
                let (name, _) = splitCountry(hint)
                let n = normalize(name)
                return sites.filter { $0.aliases.contains { normalize($0) == n } || normalize($0.label) == n }
            }
            .flatMap { $0.isEmpty ? nil : $0 } ?? sites
        let explicit = siteHint.flatMap { splitCountry($0).region }

        for site in candidates {
            guard let variant = site.regional[explicit ?? region] else { continue }
            // Already regional — Apple's variants are path-based, so a naive
            // prefix swap would produce apple.com/in/in/iphone.
            guard !absolute.hasPrefix(variant.home) else { return url }
            guard absolute.hasPrefix(site.home) else { continue }
            let tail = String(absolute.dropFirst(site.home.count))
            if let rebuilt = URL(string: variant.home + tail) { return rebuilt }
        }
        return url
    }

    static func resolve(_ requested: String, query: String?, vertical: String? = nil) -> Resolution {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        let (baseName, explicitRegion) = splitCountry(trimmed)
        let normalized = normalize(baseName)

        if let site = sites.first(where: { $0.aliases.contains(where: { normalize($0) == normalized }) })
            ?? sites.first(where: { normalize($0.label) == normalized }) {
            // Country override when the site has one for wherever this Mac
            // is; otherwise the default entry, which is right for the many
            // sites that are the same everywhere.
            let variant = site.regional[explicitRegion ?? region]
            let home = variant?.home ?? site.home
            let template = variant?.search ?? site.searchTemplate

            if let query, !query.isEmpty {
                // The user's own page wins over any search — asking for
                // "my messages" and getting a search for that phrase is
                // the failure this table exists to prevent.
                if let page = personalPage(site: site, query: query, region: explicitRegion) {
                    return .site(label: "\(site.label) — \(query)", url: page)
                }
                // A vertical wins when the site has that tab; otherwise the
                // ordinary search, which is still a reasonable answer.
                let chosen = vertical
                    .flatMap { v in site.verticals.first { $0.key.caseInsensitiveCompare(v) == .orderedSame }?.value }
                    ?? template
                if let chosen,
                   let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed),
                   let url = URL(string: String(format: chosen, encoded)) {
                    let label = vertical.map { "\(site.label) · \($0)" } ?? site.label
                    return .site(label: label, url: url)
                }
                if let url = URL(string: home) {
                    return .siteWithoutSearch(label: site.label, url: url, droppedQuery: query)
                }
            }
            if let url = URL(string: home) {
                return .site(label: site.label, url: url)
            }
        }

        // A dot means the user spelled out an address, which is exactly
        // what we ask for when a name isn't recognised.
        if let address = spokenDomain(trimmed), let url = URL(string: address) {
            if let query, !query.isEmpty {
                // We know the address but not how that site takes a search.
                return .siteWithoutSearch(label: url.host ?? trimmed, url: url, droppedQuery: query)
            }
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
