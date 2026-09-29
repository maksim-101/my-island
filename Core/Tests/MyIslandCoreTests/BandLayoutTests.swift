import Testing
import CoreGraphics
@testable import MyIslandCore

// Ported per D-02 from .planning/sketches/006-design-round/index.html's bandFrame/cells/setHot/
// cellAt/inDrop and the pointer branch of frame() (lines 316-320, 355-368, 439-449, 525-534) —
// 07-DESIGN-AGREEMENT.md §1, §3.

@Test func bandWidths() {
    let widths: [Int: CGFloat] = [5: 1166, 4: 988, 3: 824, 2: 824, 1: 824]
    for (count, expected) in widths {
        let layout = BandLayout(moduleCount: count, contentTop: 38)
        #expect(abs(layout.params.half * 2 - expected) < 0.01, "n=\(count)")
    }
}

@Test func cellsAtFive() {
    let layout = BandLayout(moduleCount: 5, contentTop: 38)
    #expect(abs(layout.cellWidth - 178) < 0.01)
    let expectedCenters: [CGFloat] = [-356, -178, 0, 178, 356]
    for (i, expected) in expectedCenters.enumerated() {
        #expect(abs(layout.centers[i] - expected) < 0.01, "center \(i)")
    }
    // cell 3 (Claude, m 150): lim = 451 - 150 - 122 - 26 = 153, raw centre 178 clamps to 153.
    let d = layout.droplet(forCell: 3, halfWidth: 150)
    #expect(abs(d.mx - 153) < 0.01)
}

@Test func cellAtBoundaries() {
    let layout = BandLayout(moduleCount: 5, contentTop: 38)
    #expect(layout.cellAt(CGPoint(x: layout.cellsX, y: 60)) == 0)
    #expect(layout.cellAt(CGPoint(x: layout.cellsX + layout.cellsWidth, y: 60)) == 4)
    #expect(layout.cellAt(CGPoint(x: layout.cellsX - 0.1, y: 60)) == nil)
    #expect(layout.cellAt(CGPoint(x: 0, y: 32)) != nil)
    #expect(layout.cellAt(CGPoint(x: 0, y: 31.9)) == nil)
    #expect(layout.cellAt(CGPoint(x: 0, y: 96)) != nil)
    #expect(layout.cellAt(CGPoint(x: 0, y: 96.1)) == nil)
}

@Test func dropletEdgeStaysInsideBand() {
    let layout = BandLayout(moduleCount: 5, contentTop: 38)
    let left = layout.droplet(forCell: 0, halfWidth: 125)
    #expect(abs(left.mx - (-178)) < 0.01)
    #expect(abs(left.dip - 188) < 0.01)
    #expect(abs(left.s2 - 122) < 0.01)

    let right = layout.droplet(forCell: 4, halfWidth: 140)
    #expect(abs(right.mx - 163) < 0.01)

    var q = layout.params
    q.dip = left.dip; q.m = left.m; q.s2 = left.s2; q.mx = left.mx
    var base = layout.params
    base.dip = 0
    let wallX = layout.frame.x0
    let drop = FluidShapeGeometry.floorY(x: wallX, q: q, cx: layout.cx)
    let flat = FluidShapeGeometry.floorY(x: wallX, q: base, cx: layout.cx)
    #expect(abs(drop - flat) < 8)
}

@Test func dropletMiddleClamp() {
    let layout = BandLayout(moduleCount: 5, contentTop: 38)
    // lim = 451 - 118 - 122 - 26 = 185; raw centre -178 stays inside, unclamped.
    let cell1 = layout.droplet(forCell: 1, halfWidth: 118)
    #expect(abs(cell1.mx - (-178)) < 0.01)

    let cell2 = layout.droplet(forCell: 2, halfWidth: 118)
    #expect(abs(cell2.mx - 0) < 0.01)

    let single = BandLayout(moduleCount: 1, contentTop: 38)
    let onlyCell = single.droplet(forCell: 0, halfWidth: 118)
    #expect(abs(onlyCell.mx - 0) < 0.01)
}

@Test func dropletAtFloor() {
    let layout = BandLayout(moduleCount: 3, contentTop: 38)
    #expect(abs(layout.params.half * 2 - 824) < 0.01)
    let cell0 = layout.droplet(forCell: 0, halfWidth: 125)
    #expect(abs(cell0.mx - (-7)) < 0.01)
    let cell1 = layout.droplet(forCell: 1, halfWidth: 125)
    #expect(abs(cell1.mx - 0) < 0.01)
}

@Test func inDropletBounds() {
    let layout = BandLayout(moduleCount: 5, contentTop: 38)
    let d = layout.frame.d
    #expect(layout.inDroplet(CGPoint(x: 188.9, y: 100), mx: 0, m: 128, s2: 122, dip: 188))
    #expect(!layout.inDroplet(CGPoint(x: 189.1, y: 100), mx: 0, m: 128, s2: 122, dip: 188))
    #expect(layout.inDroplet(CGPoint(x: 0, y: d - 4), mx: 0, m: 128, s2: 122, dip: 188))
    #expect(layout.inDroplet(CGPoint(x: 0, y: d + 188 + 7.9), mx: 0, m: 128, s2: 122, dip: 188))
    #expect(!layout.inDroplet(CGPoint(x: 0, y: d + 196), mx: 0, m: 128, s2: 122, dip: 188))
}

@Test func pointerOutsideRules() {
    let layout = BandLayout(moduleCount: 5, contentTop: 38)
    let currentHalf = layout.params.half
    let d = layout.frame.d
    let dropletParams: (mx: CGFloat, m: CGFloat, s2: CGFloat, dip: CGFloat) = (0, 150, 122, 188)

    // unpinned, droplet showing, below the band, inside |dx| < half and y < d + dip + 30 → closeDroplet
    let closeDropletAction = layout.pointerOutside(
        CGPoint(x: 0, y: d + 188 + 20), currentHalf: currentHalf, droplet: dropletParams, pinned: false
    )
    #expect(closeDropletAction == .closeDroplet)

    // unpinned, no droplet, far outside → closeBand
    let closeBandUnpinned = layout.pointerOutside(
        CGPoint(x: currentHalf + 100, y: 50), currentHalf: currentHalf, droplet: nil, pinned: false
    )
    #expect(closeBandUnpinned == .closeBand)

    // pinned, within the wider pinned-close bounds → stay
    let stayPinned = layout.pointerOutside(
        CGPoint(x: 0, y: d + 188 + 40), currentHalf: currentHalf, droplet: dropletParams, pinned: true
    )
    #expect(stayPinned == .stay)

    // pinned, beyond the wider bound → closeBand
    let closeBandPinned = layout.pointerOutside(
        CGPoint(x: 0, y: d + 188 + 41), currentHalf: currentHalf, droplet: dropletParams, pinned: true
    )
    #expect(closeBandPinned == .closeBand)

    // inside the band → stay
    let insideBand = layout.pointerOutside(
        CGPoint(x: 0, y: 50), currentHalf: currentHalf, droplet: dropletParams, pinned: false
    )
    #expect(insideBand == .stay)

    // inside the droplet → stay
    let insideDroplet = layout.pointerOutside(
        CGPoint(x: 0, y: d + 100), currentHalf: currentHalf, droplet: dropletParams, pinned: true
    )
    #expect(insideDroplet == .stay)
}
