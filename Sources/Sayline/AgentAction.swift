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
    case openSystemSetting(SettingsPane)
    case lockScreen
    case setVolume(VolumeChange)
    case setWiFi(enabled: Bool)
    case setDarkMode(enabled: Bool)
    case emptyTrash
    case takeScreenshot

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

    /// A curated set of the panes people actually ask for by voice —
    /// not exhaustive. System Settings pane URL identifiers are notably
    /// version-fragile across macOS releases, so this list may need
    /// adjusting after live testing rather than trusting it blind.
    enum SettingsPane: String, CaseIterable {
        case privacySecurity = "PrivacySecurity"
        case notifications = "Notifications"
        case general = "General"
        case displays = "Displays"
        case sound = "Sound"
        case network = "Network"
        case bluetooth = "Bluetooth"
        case wifi = "WiFi"
        case users = "Users"
    }
}
