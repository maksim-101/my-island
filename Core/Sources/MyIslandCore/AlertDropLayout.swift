import CoreGraphics

/// D-02: the HUD/alert drop's own rest sizes, ported verbatim from the sketch's `extraSize`/
/// `bumpHalf` (`.planning/sketches/006-design-round/index.html:376-389`). Widths are INPUTS here —
/// the App layer measures rendered text (`NSFont`) and passes the result in — so this stays
/// font-free, pure `CoreGraphics`, no AppKit/SwiftUI import, matching every other `MyIslandCore`
/// geometry enum's convention.
public enum AlertDropLayout {
    /// Ported from `extraSize('hud')` (index.html:386): `{ h: 22, w: st.display === 'builtin' ? 80
    /// : 70 }`. 07-DESIGN-AGREEMENT.md §6: 160pt (MacBook) / 140pt (Dell) wide, 22pt deep —
    /// half-width is half of that.
    public static func hud(isPhysical: Bool) -> (halfWidth: CGFloat, height: CGFloat) {
        (isPhysical ? 80 : 70, 22)
    }

    /// Ported from `bumpHalf`/`extraSize('bump')` (index.html:381-388): the meeting alert's width
    /// follows its own title instead of scrolling it — `leadWidth`/`titleWidth` are the App's own
    /// `NSFont`-measured rendered widths for the "{N}m " lead and the title, passed in already
    /// measured so this function stays pure arithmetic.
    public static func meeting(leadWidth: CGFloat, titleWidth: CGFloat, hasJoin: Bool, isPhysical: Bool) -> (halfWidth: CGFloat, height: CGFloat, twoLines: Bool) {
        let inner = 8 + 13 + 7 + leadWidth + titleWidth + (hasJoin ? 7 + 42 : 0) + 12
        let minimum: CGFloat = isPhysical ? 100 : 90
        let halfWidth = max(minimum, min(210, inner / 2))
        let twoLines = halfWidth >= 210 && titleWidth > 420 - 110
        let height: CGFloat = twoLines ? 44 : 30
        return (halfWidth, height, twoLines)
    }
}
