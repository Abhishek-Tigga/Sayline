import Foundation

/// The small, explicit set of things agent mode can currently do.
/// Deliberately not open-ended — every new capability gets added here
/// on purpose, with its own tool definition and execution, not inferred
/// freely by the model.
enum AgentAction {
    case openApp(name: String)
    case findFile(query: String, folder: SearchFolder)

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
