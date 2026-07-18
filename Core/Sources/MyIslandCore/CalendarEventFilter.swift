/// Pure attendance resolution and event-surfacing predicate for calendar events
/// (CAL-01). No EventKit import — the caller adapts a live `EKEvent` into these
/// plain, `Sendable` inputs at the actor boundary before calling.
///
/// All-day event exclusion is Assumption A1 (default: exclude, pending user
/// confirmation) — see .planning/phases/04-calendar/04-RESEARCH.md Assumptions Log.
///
/// Source: .planning/phases/04-calendar/04-RESEARCH.md Pattern 2.
import Foundation

public enum CalendarEventFilter {
    /// Plain-data mirror of EKParticipantStatus + the organizer/attendee resolution —
    /// intentionally decoupled from EventKit types so it's unit-testable.
    public enum AttendanceStatus: Sendable {
        case accepted, declined, tentative, other
    }

    public static func resolvedAttendance(isOrganizer: Bool, hasAttendees: Bool, currentUserStatus: AttendanceStatus?) -> AttendanceStatus {
        if isOrganizer { return .accepted }
        if let currentUserStatus { return currentUserStatus }
        // No organizer flag, no attendee entry for the current user → personal/solo
        // event on the user's own calendar (reminder, appointment) → implicitly accepted.
        return .accepted
    }

    public static func shouldSurface(isCancelled: Bool, isAllDay: Bool, attendance: AttendanceStatus) -> Bool {
        if isCancelled { return false }
        if isAllDay { return false }   // ASSUMED — see Assumptions Log A1
        if attendance == .declined || attendance == .tentative { return false }
        return true
    }
}

/// Pure threshold-bump scheduler for the 15m/5m/1m meeting-countdown bump (CAL-01).
/// `now` is always an injected parameter — no live-clock calls inside — so a
/// just-launched app never fires a threshold that's already in the past.
///
/// Source: .planning/phases/04-calendar/04-RESEARCH.md Pattern 3.
public struct ThresholdScheduler {
    public static let thresholds: [TimeInterval] = [15 * 60, 5 * 60, 60]   // 15m, 5m, 1m before start

    /// Returns only the thresholds that are still in the future relative to `now`,
    /// as absolute fire dates, so a just-launched app doesn't fire a "15m" bump
    /// for a meeting that's actually 10 minutes away.
    public static func pendingFireDates(eventStart: Date, now: Date) -> [Date] {
        thresholds
            .map { eventStart.addingTimeInterval(-$0) }
            .filter { $0 > now }
            .sorted()
    }
}
