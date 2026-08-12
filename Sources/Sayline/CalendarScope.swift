import Foundation

/// Which calendar accounts Sayline is allowed to read.
///
/// Someone with a work Gmail, a personal Gmail and an iCloud account does
/// not want "join my next meeting" reaching into all three. Scoping is by
/// *account* rather than by calendar because that is how the need was
/// described — "only my work email" — and because a real Mac here carries
/// 14 calendars across 4 sources, which is not a list anyone wants to tick
/// through while being onboarded.
///
/// Stored as `EKSource.sourceIdentifier`, never as the account name.
/// Renaming an account in System Settings would otherwise silently
/// un-choose it, and the symptom — meetings quietly disappearing — is the
/// exact class of failure this feature spent a day removing.
///
/// `nil` means every account, which is deliberately the default. A scoped
/// default silently misses meetings; over-including shows one you did not
/// want, which is visible and fixable. Wrong in the direction you can see.
enum CalendarScope {
    private static let selectedKey = "com.abhishektigga.sayline.calendarScope"
    private static let knownKey = "com.abhishektigga.sayline.knownCalendarSources"

    /// Chosen account identifiers, or nil for all of them.
    static var selected: Set<String>? {
        get {
            guard let stored = UserDefaults.standard.array(forKey: selectedKey) as? [String] else {
                return nil
            }
            // An empty stored set would mean "read nothing", which is never
            // what anyone means — see `select`, which refuses to write one.
            return stored.isEmpty ? nil : Set(stored)
        }
        set {
            guard let newValue, !newValue.isEmpty else {
                UserDefaults.standard.removeObject(forKey: selectedKey)
                return
            }
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: selectedKey)
        }
    }

    static var isNarrowed: Bool { selected != nil }

    static func isSelected(_ sourceIdentifier: String) -> Bool {
        selected?.contains(sourceIdentifier) ?? true
    }

    /// Turns one account on or off.
    ///
    /// Refuses to leave nothing selected. Deselecting the last account is
    /// always a slip — the meaning intended was "not that one", and there
    /// is nothing left to mean it with. Returns false when the change was
    /// rejected, so the caller can say why.
    @discardableResult
    static func set(_ sourceIdentifier: String, enabled: Bool, allKnown: [String]) -> Bool {
        var current = selected ?? Set(allKnown)
        if enabled {
            current.insert(sourceIdentifier)
        } else {
            guard current.count > 1 else { return false }
            current.remove(sourceIdentifier)
        }
        // Back to nil when everything is on, so "all" stays the same state
        // whether it was never changed or changed back.
        selected = current.count == allKnown.count ? nil : current
        return true
    }

    // MARK: - Accounts added later

    /// Accounts seen before. An account absent from this list is new since
    /// the last look.
    static var knownSources: Set<String> {
        get { Set(UserDefaults.standard.array(forKey: knownKey) as? [String] ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: knownKey) }
    }

    /// Records what exists now and reports what is new.
    ///
    /// A new account is included rather than excluded. Excluding it would
    /// mean someone adds their work account and Sayline ignores it with no
    /// explanation, which is the silent-wrongness this feature exists to
    /// end; including it can surface a meeting they did not want, which
    /// they will see and can turn off.
    static func noteSources(_ identifiers: [String]) -> [String] {
        let seen = knownSources
        let fresh = identifiers.filter { !seen.contains($0) }
        knownSources = seen.union(identifiers)

        // Only worth announcing once the user has actually narrowed the
        // scope. Before that "everything is included" is not news.
        guard isNarrowed, !seen.isEmpty else { return [] }
        if var current = selected {
            current.formUnion(fresh)
            selected = current
        }
        return fresh
    }
}
