import CoreGraphics

/// D-06 Wave 2 (PANEL-04): the band's cell row, one detail droplet's placement, and the pointer
/// rules that open/close it. Ported per D-02 from `.planning/sketches/006-design-round/index.html`
/// `bandFrame`/`cells`/`setHot`/`cellAt`/`inDrop` and the pointer branch of `frame()`
/// (lines 316-320, 355-368, 439-449, 525-534) — no AppKit/SwiftUI import, unrounded CGFloat
/// throughout (07-DESIGN-AGREEMENT.md §1, §3).
///
/// RED-phase stub: signatures are final, bodies are placeholders that intentionally fail the
/// behavior tests (`BandLayoutTests.swift`).
public struct BandLayout {
    public let moduleCount: Int
    public let contentTop: CGFloat
    public let cx: CGFloat

    /// `FluidParams.band(moduleCount:contentTop:)` — the band's own outline parameters.
    public let params: FluidParams
    /// `FluidShapeGeometry.frameOf(params, cx:)` — the band's inner content frame (`x0`, `x1`, `d`, …).
    public let frame: FluidFrame

    /// index.html:318 `cells().x` — `frame.x0 + 6`.
    public let cellsX: CGFloat
    /// index.html:318 `cells().w` — `frame.x1 - frame.x0 - 12`.
    public let cellsWidth: CGFloat
    /// index.html:318 `cells().cw` — `cellsWidth / n`.
    public let cellWidth: CGFloat
    /// index.html:319 `cells().centers` — one centre per enabled module, fixed order.
    public let centers: [CGFloat]
    /// index.html:319 `cells().half` — `(frame.x1 - frame.x0) / 2`, the droplet's own clamp bound.
    public let halfContent: CGFloat

    public init(moduleCount: Int, contentTop: CGFloat, cx: CGFloat = 0) {
        self.moduleCount = moduleCount
        self.contentTop = contentTop
        self.cx = cx
        let params = FluidParams.band(moduleCount: moduleCount, contentTop: contentTop)
        self.params = params
        self.frame = FluidShapeGeometry.frameOf(params, cx: cx)
        self.cellsX = 0
        self.cellsWidth = 0
        self.cellWidth = 0
        self.centers = []
        self.halfContent = 0
    }

    /// index.html:355-362 `DROP_W`/`setHot`'s `mx`/`lim` — outer modules continue the band's own
    /// end curve (agreement §3), a middle module's droplet clamps to stay inside the band.
    public func droplet(forCell cell: Int, halfWidth: CGFloat) -> (mx: CGFloat, m: CGFloat, s2: CGFloat, dip: CGFloat) {
        (0, 0, 0, 0)
    }

    /// index.html:439-444 `cellAt` — the pointer-to-cell hit test; `nil` outside the cell row.
    public func cellAt(_ p: CGPoint) -> Int? {
        nil
    }

    /// index.html:529 `inBand` inline expression.
    public func inBand(_ p: CGPoint, currentHalf: CGFloat) -> Bool {
        false
    }

    /// index.html:445-448 `inDrop`.
    public func inDroplet(_ p: CGPoint, mx: CGFloat, m: CGFloat, s2: CGFloat, dip: CGFloat) -> Bool {
        false
    }

    /// index.html:525-534, the `!inBand && !inDrop(p)` branch — three outcomes: stay, close the
    /// droplet first (unpinned, still near the band), or close the whole band.
    public func pointerOutside(
        _ p: CGPoint,
        currentHalf: CGFloat,
        droplet: (mx: CGFloat, m: CGFloat, s2: CGFloat, dip: CGFloat)?,
        pinned: Bool
    ) -> BandPointerAction {
        .stay
    }
}

/// index.html:530-534 outcomes — `BandLayout.pointerOutside`'s result.
public enum BandPointerAction: Equatable {
    case stay
    case closeDroplet
    case closeBand
}
