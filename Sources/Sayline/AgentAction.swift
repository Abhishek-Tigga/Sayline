import Foundation

/// The small, explicit set of things agent mode can currently do.
/// Deliberately not open-ended — every new capability gets added here
/// on purpose, with its own tool definition and execution, not inferred
/// freely by the model.
enum AgentAction {
    case openApp(name: String)
    case closeApp(name: String)
    case findFile(query: String, folder: SearchFolder, subpath: String?)
    case openFolder(SearchFolder, subpath: String?)
    /// `bundleID` is resolved from the live `SettingsPaneCatalog` before
    /// this case is ever constructed — no hardcoded pane enum here
    /// anymore (see BACKLOG.md, "Dynamic System Settings pane catalog").
    case openSystemSetting(paneName: String, bundleID: String)
    /// Deterministic, visible fallback when the requested pane name
    /// doesn't match anything in the live catalog — opens System
    /// Settings itself rather than doing nothing silently.
    case openSystemSettingsFallback(requestedPaneName: String)
    case lockScreen
    case setVolume(VolumeChange)
    case setWiFi(enabled: Bool)
    case setDarkMode(enabled: Bool)
    case emptyTrash
    case takeScreenshot
    /// Opens a site, or a site's search results. `label` is only for the
    /// log — the URL is already resolved by WebsiteCatalog.
    case openWebsite(label: String, url: URL)
    /// The name matched no known site and wasn't a domain. Refused on
    /// purpose rather than guessing a TLD: opening the wrong site is more
    /// annoying than saying "say the full address".
    case unknownWebsite(requested: String)
    /// Site opened, but it publishes no search URL we know, so the query
    /// went unused. Reported rather than dropped quietly.
    case openedSiteButCouldNotSearch(label: String, url: URL, query: String)
    /// "play <thing> on YouTube". Resolved asynchronously in AgentRouter
    /// into a real `/watch` URL, which autoplays — unlike the search page.
    /// Falls back to the search page if the lookup fails for any reason.
    case playOnYouTube(query: String)
    /// A specific page the model supplied from memory. Checked with a HEAD
    /// request before opening, because it might not exist; falls back to
    /// the site's search when it doesn't.
    case openDirectPage(url: URL, fallbackSite: String, fallbackQuery: String?)
    /// Distinct from every case above — these don't perform a side
    /// effect, they produce an answer to display. Handled by a separate
    /// AgentExecutor.answer(_:) path rather than the Bool-returning
    /// execute(_:), since "did it succeed" isn't the right question for
    /// a fact lookup.
    case answerQuery(SystemQuery)

    enum SystemQuery: String, CaseIterable {
        case battery = "Battery"
        case storage = "Storage"
        case memory = "Memory"
        case uptime = "Uptime"
        case volumeLevel = "VolumeLevel"
        case macOSVersion = "MacOSVersion"
        case nowPlaying = "NowPlaying"
    }

    enum VolumeChange: String, CaseIterable {
        case mute = "Mute"
        case unmute = "Unmute"
        case up = "Up"
        case down = "Down"
    }

    /// Restricted to a fixed enum, not an arbitrary path — sidesteps any
    /// path-traversal concern entirely rather than needing to validate
    /// free-form input from the model.
    enum SearchFolder: String, CaseIterable {
        case downloads = "Downloads"
        case documents = "Documents"
        case desktop = "Desktop"
        case home = "Home"
    }

}
