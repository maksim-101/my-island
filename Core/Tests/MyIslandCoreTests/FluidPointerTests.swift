import Testing
import CoreGraphics
@testable import MyIslandCore

// Ported per D-02 from .planning/sketches/006-design-round/index.html:510-524 (collapsed
// frame-loop branch: reach, pull, lean, inside, dwell), a gitignored planning artifact read
// directly from disk. `dwellExcludesAlertDrop`'s fixture uses a deeper-than-macBookPill `q` (d:
// 40) deliberately — the sketch's `onBump` guard only matters once the base `inside` check would
// otherwise pass at the tested y, which `.macBookPill(menuBarHeight:notchHeight:)`'s own d (33,
// 07-15 gap closure — was 36) does not allow at y=44.9/45.5.

@Test func dwellInsideHalfWidthAndEightBelow() {
    let q = FluidParams.macBookPill(menuBarHeight: 33, notchHeight: 32)
    #expect(FluidPointer.isDwellTarget(pointer: CGPoint(x: 0, y: 20), cx: 0, q: q))
    #expect(FluidPointer.isDwellTarget(pointer: CGPoint(x: 128.4, y: 5), cx: 0, q: q))
    #expect(!FluidPointer.isDwellTarget(pointer: CGPoint(x: 128.6, y: 5), cx: 0, q: q))
    #expect(FluidPointer.isDwellTarget(pointer: CGPoint(x: 0, y: 40.9), cx: 0, q: q))
    #expect(!FluidPointer.isDwellTarget(pointer: CGPoint(x: 0, y: 41.1), cx: 0, q: q))
}

@Test func dwellExcludesAlertDrop() {
    let q = FluidParams(half: 128.5, run: 18, d: 40, sd: 40, sag: 3)
    #expect(!FluidPointer.isDwellTarget(pointer: CGPoint(x: 0, y: 45.5), cx: 0, q: q, alertTop: 47))
    #expect(FluidPointer.isDwellTarget(pointer: CGPoint(x: 0, y: 44.9), cx: 0, q: q, alertTop: 47))
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
