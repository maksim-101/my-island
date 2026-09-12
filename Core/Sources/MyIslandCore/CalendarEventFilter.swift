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

/// Start/end pair for one surfaced event — the only shape the slot selector
/// needs, so no EventKit or app-layer type crosses into this pure logic.
public struct EventSlot: Equatable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

/// Picks which events own the Calendar slot (CAL-01).
///
/// A meeting that has already started must not hide the one coming up behind
/// it: `predicateForEvents(withStart:end:)` matches any event *overlapping* the
/// window, so a running 09:00–10:00 meeting sorts ahead of a 09:15 one and
/// would otherwise own the slot — and starve it of threshold bumps — for a
/// full hour.
///
/// The rule is purely about time, never about started-vs-upcoming: take the two
/// earliest events that haven't ended, and show the second only when it starts
/// before the first ends. That covers a running meeting plus an upcoming one
/// AND two meetings running concurrently — an earlier in-progress/upcoming
/// split silently dropped the concurrent case. A meeting running now plus one
/// tomorrow afternoon is not an overlap, and stays a single row.
public enum CalendarSlotSelector {
    public struct Selection: Equatable, Sendable {
        public let primary: Int?
        /// Non-nil only when it genuinely overlaps `primary`.
        public let secondary: Int?
    }

    /// `slots` is assumed sorted by start ascending (the caller's fetch already
    /// sorts). Indices refer back into that array.
    public static func select(slots: [EventSlot], now: Date) -> Selection {
        let live = slots.indices.filter { now < slots[$0].end }

        guard let primary = live.first else {
            return Selection(primary: nil, secondary: nil)
        }
        guard let candidate = live.dropFirst().first,
              slots[candidate].start < slots[primary].end else {
            return Selection(primary: primary, secondary: nil)
        }
        return Selection(primary: primary, secondary: candidate)
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

    /// Whether `remaining` (seconds until start; an already-started event reads <= 0) sits inside
    /// the meeting's own 15m/5m/1m bump window — the proximity test the synthetic pill's centre
    /// slot reuses instead of inventing a new cutoff (06-UI-SPEC.md "Centre slot decoupled from
    /// the timer", 2026-09-12 Amendment #2). An already-running meeting always qualifies, since
    /// "now" is the closest a meeting can be.
    public static func isWithinBumpWindow(remaining: TimeInterval) -> Bool {
        remaining <= (thresholds.max() ?? 0)
    }
}
