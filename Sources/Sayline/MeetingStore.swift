import EventKit
import Foundation

/// Calendar access, and nothing else.
///
/// The only file in the meetings feature that imports EventKit. Everything
/// that decides — which meeting is next, which URL is a join link — lives
/// in `Meeting.swift` and `MeetingLink.swift`, which compile without
/// frameworks and therefore have a check suite. This file is deliberately
/// too thin to hide a decision.
///
/// Its own `EKEventStore` rather than sharing the reminders one: calendar
/// and reminders are separate TCC grants with separate request calls, the
/// two share no state worth sharing, and two small stores that each mirror
/// a proven shape beat one store carrying two permission lifecycles.
/// One calendar provider, and which of its accounts are on this Mac.
struct ConnectedAccount: Equatable, Identifiable {
    /// `EKSource.sourceIdentifier` — stable across renames, unlike the
    /// title, which is what a person edits in System Settings.
    let id: String
    let provider: String
    let addresses: [String]
    var isSelected: Bool

    /// "Google · a@gmail.com", or just the provider when EventKit exposed
    /// no address for it.
    var label: String {
        addresses.isEmpty ? provider : "\(provider) · \(addresses.joined(separator: ", "))"
    }
}

enum CalendarAccess: Equatable {
    case granted
    /// Refused or restricted. Both are dead ends from code — macOS will not
    /// show the prompt again.
    case denied
    case failed(String)
}

final class MeetingStore {
    private let store = EKEventStore()

    var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Asks only when macOS would actually show the prompt.
    ///
    /// Full access to *read*, because macOS 14 offers no read-only grant
    /// for events. Sayline never writes — creating events by voice is out
    /// of scope by an explicit design decision, since a misheard word
    /// becomes a real event other people see. The Info.plist usage string
    /// says so, because that string is what the system dialog shows and it
    /// is the only place the explanation reaches the person deciding.
    func requestAccess() async -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return .granted
        case .denied, .restricted, .writeOnly:
            return .denied
        default:
            do {
                let granted = try await store.requestFullAccessToEvents()
                return granted ? .granted : .denied
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    /// The accounts supplying event calendars, with their addresses.
    ///
    /// `EKSource.title` is only ever the provider — "Google", "iCloud" —
    /// which is not enough to answer the question someone actually has:
    /// *which* of my accounts is connected. With two Gmail addresses,
    /// "Google" tells you nothing about whether the right one is here.
    ///
    /// The addresses come from calendar titles. Google names a person's
    /// primary calendar after their email, so an "@" in a calendar title
    /// inside a Google source is the account. Heuristic rather than an API,
    /// because EventKit exposes no account address — so an empty address
    /// list degrades to just the provider name rather than to nothing.
    func connectedAccounts() -> [ConnectedAccount] {
        let calendars = store.calendars(for: .event)
            .filter { $0.type != .birthday && $0.type != .subscription }

        #if DEBUG
        SaylineLog.log("[accounts] raw calendars: "
            + calendars.map { "\($0.source?.title ?? "?")/\($0.title)" }.joined(separator: ", "))
        #endif

        var addressesBySource: [String: (provider: String, addresses: Set<String>)] = [:]
        for calendar in calendars {
            guard let source = calendar.source else { continue }
            var entry = addressesBySource[source.sourceIdentifier]
                ?? (provider: source.title, addresses: [])
            if calendar.title.contains("@") { entry.addresses.insert(calendar.title) }
            addressesBySource[source.sourceIdentifier] = entry
        }
        return addressesBySource
            .map { id, entry in
                ConnectedAccount(id: id, provider: entry.provider,
                                 addresses: entry.addresses.sorted(),
                                 isSelected: CalendarScope.isSelected(id))
            }
            .sorted { $0.provider < $1.provider }
    }

    /// The calendars a query may read, honouring the account scope.
    ///
    /// Returns nil for "everything", which is what `predicateForEvents`
    /// wants when nothing is narrowed — passing an explicit list of all of
    /// them would behave the same but hide the distinction.
    private func scopedCalendars() -> [EKCalendar]? {
        guard CalendarScope.isNarrowed else { return nil }
        let allowed = store.calendars(for: .event)
            .filter { calendar in
                guard let id = calendar.source?.sourceIdentifier else { return false }
                return CalendarScope.isSelected(id)
            }
        // Never let a scope produce an empty query — that reads as "no
        // meetings" and is indistinguishable from a broken setup.
        return allowed.isEmpty ? nil : allowed
    }

    /// New accounts since the last look, having recorded what exists now.
    @discardableResult
    func noteNewAccounts() -> [ConnectedAccount] {
        let accounts = connectedAccounts()
        let freshIDs = Set(CalendarScope.noteSources(accounts.map(\.id)))
        return accounts.filter { freshIDs.contains($0.id) }
    }

    /// Why an empty result was empty.
    ///
    /// "No meetings" and "your calendar was never connected" look identical
    /// from the outside and need completely different sentences. Found live
    /// 2026-08-11: a user's Google Calendar was not in macOS at all, so
    /// every query returned nothing while the meeting sat plainly visible
    /// in their browser. That reads as a broken app, not a setup gap.
    enum Emptiness: Equatable {
        /// No calendar accounts at all, or none with event calendars.
        case noCalendarsConfigured
        /// Calendars exist and nothing is scheduled in the window. Ordinary.
        case nothingScheduled
        /// Calendars exist and hold no events for a whole day either side.
        /// Not proof of a sync problem, but the shape of one.
        case suspiciouslyEmpty
    }

    /// Whether any account is actually supplying event calendars.
    func diagnoseEmptiness(around now: Date) -> Emptiness {
        let calendars = store.calendars(for: .event)
        guard !calendars.isEmpty else { return .noCalendarsConfigured }

        // Only calendars a person actually schedules into. Birthdays and
        // subscribed holiday feeds almost always hold something within a
        // day, so probing everything answered "nothingScheduled" for the
        // exact case this diagnosis exists for — a Google account absent
        // from macOS, with the meeting sitting visible in a browser tab.
        let scheduled = calendars.filter {
            $0.type != .birthday && $0.type != .subscription
                && CalendarScope.isSelected($0.source?.sourceIdentifier ?? "")
        }
        guard !scheduled.isEmpty else { return .noCalendarsConfigured }

        let dayPredicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-24 * 3600),
            end: now.addingTimeInterval(24 * 3600),
            calendars: scheduled
        )
        return store.events(matching: dayPredicate).isEmpty ? .suspiciouslyEmpty : .nothingScheduled
    }

    /// Events overlapping the window, as `Meeting` values.
    ///
    /// Every calendar, no picker — the design's filter is "has a join
    /// link", applied by the selection logic rather than by configuration.
    /// A holiday calendar contributes events that simply never win a join.
    ///
    /// Timed, because EventKit is blocking cross-process IPC in a pipeline
    /// with an unexplained freeze in its history. If a stall ever coincides
    /// with a calendar query, the log will say so in one line rather than
    /// leaving the next investigation to guess.
    func meetings(around now: Date,
                  window: TimeInterval = MeetingSelection.defaultWindow) async -> [Meeting] {
        // Kept, but MEASURED NOT TO WORK — do not rely on it.
        //
        // Shipped on the reading that Apple's docs describe this as pulling
        // from remote sources when needed. Tested live on 2026-08-11 with
        // the account's refresh interval set back to 15 minutes so macOS's
        // own timer could not be mistaken for this call: an event was
        // renamed and another added in Google's web UI, and four queries
        // over 83 seconds returned byte-identical results, with every
        // `lastModifiedDate` frozen more than twelve minutes in the past.
        // Nothing propagated.
        //
        // So "if necessary" is exactly what it says, and the system decides
        // — not us. The call stays because it is one line, costs nothing,
        // and Apple's behaviour may change; the comment is the part that
        // matters, so nobody reads this as a working freshness mechanism
        // and builds on it.
        //
        // What actually mitigates staleness today is the user setting
        // Calendar → Settings → Accounts → Refresh Calendars to "Every
        // minute". That sentence is in the empty-calendar notice.
        store.refreshSourcesIfNecessary()

        let started = Date()
        // Reaches back far enough to catch a long meeting already running,
        // which is the case someone running late actually needs.
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-4 * 3600),
            end: now.addingTimeInterval(window),
            calendars: scopedCalendars()
        )
        let events = store.events(matching: predicate)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let sources = store.calendars(for: .event)
            .map { $0.source?.title ?? "?" }
        let accounts = Set(sources).sorted().joined(separator: ", ")
        SaylineLog.log("calendar query returned \(events.count) event(s) in \(elapsed)ms "
              + "from \(sources.count) calendar(s) [\(accounts.isEmpty ? "none" : accounts)]")

        // Titles and last-modified, because a count cannot show staleness.
        // The 2026-08-11 refresh test was inconclusive for exactly this
        // reason: a rename does not change how many events there are, so
        // four queries logged an identical line while the user watched a
        // stale title on screen. `lastModifiedDate` is what settles it —
        // if an edit made minutes ago is not reflected there, the local
        // store has not pulled, whatever else is true.
        for event in events {
            let modified = event.lastModifiedDate.map { Self.stamp.string(from: $0) } ?? "?"
            SaylineLog.log("  · \"\(event.title ?? "")\" "
                  + "starts \(Self.stamp.string(from: event.startDate)) "
                  + "modified \(modified) [\(event.calendar.source?.title ?? "?")]")
        }

        return events.compactMap { event in
            guard let start = event.startDate, let end = event.endDate else { return nil }
            return Meeting(
                title: event.title ?? "",
                start: start,
                end: end,
                // The one place event text is inspected. After this, nothing
                // downstream sees notes or location at all.
                joinURL: MeetingLink.extract(url: event.url,
                                             location: event.location,
                                             notes: event.notes),
                isAccepted: Self.isAccepted(event)
            )
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Whether the user said yes. Only used to break a tie between two
    /// meetings starting in the same minute, so "unknown" counts as no.
    private static func isAccepted(_ event: EKEvent) -> Bool {
        guard let attendees = event.attendees else {
            // No attendee list at all usually means an event they made
            // themselves, which is as accepted as it gets.
            return true
        }
        guard let me = attendees.first(where: { $0.isCurrentUser }) else { return false }
        return me.participantStatus == .accepted
    }
}
