/// Pure marquee schedule for one restrained, repeating horizontal pass over an overflowing
/// single-line text run (G-05-5). Mirrors `NowPlayingElapsed.swift`'s convention: a public,
/// Sendable, side-effect-free namespace with elapsed time always injected by the caller — this
/// file never reads a live clock and depends on nothing but CoreGraphics (for `CGFloat`, as
/// `NotchGeometry.swift` already does). The panel's `ScrollingTrackText` view drives this; this
/// file decides no UI.
///
/// Cycle: hold at the start (`startHoldSeconds`), walk left to reveal the end at a constant
/// `pointsPerSecond` rate clamped into `minScrollSeconds...maxScrollSeconds`, hold at the end
/// (`endHoldSeconds`), then return to the start at twice the scroll-out rate (floored at 0.4s so
/// a small overflow never snaps back instantaneously). Rate-based rather than fixed-duration
/// timing is deliberate: a fixed-duration pass (the removed ear component's approach, see
/// `git show d08cffe`) whips a very long title past illegibly and crawls through a
/// barely-overflowing one; a constant rate reads at the same speed regardless of length, and the
/// clamp bounds the cycle for pathological inputs.
import CoreGraphics

public enum MarqueePass {
    /// The hostile-metadata cap (T-05-07): a string longer than this contributes nothing but
    /// unbounded measurement/layout cost, since the viewport only ever reveals a couple hundred
    /// points of text.
    public static let maxCharacters = 300
    public static let startHoldSeconds: Double = 1.5
    public static let endHoldSeconds: Double = 2
    public static let pointsPerSecond: Double = 30
    public static let minScrollSeconds: Double = 2
    public static let maxScrollSeconds: Double = 12

    /// Caps `text` at `maxCharacters`, unchanged if already within bounds.
    public static func bounded(_ text: String) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters))
    }

    /// The horizontal distance the text run must travel to reveal its end: 0 when it already fits
    /// (or the viewport hasn't been measured yet — a non-positive width), otherwise the positive
    /// difference.
    public static func overflow(textWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        guard viewportWidth > 0, textWidth > viewportWidth else { return 0 }
        return textWidth - viewportWidth
    }

    /// Scroll-out duration at the constant `pointsPerSecond` rate, clamped so a barely-overflowing
    /// line doesn't crawl and a pathologically long one doesn't run forever.
    public static func scrollSeconds(overflow: CGFloat) -> Double {
        let raw = Double(overflow) / pointsPerSecond
        return min(max(raw, minScrollSeconds), maxScrollSeconds)
    }

    /// The return leg travels the same distance at twice the scroll-out's (possibly clamped) rate
    /// — half its duration — floored at 0.4s so a small overflow never snaps back instantaneously.
    public static func returnSeconds(overflow: CGFloat) -> Double {
        max(scrollSeconds(overflow: overflow) / 2, 0.4)
    }

    /// The full hold/scroll/hold/return cycle length. 0 for a non-positive overflow — `offset`
    /// never calls this with one (it guards first), but the function stays total rather than
    /// partial.
    public static func cycleSeconds(overflow: CGFloat) -> Double {
        guard overflow > 0 else { return 0 }
        return startHoldSeconds + scrollSeconds(overflow: overflow) + endHoldSeconds + returnSeconds(overflow: overflow)
    }

    /// The horizontal offset to apply at `elapsed` seconds into a track's display. Guarded at the
    /// top so a non-positive overflow, a negative elapsed value, or a degenerate cycle length can
    /// never produce a division by zero or a non-finite result — by construction, not by the
    /// caller's care.
    public static func offset(overflow: CGFloat, elapsed: Double) -> CGFloat {
        guard overflow > 0, elapsed >= 0 else { return 0 }
        let cycle = cycleSeconds(overflow: overflow)
        guard cycle > 0 else { return 0 }

        let t = elapsed.truncatingRemainder(dividingBy: cycle)
        let scrollOut = scrollSeconds(overflow: overflow)
        let holdEndStart = startHoldSeconds + scrollOut
        let returnStart = holdEndStart + endHoldSeconds
        let returnDuration = returnSeconds(overflow: overflow)

        if t < startHoldSeconds {
            return 0
        } else if t < holdEndStart {
            let fraction = (t - startHoldSeconds) / scrollOut
            return -overflow * CGFloat(fraction)
        } else if t < returnStart {
            return -overflow
        } else {
            let fraction = (t - returnStart) / returnDuration
            return -overflow + overflow * CGFloat(fraction)
        }
    }
}
