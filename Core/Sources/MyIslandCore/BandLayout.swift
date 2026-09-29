import CoreGraphics

/// D-06 Wave 2 (PANEL-04): the band's cell row, one detail droplet's placement, and the pointer
/// rules that open/close it. Ported per D-02 from `.planning/sketches/006-design-round/index.html`
/// `bandFrame`/`cells`/`setHot`/`cellAt`/`inDrop` and the pointer branch of `frame()`
/// (lines 316-320, 355-368, 439-449, 525-534) — no AppKit/SwiftUI import, unrounded CGFloat
/// throughout (07-DESIGN-AGREEMENT.md §1, §3).
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

    private var n: Int { max(1, moduleCount) }

    public init(moduleCount: Int, contentTop: CGFloat, cx: CGFloat = 0) {
        self.moduleCount = moduleCount
        self.contentTop = contentTop
        self.cx = cx
        let params = FluidParams.band(moduleCount: moduleCount, contentTop: contentTop)
        self.params = params
        let frame = FluidShapeGeometry.frameOf(params, cx: cx)
        self.frame = frame
        let count = max(1, moduleCount)
        let cellsX = frame.x0 + 6
        let cellsWidth = frame.x1 - frame.x0 - 12
        let cellWidth = cellsWidth / CGFloat(count)
        self.cellsX = cellsX
        self.cellsWidth = cellsWidth
        self.cellWidth = cellWidth
        self.halfContent = (frame.x1 - frame.x0) / 2
        self.centers = (0..<count).map { cellsX + cellWidth * (CGFloat($0) + 0.5) }
    }

    /// index.html:355-362 `DROP_W`/`setHot`'s `lim` — every module's droplet, edge cells included,
    /// clamps so its whole flank ends inside the band. The sketch let outer droplets continue the
    /// band's end curve (agreement §3), which dragged the band's own shoulder down with them and
    /// visibly changed the band's width whenever an edge droplet opened; clamping keeps the band's
    /// walls identical whether or not a droplet is showing.
    public func droplet(forCell cell: Int, halfWidth: CGFloat) -> (mx: CGFloat, m: CGFloat, s2: CGFloat, dip: CGFloat) {
        let s2 = FluidShapeGeometry.dropletFlank
        let dip = FluidShapeGeometry.dropletHeight
        let lim = max(0, halfContent - halfWidth - s2 - 26)
        let mx = n == 1 ? 0 : max(-lim, min(lim, centers[cell] - cx))
        return (mx, halfWidth, s2, dip)
    }

    /// index.html:439-444 `cellAt` — the pointer-to-cell hit test; `nil` outside the cell row.
    public func cellAt(_ p: CGPoint) -> Int? {
        if p.y < contentTop - 6 || p.y > frame.d + 4 { return nil }
        if p.x < cellsX || p.x > cellsX + cellsWidth { return nil }
        let idx = Int(floor((p.x - cellsX) / cellWidth))
        return min(n - 1, max(0, idx))
    }

    /// index.html:529 `inBand` inline expression.
    public func inBand(_ p: CGPoint, currentHalf: CGFloat) -> Bool {
        abs(p.x - cx) < currentHalf + 8 && p.y < frame.d + params.sag + 6
    }

    /// index.html:445-448 `inDrop`.
    public func inDroplet(_ p: CGPoint, mx: CGFloat, m: CGFloat, s2: CGFloat, dip: CGFloat) -> Bool {
        abs(p.x - (cx + mx)) < m + s2 * 0.5 && p.y >= frame.d - 4 && p.y < frame.d + dip + 8
    }

    /// index.html:525-534, the `!inBand && !inDrop(p)` branch — three outcomes: stay, close the
    /// droplet first (unpinned, still near the band), or close the whole band.
    public func pointerOutside(
        _ p: CGPoint,
        currentHalf: CGFloat,
        droplet: (mx: CGFloat, m: CGFloat, s2: CGFloat, dip: CGFloat)?,
        pinned: Bool
    ) -> BandPointerAction {
        if inBand(p, currentHalf: currentHalf) { return .stay }
        if let droplet, inDroplet(p, mx: droplet.mx, m: droplet.m, s2: droplet.s2, dip: droplet.dip) { return .stay }

        let dx = abs(p.x - cx)
        if let droplet, !pinned, dx < currentHalf, p.y < frame.d + droplet.dip + 30 {
            return .closeDroplet
        }
        if !pinned { return .closeBand }
        if p.y > frame.d + (droplet?.dip ?? 0) + 40 || dx > currentHalf + 40 {
            return .closeBand
        }
        return .stay
    }
}

/// index.html:530-534 outcomes — `BandLayout.pointerOutside`'s result.
public enum BandPointerAction: Equatable {
    case stay
    case closeDroplet
    case closeBand
}
