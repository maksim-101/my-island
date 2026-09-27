import Foundation

/// Per-local-day session count and total seconds for the Timer droplet's "Today" filler row
/// (07-DESIGN-AGREEMENT.md §9). Persisted as JSON by `TimerViewModel` under
/// `com.myisland.timerToday` — a hand-edited or otherwise undecodable stored value must read back
/// as an empty total rather than crash (T-07-05); `total(on:calendar:)` also rolls over silently
/// once the stored `day` no longer matches "today," with no separate reset step needed.
public struct DailyTimerTotal: Codable, Equatable, Sendable {
    public private(set) var day: String
    public private(set) var sessions: Int
    public private(set) var seconds: TimeInterval

    public init(day: String = "", sessions: Int = 0, seconds: TimeInterval = 0) {
        self.day = day
        self.sessions = sessions
        self.seconds = seconds
    }

    /// A local "yyyy-MM-dd" key derived from `calendar`'s own year/month/day components — never
    /// UTC-normalized, so a session recorded near local midnight lands on the day the user
    /// actually experienced it on.
    public static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return ""
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Adds one completed session. Resets `sessions`/`seconds` to zero first when `date` falls on
    /// a different local day than the one already stored — the rollover this type exists for.
    public mutating func record(duration: TimeInterval, at date: Date, calendar: Calendar) {
        let key = Self.dayKey(for: date, calendar: calendar)
        if key != day {
            day = key
            sessions = 0
            seconds = 0
        }
        sessions += 1
        seconds += duration
    }

    /// The stored total, but only when `date` falls on the same local day as the one already
    /// recorded — any other day reads as zero rather than a stale prior day's numbers.
    public func total(on date: Date, calendar: Calendar) -> (sessions: Int, seconds: TimeInterval) {
        guard Self.dayKey(for: date, calendar: calendar) == day else { return (0, 0) }
        return (sessions, seconds)
    }
}
