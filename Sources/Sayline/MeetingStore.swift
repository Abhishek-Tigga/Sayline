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
        NSLog("Sayline: calendar query returned \(events.count) event(s) in \(elapsed)ms")

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
