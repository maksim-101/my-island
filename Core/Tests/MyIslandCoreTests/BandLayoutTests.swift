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
    // cell 3 (m 150): lim = 451 - 150 - 80 - 6 = 215, raw centre 178 stays unclamped.
    let d = layout.droplet(forCell: 3, halfWidth: 150)
    #expect(abs(d.mx - 178) < 0.01)
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

@Test func dropletsKeepBandWallsAndCellOrder() {
    let layout = BandLayout(moduleCount: BandModule.allCases.count, contentTop: 38)
    var previousMX = -CGFloat.infinity
    for (cell, module) in BandModule.allCases.enumerated() {
        let d = layout.droplet(forCell: cell, halfWidth: module.dropletWidth / 2)
        // Distinct cells never share a droplet position: strictly ordered left to right, ≥ 40pt apart.
        #expect(d.mx - previousMX >= 40, "cell \(cell)")
        previousMX = d.mx

        var q = layout.params
        q.dip = d.dip; q.m = d.m; q.s2 = d.s2; q.mx = d.mx
        var flat = layout.params
        flat.dip = 0
        for wallX in [layout.frame.x0, layout.frame.x1] {
            let withDrop = FluidShapeGeometry.floorY(x: wallX, q: q, cx: layout.cx)
            let without = FluidShapeGeometry.floorY(x: wallX, q: flat, cx: layout.cx)
            #expect(abs(withDrop - without) < 8, "cell \(cell) wall \(wallX)")
        }
    }
}

@Test func dropletMiddleClamp() {
    let layout = BandLayout(moduleCount: 5, contentTop: 38)
    // lim = 451 - 118 - 80 - 6 = 247; raw centre -178 stays inside, unclamped.
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
    #expect(abs(cell0.mx - (-54)) < 0.01)
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

@Test func dropletsStayDistinctForEveryModuleSubset() {
    let all = BandModule.allCases
    for mask in 1..<(1 << all.count) {
        let modules = all.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
        guard modules.count > 1 else { continue }
        let layout = BandLayout(moduleCount: modules.count, contentTop: 38)
        var previous = -CGFloat.infinity
        for (cell, module) in modules.enumerated() {
            let mx = layout.droplet(forCell: cell, halfWidth: module.dropletWidth / 2).mx
            #expect(mx - previous >= 40, "mask \(mask) cell \(cell)")
            previous = mx
        }
    }
}

@Test func slidingAsymNeverReachesTheWalls() {
    let layout = BandLayout(moduleCount: BandModule.allCases.count, contentTop: 38)
    for (cell, module) in BandModule.allCases.enumerated() {
        let d = layout.droplet(forCell: cell, halfWidth: module.dropletWidth / 2)
        for requested: CGFloat in [-0.45, 0.45] {
            var q = layout.params
            q.dip = d.dip; q.m = d.m; q.s2 = d.s2; q.mx = d.mx
            q.asym = FluidShapeGeometry.wallSafeAsym(requested, q: q)
            var flat = layout.params
            flat.dip = 0
            for wallX in [layout.frame.x0, layout.frame.x1] {
                let withDrop = FluidShapeGeometry.floorY(x: wallX, q: q, cx: layout.cx)
                let without = FluidShapeGeometry.floorY(x: wallX, q: flat, cx: layout.cx)
                #expect(abs(withDrop - without) < 8, "cell \(cell) asym \(requested) wall \(wallX)")
            }
        }
    }
}

@Test func edgeDropletsMirrorEachOther() {
    let layout = BandLayout(moduleCount: 4, contentTop: 38)
    let modules = BandModule.allCases
    let left = layout.droplet(forCell: 0, halfWidth: modules[0].dropletWidth / 2).mx
    let right = layout.droplet(forCell: 3, halfWidth: modules[3].dropletWidth / 2).mx
    #expect(abs(left + right) < 0.01)
}
