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
        // Ask macOS to pull from CalDAV before reading.
        //
        // Google calendars reach EventKit through CalDAV, which Calendar.app
        // refreshes every 15 minutes by default. A meeting created or moved
        // in the last few minutes is therefore simply not here yet — the
        // user changed something, looked at Sayline, and saw stale truth.
        // This is best-effort and asynchronous: it does not block, and the
        // very next query may still miss. It costs nothing and shortens the
        // window over repeated use, which is the honest description of what
        // it buys.
        store.refreshSourcesIfNecessary()

        let started = Date()
        // Reaches back far enough to catch a long meeting already running,
        // which is the case someone running late actually needs.
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-4 * 3600),
            end: now.addingTimeInterval(window),
            calendars: nil
        )
        let events = store.events(matching: predicate)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let sources = store.calendars(for: .event)
            .map { $0.source?.title ?? "?" }
        let accounts = Set(sources).sorted().joined(separator: ", ")
        NSLog("%@", "Sayline: calendar query returned \(events.count) event(s) in \(elapsed)ms "
              + "from \(sources.count) calendar(s) [\(accounts.isEmpty ? "none" : accounts)]")

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
