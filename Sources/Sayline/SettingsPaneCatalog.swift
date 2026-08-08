import Foundation

/// Reads the real, complete list of System Settings panes from the OS at
/// launch instead of maintaining a hand-written enum. Root cause this
/// replaces: a hardcoded `SettingsPane` enum covered only 10 panes while
/// the OS ships ~56, so any pane outside the list ("keyboard settings",
/// "wallpaper") silently failed, and each fix so far was a one-off patch
/// (Privacy, then Touch ID & Password) rather than closing the class.
/// Scanning `/System/Library/ExtensionKit/Extensions/*.appex` directly
/// means the catalog is always exactly what's actually installed — the
/// stale-identifier class of bug (found for `.general` on 2026-08-08)
/// becomes structurally impossible, since there's no hand-copied
/// identifier left to go stale.
enum SettingsPaneCatalog {
    struct Pane {
        let displayName: String
        let bundleID: String
    }

    /// Scanned once, at first access — 227 `.appex` bundles' Info.plist
    /// files on a live 2026-08-08 machine, filtered down to 56 real
    /// settings panes. Cheap enough (well under a second) that a plain
    /// `static let` with no explicit warm-up is fine.
    static let panes: [Pane] = scan()

    /// Three-stage match, in order of confidence. Exact-normalized alone
    /// (all this did until 2026-08-09) turned out to be far too brittle
    /// against real model output — live testing found "keyboard
    /// settings", "display", "Dock", and "General" all falling through to
    /// the failure path despite each naming a real pane.
    static func bundleID(forPaneName name: String) -> String? {
        // "System Settings" / "Settings" means the app itself, not a pane.
        // Left unmatched here on purpose — both so it can't subset-match
        // its way into "System Extensions", and so the caller can route it
        // to open_app instead (see meansSystemSettingsApp).
        guard !meansSystemSettingsApp(name) else { return nil }
        let queryTokens = tokens(name)

        // 1. Whole-string match, punctuation and "and"/"&" folded away.
        //    Catches the cases token-splitting would break, notably
        //    "wifi" -> "Wi-Fi" (which splits into two tokens).
        let joined = normalize(name)
        if let pane = panes.first(where: { normalize($0.displayName) == joined }) {
            return pane.bundleID
        }

        // 2. Hand-written aliases for names with no literal catalog entry.
        if let target = aliases[queryTokens.joined(separator: " ")],
           let pane = panes.first(where: { normalize($0.displayName) == normalize(target) }) {
            return pane.bundleID
        }

        // 3. Token-subset match, tightest fit wins — "keyboard settings"
        //    -> Keyboard, "display" -> Displays, "dock" -> Desktop & Dock.
        let scored: [(pane: Pane, slack: Int)] = panes.compactMap { pane in
            let paneTokens = tokens(pane.displayName)
            if queryTokens.isSubset(of: paneTokens) {
                return (pane, paneTokens.count - queryTokens.count)
            }
            if paneTokens.isSubset(of: queryTokens) {
                return (pane, queryTokens.count - paneTokens.count)
            }
            return nil
        }
        return scored.min(by: { $0.slack < $1.slack })?.pane.bundleID
    }

    /// True when the model's pane string names the System Settings app
    /// rather than any pane inside it — "Settings", "System Settings", or
    /// nothing left once noise words are stripped. Those requests want
    /// the app opened, not a pane lookup, so the caller routes them to
    /// open_app. Without this the no-match fallback swallows them and
    /// (since 2026-08-09, when the fallback correctly stopped opening a
    /// stale pane) "open settings" does nothing at all.
    static func meansSystemSettingsApp(_ name: String) -> Bool {
        let t = tokens(name)
        return t.isEmpty || t == ["system"]
    }

    /// Folds "&" and the word "and" together so "Touch ID & Password"
    /// matches a model response of "Touch ID and Password" — found via
    /// testing that the plain strip-non-alphanumeric scheme (matching
    /// AgentRouter's other enum matching) missed exactly that pair, which
    /// is the one confirmed-important pane most likely to get spelled out
    /// instead of using the symbol.
    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "&", with: " ")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0 != "and" }
            .joined()
    }

    /// Words that carry no identifying signal in either a spoken request
    /// or a pane name — dropped so "keyboard settings" and "Keyboard"
    /// reduce to the same token set.
    private static let noiseWords: Set<String> = [
        "and", "the", "my", "settings", "setting", "preferences", "preference", "pane", "panel",
    ]

    /// Both sides of every comparison go through this, so the crude
    /// trailing-"s" singularization ("displays" -> "display", but also
    /// "focus" -> "focu") is harmless — it only has to be *consistent*,
    /// not linguistically correct.
    private static func tokens(_ s: String) -> Set<String> {
        let raw = s.lowercased()
            .replacingOccurrences(of: "&", with: " ")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !noiseWords.contains($0) }
        return Set(raw.map { $0.count > 3 && $0.hasSuffix("s") ? String($0.dropLast()) : $0 })
    }

    /// Things people really say that have no literal catalog entry,
    /// because macOS implements them as a sidebar *category* or as a
    /// section inside another pane rather than as their own settings
    /// extension. Verified against a live macOS 26 install: there is no
    /// General `.appex` at all (confirmed by testing every plausible
    /// identifier — `com.apple.systempreferences.GeneralSettings` and
    /// `com.apple.General-Settings.extension` both launch System
    /// Settings to an empty window, and the legacy
    /// `com.apple.preference.general` has been reassigned to Appearance).
    /// General is a container for About / Software Update / Storage /
    /// Sharing / Date & Time and friends, so "general settings" lands on
    /// About — the first item inside it, which puts the user in the right
    /// section rather than nowhere.
    private static let aliases: [String: String] = [
        "general": "About",
        "menu bar": "Control Center",
        "dock": "Desktop & Dock",
        "screen saver": "Wallpaper",
        "wallpaper background": "Wallpaper",
        "password": "Touch ID & Password",
        "touch id": "Touch ID & Password",
        "update": "Software Update",
        "software update": "Software Update",
        "vpn": "VPN",
        "printer": "Printers & Scanners",
        "scanner": "Printers & Scanners",
    ]

    /// A handful of entries whose `CFBundleDisplayName` is an internal/
    /// technical string rather than what a person would actually say —
    /// hand-corrected rather than guessed at with a generic heuristic,
    /// since there's no reliable pattern connecting e.g. "UsersGroups" to
    /// "Users & Groups". Keyed by bundle ID so a macOS update changing
    /// the raw display name doesn't silently break the mapping.
    private static let displayNameOverrides: [String: String] = [
        "com.apple.Accessibility-Settings.extension": "Accessibility",
        "com.apple.AirDrop-Handoff-Settings.extension": "AirDrop & Handoff",
        "com.apple.Battery-Settings.extension": "Battery",
        "com.apple.CD-DVD-Settings.extension": "CDs & DVDs",
        "com.apple.ControlCenter-Settings.extension": "Control Center",
        "com.apple.Date-Time-Settings.extension": "Date & Time",
        // Bundle display name is just "Desktop"; the real pane is
        // "Desktop & Dock", which is also how people ask for it.
        "com.apple.Desktop-Settings.extension": "Desktop & Dock",
        "com.apple.Focus-Settings.extension": "Focus",
        "com.apple.HeadphoneSettings": "Headphones",
        "com.apple.Internet-Accounts-Settings.extension": "Internet Accounts",
        "com.apple.Localization-Settings.extension": "Language & Region",
        "com.apple.Lock-Screen-Settings.extension": "Lock Screen",
        "com.apple.LoginItems-Settings.extension": "Login Items",
        "com.apple.Mouse-Settings.extension": "Mouse",
        "com.apple.Print-Scan-Settings.extension": "Printers & Scanners",
        "com.apple.settings.PrivacySecurity.extension": "Privacy & Security",
        // macOS 26 renamed this pane — confirmed live by reading the real
        // System Settings window title, which reads "Apple Intelligence &
        // Siri" rather than the bundle's older "Siri" display name.
        "com.apple.Siri-Settings.extension": "Apple Intelligence & Siri",
        "com.apple.Software-Update-Settings.extension": "Software Update",
        "com.apple.systempreferences.AppleIDSettings": "Apple Account",
        "com.apple.Time-Machine-Settings.extension": "Time Machine",
        "com.apple.Trackpad-Settings.extension": "Trackpad",
        "com.apple.Users-Groups-Settings.extension": "Users & Groups",
        "com.apple.wifi-settings-extension": "Wi-Fi",
    ]

    /// Genuinely not something anyone asks Sayline to open by voice —
    /// internal/administrative extension points that happen to share the
    /// Settings extension point but aren't real user-facing panes (e.g.
    /// School/ClassKit management panes, internal plugin-enablement
    /// bookkeeping). Confirmed by name against a live 2026-08-08 scan,
    /// not guessed — matches the "a few junk entries tolerated/tiny-
    /// denylisted" limit agreed in BACKLOG.md.
    private static let denylist: Set<String> = [
        "com.apple.ExtensionsSettings.DefaultExtensionEnablement",
        "com.apple.ExtensionsSettings.LegacyPluginEnablementExtension",
        "com.apple.fskit.ModuleEnablement",
        "com.apple.Coverage-Settings.extension",
        "com.apple.ClassKit-Settings.extension",
        "com.apple.Classroom-Settings.extension",
        "com.apple.FollowUpSettings.FollowUpSettingsExtension",
    ]

    private static func scan() -> [Pane] {
        let extensionsDir = "/System/Library/ExtensionKit/Extensions"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: extensionsDir) else {
            NSLog("Sayline: settings pane catalog scan failed — no panes available, open_system_setting will always fall back")
            return []
        }

        var results: [Pane] = []
        for entry in entries where entry.hasSuffix(".appex") {
            let plistPath = "\(extensionsDir)/\(entry)/Contents/Info.plist"
            guard let data = FileManager.default.contents(atPath: plistPath),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let bundleID = plist["CFBundleIdentifier"] as? String,
                  !denylist.contains(bundleID) else { continue }

            guard let pointID = extensionPointIdentifier(from: plist),
                  pointID.lowercased().contains("settings") else { continue }

            let rawName = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String) ?? bundleID
            let displayName = displayNameOverrides[bundleID] ?? cleaned(rawName)
            results.append(Pane(displayName: displayName, bundleID: bundleID))
        }
        return results.sorted { $0.displayName < $1.displayName }
    }

    /// Two schema variants found live across the 227 `.appex` bundles
    /// scanned on 2026-08-08: 77 use the older `NSExtension` key, 149 use
    /// the newer `EXAppExtensionAttributes` key. Checking only the first
    /// one (the initial verification pass) silently missed more than
    /// half the real entries — including every core pane already
    /// hardcoded before this rewrite (Privacy & Security, General/
    /// Appearance, Displays, Sound, Network, Users), which is why the
    /// old enum's 10 panes looked complete-ish despite the OS actually
    /// shipping 56.
    private static func extensionPointIdentifier(from plist: [String: Any]) -> String? {
        if let ns = plist["NSExtension"] as? [String: Any],
           let point = ns["NSExtensionPointIdentifier"] as? String {
            return point
        }
        if let ex = plist["EXAppExtensionAttributes"] as? [String: Any],
           let point = ex["EXExtensionPointIdentifier"] as? String {
            return point
        }
        return nil
    }

    /// Generic fallback for names not in `displayNameOverrides` — strips
    /// the common "...SettingsExtension"/"...Extension" noise suffix a
    /// few raw `CFBundleDisplayName` values carry. Only a safety net for
    /// panes Apple adds after this table was written; every currently-
    /// known offender already has an explicit override above.
    private static func cleaned(_ name: String) -> String {
        var result = name
        for suffix in ["SettingsExtension", "Extension"] {
            if result.hasSuffix(suffix) {
                result = String(result.dropLast(suffix.count))
                break
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
