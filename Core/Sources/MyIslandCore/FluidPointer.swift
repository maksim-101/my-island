import CoreGraphics

/// D-04 collapsed hover behavior, ported (07-DESIGN-AGREEMENT.md §11) from the sketch's frame-loop
/// branch for `!st.open` (`.planning/sketches/006-design-round/index.html:510-524`): whether the
/// pointer sits inside the dwell-to-open target, and the sticky pull/lean the collapsed pill's
/// belly and lean channels chase toward. Pure CoreGraphics, no AppKit/SwiftUI import — same
/// convention as `FluidShapeGeometry`/`FluidSpring`.
public enum FluidPointer {
    /// Only the upper two-thirds of a collapsed surface's depth starts the hover dwell, so a pointer passing just under the notch (a maximized window's tab bar) cannot open it (quick 261004-ah2).
    public static let hoverTriggerDepthFraction: CGFloat = 2.0 / 3.0

    /// The trigger band's depth for `q`, measured top-down from the anchor's top edge; the App sizes its tracking area from the same value.
    public static func triggerDepth(q: FluidParams) -> CGFloat {
        q.d * hoverTriggerDepthFraction
    }

    /// The pointer must sit inside the half-width band and above `triggerDepth(q:)` (the upper
    /// two-thirds of `q.d`; quick 261004-ah2 dropped the sketch's 8 pt below-pill slack from the
    /// dwell decision). The meeting-bump guard (`onBump`) is folded in as an optional `alertTop`:
    /// resting on the alert drop's own content (`p.y > alertTop − 2`) must never register as a
    /// dwell target, even when the base band would otherwise say yes.
    public static func isDwellTarget(pointer: CGPoint, cx: CGFloat, q: FluidParams, alertTop: CGFloat? = nil) -> Bool {
        let base = abs(pointer.x - cx) < q.half && pointer.y < triggerDepth(q: q)
        if let alertTop, pointer.y > alertTop - 2 {
            return false
        }
        return base
    }

    /// Ported verbatim from index.html:512-519. `reach` grows with `q.half` so a wider pill (the
    /// Dell's desktop pill) reaches a touch further than the MacBook's; `f` is the falloff from
    /// reach, `inside` is the sketch's full band, half-width and down to 8 pt below the
    /// pill's depth, deliberately wider than `isDwellTarget`'s trigger band so the visual pull still
    /// answers a pointer the dwell ignores, and it has no alert concept. `damped` scales both terms by 0.3, exactly
    /// the sketch's `if (st.extra){ pull *= .3; lean *= .3; }`.
    public static func stickyPull(pointer: CGPoint?, cx: CGFloat, q: FluidParams, damped: Bool) -> (pull: CGFloat, lean: CGFloat) {
        guard let pointer else { return (0, 0) }
        let dx = pointer.x - cx
        let dy = max(0, pointer.y - q.d)
        let reach = 80 + q.half * 0.5
        let f = max(0, 1 - hypot(dx * 0.6, dy) / reach)
        let inside = abs(dx) < q.half && pointer.y < q.d + 8
        var pull = FluidTiming.pull * (inside ? 1.2 : f * f)
        var lean = max(-1, min(1, dx / q.half)) * 12 * f
        if damped {
            pull *= 0.3
            lean *= 0.3
        }
        return (pull, lean)
    }
}
