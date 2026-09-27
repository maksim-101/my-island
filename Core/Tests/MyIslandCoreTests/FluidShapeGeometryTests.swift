import Testing
import CoreGraphics
@testable import MyIslandCore

// Ported per D-02 from .planning/sketches/005-band-droplet/index.html and
// .planning/sketches/006-design-round/index.html (gitignored planning artifacts,
// read directly from disk — not a source-tree analog). Every assertion below
// reproduces a number from 07-DESIGN-AGREEMENT.md §1 or a value hand-traced
// against the sketch's own frameOf/floorY/shape/pebble/neck arithmetic.

@Test func macBookPillSpansExactly257() {
    let path = FluidShapeGeometry.outline(cx: 0, q: .macBookPill, closed: true)
    let box = path.boundingBox
    #expect(abs(box.minX - (-128.5)) < 0.01)
    #expect(abs(box.maxX - 128.5) < 0.01)

    let frame = FluidShapeGeometry.frameOf(.macBookPill, cx: 0)
    #expect(abs(frame.x0 - (-110.5)) < 0.01)
}

@Test func macBookPillFloorAndSag() {
    let frame = FluidShapeGeometry.frameOf(.macBookPill, cx: 0)
    let atShoulderEnd = FluidShapeGeometry.floorY(x: frame.x0, q: .macBookPill, cx: 0)
    let atCentre = FluidShapeGeometry.floorY(x: 0, q: .macBookPill, cx: 0)
    #expect(abs(atShoulderEnd - 36) < 0.01)
    #expect(abs(atCentre - 39) < 0.01)
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
    q.s2 = 122
    q.mx = 0

    let floor = FluidShapeGeometry.floorY(x: 0, q: q, cx: 0)
    let baseline = q.d + q.sag
    #expect(abs((floor - baseline) - 213) < 0.01)
}

@Test func cameraHousingCovered() {
    let q = FluidParams.macBookPill
    #expect(FluidShapeGeometry.contains(CGPoint(x: 0, y: 31.5), cx: 0, q: q))
    #expect(FluidShapeGeometry.contains(CGPoint(x: 92.5, y: 31.5), cx: 0, q: q))
    #expect(FluidShapeGeometry.contains(CGPoint(x: -92.5, y: 31.5), cx: 0, q: q))
    #expect(FluidShapeGeometry.contains(CGPoint(x: 92.5, y: 0.5), cx: 0, q: q))
    #expect(FluidShapeGeometry.contains(CGPoint(x: -92.5, y: 0.5), cx: 0, q: q))
}

@Test func wingItemsClearOutline() {
    let q = FluidParams.macBookPill
    for x: CGFloat in [95.5, 111.5] {
        for signedX in [x, -x] {
            let boundary = FluidShapeGeometry.boundaryY(atX: signedX, cx: 0, q: q)
            #expect(boundary - 26 >= 9.5, "x=\(signedX) boundary=\(boundary)")
        }
    }
}

@Test func oneFamilyEndpoints() {
    let shapes: [FluidParams] = [
        .macBookPill,
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
    for q in [FluidParams.macBookPill, FluidParams.band(moduleCount: 5, contentTop: 38)] {
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
