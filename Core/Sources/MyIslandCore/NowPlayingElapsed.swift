/// Pure local elapsed-position interpolation and progress-fraction clamping (MEDIA-01/02, D-08).
/// No AppKit/Foundation-adapter types beyond `Date` — mirrors `CalendarEventFilter.swift`'s
/// convention of a pure, `Sendable`, unit-testable namespace with `now` always injected, never a
/// live clock call inside.
///
/// Spike 002 (05-01 evidence) observed that the adapter's persistent stream does NOT tick
/// per second: `elapsedTimeMicros` is a static snapshot per event, refreshed only when a new
/// event fires. Consumers must interpolate the current position locally from the snapshot's
/// `elapsedTimeMicros`, the wall-clock instant it was taken (`timestampEpochMicros`), and the
/// session's `playbackRate` — the formula RESEARCH.md's own code example already assumed.
import Foundation

public enum NowPlayingElapsed {
    /// Interpolates the current elapsed position, in microseconds, from the last-known snapshot.
    /// Returns `nil` when there is no elapsed value at all — a session with no `elapsedTimeMicros`
    /// has nothing to interpolate from. Returns the snapshot's elapsed value UNCHANGED (never
    /// interpolated) when the session is not playing, the playback rate is zero, or there is no
    /// timestamp to interpolate from — a paused or rate-less bar must not creep forward, and an
    /// absent timestamp leaves nothing to compute a delta against.
    public static func currentMicros(
        elapsedTimeMicros: Double?,
        timestampEpochMicros: Double?,
        playbackRate: Double,
        isPlaying: Bool,
        now: Date
    ) -> Double? {
        guard let elapsedTimeMicros else { return nil }
        guard isPlaying, playbackRate != 0, let timestampEpochMicros else {
            return elapsedTimeMicros
        }
        let nowMicros = now.timeIntervalSince1970 * 1_000_000
        let elapsedSinceUpdate = nowMicros - timestampEpochMicros
        return elapsedTimeMicros + elapsedSinceUpdate * playbackRate
    }

    /// The progress-bar fill fraction, clamped into the closed range 0...1. Returns `nil` when
    /// either input is missing or the duration is zero/negative — that `nil` is the caller's
    /// signal to omit the progress-bar row entirely (a live stream with no meaningful length)
    /// rather than render an indeterminate or zero-width bar. A payload whose elapsed position has
    /// drifted past its duration (or gone negative) clamps rather than overflows/inverts the bar.
    public static func fraction(elapsedMicros: Double?, durationMicros: Double?) -> Double? {
        guard let elapsedMicros, let durationMicros, durationMicros > 0 else { return nil }
        let raw = elapsedMicros / durationMicros
        return min(max(raw, 0), 1)
    }
}
