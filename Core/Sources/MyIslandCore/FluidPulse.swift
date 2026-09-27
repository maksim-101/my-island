import CoreGraphics
import Foundation

/// 07-04 Task 2 (PANEL-07 amended, agreement §6): the finished-timer pulse — three rings expanding
/// outward from the collapsed outline while its glow beats, ~3.2s in all, with no action and no
/// click target. Ported verbatim from `.planning/sketches/006-design-round/index.html:565-575`.
public enum FluidPulse {
    /// index.html:566 `e < 3.2` — the whole pulse window, in seconds since the timer finished.
    public static let duration: TimeInterval = 3.2

    /// One of the three outward-expanding rings at a given elapsed time — `nil` outside its own
    /// `0 ≤ k ≤ 1` window (index.html:568 `if (k < 0 || k > 1) continue`) or once `elapsed` has
    /// left the overall pulse window. `depth` is the collapsed outline's own current `d` (36 for
    /// the MacBook/desktop pill, 9 for the fullscreen bulge) — the ring's vertical scale flattens
    /// on the pill and stretches on the shallower bulge (index.html:569's `12 / max(9, P.d.x)`).
    public static func ring(n: Int, elapsed: TimeInterval, depth: CGFloat) -> (k: CGFloat, sx: CGFloat, sy: CGFloat, opacity: CGFloat, lineWidth: CGFloat)? {
        guard elapsed >= 0, elapsed < duration else { return nil }
        let k = (CGFloat(elapsed) - 0.45 - CGFloat(n) * 0.8) / 1.1
        guard k >= 0, k <= 1 else { return nil }
        let sx = 1 + 0.10 * k
        let sy = 1 + 0.9 * k * max(0.4, 12 / max(9, depth))
        let opacity = 0.85 * pow(1 - k, 1.5)
        let lineWidth = 1.6 / sx
        return (k: k, sx: sx, sy: sy, opacity: opacity, lineWidth: lineWidth)
    }

    /// The glow's beat opacity while the pulse runs (index.html:572-573) — a single half-sine
    /// pulse starting at `elapsed == 0.45`, period 0.8s, floor 0.2 (the glow channel's own idle
    /// opacity), peak 0.55. Not itself windowed by `duration` — callers only read this while
    /// `finishedAt` is set, which the timer clears exactly at `duration`.
    public static func glowBeat(elapsed: TimeInterval) -> CGFloat {
        let e = max(0, CGFloat(elapsed) - 0.45)
        let beat = max(0, sin(e * .pi / 0.8))
        return 0.2 + 0.35 * beat
    }
}
