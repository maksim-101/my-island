import Testing
import CoreGraphics
@testable import MyIslandCore

// Ported per D-02 from .planning/sketches/006-design-round/index.html:510-524 (collapsed
// frame-loop branch: reach, pull, lean, inside, dwell), a gitignored planning artifact read
// directly from disk. `dwellExcludesAlertDrop`'s fixture keeps a deeper-than-macBookPill `q` (d:
// 40) so the tested y (20) sits inside the trigger band (26.67) and only the alertTop guard decides.

@Test func dwellOnlyInUpperTwoThirdsOfPillDepth() {
    let q = FluidParams.macBookPill(menuBarHeight: 33, notchHeight: 32)
    #expect(FluidPointer.isDwellTarget(pointer: CGPoint(x: 0, y: q.d * 0.5), cx: 0, q: q))
    #expect(FluidPointer.isDwellTarget(pointer: CGPoint(x: 0, y: 21.9), cx: 0, q: q))
    #expect(FluidPointer.isDwellTarget(pointer: CGPoint(x: 128.4, y: 5), cx: 0, q: q))
    #expect(!FluidPointer.isDwellTarget(pointer: CGPoint(x: 0, y: 22.1), cx: 0, q: q))
    #expect(!FluidPointer.isDwellTarget(pointer: CGPoint(x: 0, y: q.d * 0.7), cx: 0, q: q))
    #expect(!FluidPointer.isDwellTarget(pointer: CGPoint(x: 0, y: q.d - 0.1), cx: 0, q: q))
    #expect(!FluidPointer.isDwellTarget(pointer: CGPoint(x: 0, y: q.d + 7.9), cx: 0, q: q))
    #expect(!FluidPointer.isDwellTarget(pointer: CGPoint(x: 128.6, y: 5), cx: 0, q: q))
    #expect(!FluidPointer.isDwellTarget(pointer: CGPoint(x: -128.6, y: 5), cx: 0, q: q))
}

@Test func dwellTriggerDepthFollowsEachSurface() {
    #expect(abs(FluidPointer.hoverTriggerDepthFraction - 2.0 / 3.0) < 1e-12)
    let desktop = FluidParams.desktopPill(width: 197.33, height: 30)
    #expect(FluidPointer.isDwellTarget(pointer: CGPoint(x: 0, y: 15), cx: 0, q: desktop))
    #expect(!FluidPointer.isDwellTarget(pointer: CGPoint(x: 0, y: 21), cx: 0, q: desktop))
    #expect(abs(FluidPointer.triggerDepth(q: desktop) - 20) < 1e-9)
    let bulge = FluidParams.fullscreenBulge(width: 197.33)
    #expect(FluidPointer.isDwellTarget(pointer: CGPoint(x: 0, y: 4.5), cx: 0, q: bulge))
    #expect(!FluidPointer.isDwellTarget(pointer: CGPoint(x: 0, y: 6.3), cx: 0, q: bulge))
    #expect(abs(FluidPointer.triggerDepth(q: bulge) - 6) < 1e-9)
}

@Test func dwellExcludesAlertDrop() {
    let q = FluidParams(half: 128.5, run: 18, d: 40, sd: 40, sag: 3)
    #expect(!FluidPointer.isDwellTarget(pointer: CGPoint(x: 0, y: 20), cx: 0, q: q, alertTop: 21))
    #expect(FluidPointer.isDwellTarget(pointer: CGPoint(x: 0, y: 20), cx: 0, q: q, alertTop: 23))
}

@Test func stickyPullInside() {
    let q = FluidParams.macBookPill(menuBarHeight: 33, notchHeight: 32)
    let result = FluidPointer.stickyPull(pointer: CGPoint(x: 0, y: 10), cx: 0, q: q, damped: false)
    #expect(abs(result.pull - 6) < 1e-9)
    #expect(abs(result.lean) < 1e-9)
}

@Test func stickyPullBeyondReach() {
    let q = FluidParams.macBookPill(menuBarHeight: 33, notchHeight: 32)
    // reach = 80 + half * 0.5 = 144.25, derived from q.d (no literal depth — 07-15 gap closure).
    let result = FluidPointer.stickyPull(pointer: CGPoint(x: 0, y: q.d + 80 + 64.25 + 1), cx: 0, q: q, damped: false)
    #expect(abs(result.pull) < 1e-9)
    #expect(abs(result.lean) < 1e-9)
}

@Test func stickyLeanFollowsSide() {
    let q = FluidParams.macBookPill(menuBarHeight: 33, notchHeight: 32)
    let right = FluidPointer.stickyPull(pointer: CGPoint(x: 60, y: 50), cx: 0, q: q, damped: false)
    let left = FluidPointer.stickyPull(pointer: CGPoint(x: -60, y: 50), cx: 0, q: q, damped: false)
    #expect(right.lean > 0)
    #expect(left.lean < 0)
    #expect(abs(right.lean) <= 12)
    #expect(abs(left.lean) <= 12)
}

@Test func stickyDampedWhileAlert() {
    let q = FluidParams.macBookPill(menuBarHeight: 33, notchHeight: 32)
    let undamped = FluidPointer.stickyPull(pointer: CGPoint(x: 0, y: 10), cx: 0, q: q, damped: false)
    let damped = FluidPointer.stickyPull(pointer: CGPoint(x: 0, y: 10), cx: 0, q: q, damped: true)
    #expect(abs(damped.pull - undamped.pull * 0.3) < 1e-9)
    #expect(abs(damped.lean - undamped.lean * 0.3) < 1e-9)
}

@Test func noPointerNoPull() {
    let q = FluidParams.macBookPill(menuBarHeight: 33, notchHeight: 32)
    let result = FluidPointer.stickyPull(pointer: nil, cx: 0, q: q, damped: false)
    #expect(result.pull == 0)
    #expect(result.lean == 0)
}
