import Testing
import CoreGraphics
@testable import MyIslandCore

// Ported per D-02 from .planning/sketches/005-band-droplet/index.html and
// .planning/sketches/006-design-round/index.html (gitignored planning artifacts,
// read directly from disk — not a source-tree analog). Every assertion below
// reproduces a number from 07-DESIGN-AGREEMENT.md §1 or a value hand-traced
// against the sketch's own frameOf/floorY/shape/pebble/neck arithmetic.

@Test func macBookPillSpansExactly257() {
    let q = FluidParams.macBookPill(menuBarHeight: 33, notchHeight: 32)
    let path = FluidShapeGeometry.outline(cx: 0, q: q, closed: true)
    let box = path.boundingBox
    #expect(abs(box.minX - (-128.5)) < 0.01)
    #expect(abs(box.maxX - 128.5) < 0.01)

    let frame = FluidShapeGeometry.frameOf(q, cx: 0)
    #expect(abs(frame.x0 - (-110.5)) < 0.01)
}

// 07-15 gap closure (D-06 row 1): depth now follows the display's measured menu-bar height —
// the same rule `desktopPill` already used — instead of a fixed 36pt. 33/32 are this Mac's
// measured menu-bar height and notch height (uat-evidence/gap-15/01-baseline-probe.txt).
@Test func macBookPillDepthFollowsMenuBar() {
    let q = FluidParams.macBookPill(menuBarHeight: 33, notchHeight: 32)
    #expect(abs(q.half - 128.5) < 0.01)
    #expect(abs(q.run - 18) < 0.01)
    #expect(abs(q.sag - 3) < 0.01)
    #expect(abs(q.d - 33) < 0.01)
    #expect(abs(q.sd - 33) < 0.01)

    let frame = FluidShapeGeometry.frameOf(q, cx: 0)
    let atShoulderEnd = FluidShapeGeometry.floorY(x: frame.x0, q: q, cx: 0)
    let atCentre = FluidShapeGeometry.floorY(x: 0, q: q, cx: 0)
    #expect(abs(atShoulderEnd - 33) < 0.01)
    #expect(abs(atCentre - 36) < 0.01)
}

// FLUID-01: depth is floored at the notch height so a zero menu-bar read (Pitfall 3) or an
// auto-hidden menu bar can never uncover the camera housing.
@Test func macBookPillNeverShallowerThanHousing() {
    #expect(abs(FluidParams.macBookPill(menuBarHeight: 0, notchHeight: 32).d - 32) < 0.01)
    #expect(abs(FluidParams.macBookPill(menuBarHeight: 30, notchHeight: 32).d - 32) < 0.01)
    #expect(abs(FluidParams.macBookPill(menuBarHeight: 37, notchHeight: 32).d - 37) < 0.01)
}

@Test func desktopPillFromAnchor() {
    let q = FluidParams.desktopPill(width: 197, height: 30)
    let path = FluidShapeGeometry.outline(cx: 0, q: q, closed: true)
    let box = path.boundingBox
    #expect(abs(box.width - 197) < 0.01)

    let frame = FluidShapeGeometry.frameOf(q, cx: 0)
    let atX0 = FluidShapeGeometry.floorY(x: frame.x0, q: q, cx: 0)
    let atCentre = FluidShapeGeometry.floorY(x: 0, q: q, cx: 0)
    #expect(abs(atX0 - 30) < 0.01)
    #expect(abs(atCentre - 32) < 0.01)
}

@Test func bulgeRestShape() {
    let q = FluidParams.fullscreenBulge(width: 197)
    let frame = FluidShapeGeometry.frameOf(q, cx: 0)
    #expect(abs(frame.run - 72) < 0.01)
    #expect(abs(frame.x0 - (-26.5)) < 0.01)

    let atCentre = FluidShapeGeometry.floorY(x: 0, q: q, cx: 0)
    #expect(abs(atCentre - 11) < 0.01)
}

@Test func bandWidthReflows() {
    let q5 = FluidParams.band(moduleCount: 5, contentTop: 38)
    let q4 = FluidParams.band(moduleCount: 4, contentTop: 38)
    let q3 = FluidParams.band(moduleCount: 3, contentTop: 38)
    let q2 = FluidParams.band(moduleCount: 2, contentTop: 38)
    let q1 = FluidParams.band(moduleCount: 1, contentTop: 38)

    #expect(abs(FluidShapeGeometry.outline(cx: 0, q: q5, closed: true).boundingBox.width - 1166) < 0.01)
    #expect(abs(FluidShapeGeometry.outline(cx: 0, q: q4, closed: true).boundingBox.width - 988) < 0.01)
    #expect(abs(FluidShapeGeometry.outline(cx: 0, q: q3, closed: true).boundingBox.width - 824) < 0.01)
    #expect(abs(FluidShapeGeometry.outline(cx: 0, q: q2, closed: true).boundingBox.width - 824) < 0.01)
    #expect(abs(FluidShapeGeometry.outline(cx: 0, q: q1, closed: true).boundingBox.width - 824) < 0.01)

    let atContentTop38 = FluidParams.band(moduleCount: 5, contentTop: 38)
    let atContentTop12 = FluidParams.band(moduleCount: 5, contentTop: 12)
    #expect(abs(atContentTop38.d - 92) < 0.01)
    #expect(abs(atContentTop12.d - 66) < 0.01)
}

@Test func fullDropletDepth() {
    var q = FluidParams.band(moduleCount: 5, contentTop: 38)
    q.dip = 188
    q.m = 125
    q.s2 = FluidShapeGeometry.dropletFlank
    q.mx = 0

    let floor = FluidShapeGeometry.floorY(x: 0, q: q, cx: 0)
    let baseline = q.d + q.sag
    #expect(abs((floor - baseline) - 213) < 0.01)
}

@Test func cameraHousingCovered() {
    let points: [CGPoint] = [
        CGPoint(x: 0, y: 31.5), CGPoint(x: 92.5, y: 31.5), CGPoint(x: -92.5, y: 31.5),
        CGPoint(x: 92.5, y: 0.5), CGPoint(x: -92.5, y: 0.5),
    ]
    // Measured menu-bar depth.
    let q = FluidParams.macBookPill(menuBarHeight: 33, notchHeight: 32)
    for p in points {
        #expect(FluidShapeGeometry.contains(p, cx: 0, q: q), "\(p) at measured depth")
    }
    // Floor case: a zero-read/auto-hidden menu bar must never uncover the housing (FLUID-01).
    let qFloor = FluidParams.macBookPill(menuBarHeight: 0, notchHeight: 32)
    for p in points {
        #expect(FluidShapeGeometry.contains(p, cx: 0, q: qFloor), "\(p) at floored depth")
    }
}

// 07-DESIGN-AGREEMENT.md §2 amended 2026-09-27 (07-15): at the measured 33pt depth the black
// below the wing items is at least 6.7pt (was 9.7pt at the retired fixed 36pt depth).
@Test func wingItemsClearOutline() {
    let q = FluidParams.macBookPill(menuBarHeight: 33, notchHeight: 32)
    for x: CGFloat in [95.5, 111.5] {
        for signedX in [x, -x] {
            let boundary = FluidShapeGeometry.boundaryY(atX: signedX, cx: 0, q: q)
            #expect(boundary - 26 >= 6.5, "x=\(signedX) boundary=\(boundary)")
        }
    }
}

// 07-15 gap closure (T-07-26, characterization not a gate): the chevron's relMinX (127, measured
// via MenuBarAgent's AX tree, uat-evidence/gap-15/01-baseline-probe.txt 2026-09-27) is not
// portable across x — recompute the depth bound from `boundaryY` at the measured x rather than
// asserting a literal. At this specific reading the pill's shoulder tip enters the chevron's
// frame only in its very top (well under half a point) and the glyph band (y ≥ 11) stays clear.
// The chevron's own AX frame moved during 07-15's own session and later settled at a deeper
// reading (relMinX 118, ~20pt fill, past the glyph band — 07-15-SUMMARY.md "Chevron measurement")
// — this test characterizes the 127 sample only, not a stable property of the live system.
@Test func shoulderTipInChevronFrame() {
    let q = FluidParams.macBookPill(menuBarHeight: 33, notchHeight: 32)
    let relMinX: CGFloat = 127
    var maxBoundary: CGFloat = 0
    var x = relMinX
    while x <= 128.5 {
        maxBoundary = max(maxBoundary, FluidShapeGeometry.boundaryY(atX: x, cx: 0, q: q))
        x += 0.1
    }
    let roundedBound = (maxBoundary * 10).rounded(.up) / 10
    #expect(maxBoundary <= roundedBound + 0.001)
    #expect(roundedBound <= 0.6, "chevron entry depth grew unexpectedly: \(roundedBound)")
    #expect(!FluidShapeGeometry.contains(CGPoint(x: relMinX - 2, y: 11), cx: 0, q: q))
}

@Test func oneFamilyEndpoints() {
    let shapes: [FluidParams] = [
        .macBookPill(menuBarHeight: 33, notchHeight: 32),
        .desktopPill(width: 197, height: 30),
        .fullscreenBulge(width: 197),
        .band(moduleCount: 5, contentTop: 38),
    ]
    for q in shapes {
        let path = FluidShapeGeometry.outline(cx: 0, q: q, closed: true)
        let box = path.boundingBox
        #expect(abs(box.minX - (-q.half)) < 0.05)
        #expect(abs(box.maxX - q.half) < 0.05)
    }
}

@Test func probePointsStraddleOutline() {
    for q in [FluidParams.macBookPill(menuBarHeight: 33, notchHeight: 32), FluidParams.band(moduleCount: 5, contentTop: 38)] {
        let probes = FluidShapeGeometry.probePoints(cx: 0, q: q, count: 24, offset: 1)
        #expect(probes.count == 24)
        for probe in probes {
            #expect(FluidShapeGeometry.contains(probe.inside, cx: 0, q: q), "inside \(probe.inside) should be contained")
            #expect(!FluidShapeGeometry.contains(probe.outside, cx: 0, q: q), "outside \(probe.outside) should not be contained")
        }
    }
}

@Test func pebbleBounds() {
    let path = FluidShapeGeometry.pebble(w: 80, y: 44, h: 22)
    let box = path.boundingBox
    #expect(abs(box.minX - (-80)) < 0.01)
    #expect(abs(box.maxX - 80) < 0.01)
    #expect(box.minY >= 43.99)
    #expect(path.contains(CGPoint(x: 0, y: 55), using: .winding, transform: .identity))
}

@Test func neckWaistNarrows() {
    let path = FluidShapeGeometry.neck(a: 48, y0: 39, y1: 47, waist: 10)
    #expect(path.contains(CGPoint(x: 0, y: 43), using: .winding, transform: .identity))
    #expect(!path.contains(CGPoint(x: 20, y: 43), using: .winding, transform: .identity))
}
