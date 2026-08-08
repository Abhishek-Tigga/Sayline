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
