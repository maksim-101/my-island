import Foundation

public enum RelativeTimeRounding: Sendable {
    case floor, nearest
}

/// One shared "time until an event" formatter (06-UI-SPEC.md "Format Contract — Relative Time",
/// 2026-09-12 Amendment #2) replacing three independent, disagreeing implementations
/// (`CalendarProvider.computeCountdowns`, `CalendarProvider.fireThreshold`,
/// `CockpitTileStripView.compactCountdown`). Hours by default, switching to minutes at <= 60
/// minutes remaining, "now" at/below zero.
///
/// `.nearest` applies ONLY inside the minutes branch — `fireThreshold` passes it to compensate for
/// timer-fire jitter around a one-shot 15m/5m/1m threshold bump (a bump fired a fraction of a
/// second late must not read "14m" at the exact 15-minute mark). Since
/// `ThresholdScheduler.thresholds` are all <= 900s (15m), `.nearest` never touches the hours branch
/// and needs no reconciliation with it — the hours branch always floors. Every other,
/// continuously-ticking consumer passes `.floor`.
public enum RelativeTimeFormat {
    public static func string(remaining: TimeInterval, rounding: RelativeTimeRounding) -> String {
        if remaining <= 0 { return "now" }
        if remaining <= 3600 {
            let minutes: Int
            switch rounding {
            case .floor: minutes = Int(remaining / 60)
            case .nearest: minutes = max(1, Int((remaining / 60).rounded()))
            }
            return "\(minutes)m"
        }
        let hours = Int(remaining / 3600)   // always floors — no fractional hours, no .nearest here
        return "\(hours)h"
    }
}
