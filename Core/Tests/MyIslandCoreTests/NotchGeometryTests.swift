import Testing
import CoreGraphics
@testable import MyIslandCore

@Test func notchFrameIsNilWhenRightAuxiliaryEdgeAbsent() {
    let screenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let result = NotchGeometry.notchFrame(
        screenFrame: screenFrame,
        auxiliaryTopLeftMaxX: 771,
        auxiliaryTopRightMinX: nil,
        safeAreaTop: 32
    )
    #expect(result == nil)
}

@Test func notchFrameIsNilWhenLeftAuxiliaryEdgeAbsent() {
    let screenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let result = NotchGeometry.notchFrame(
        screenFrame: screenFrame,
        auxiliaryTopLeftMaxX: nil,
        auxiliaryTopRightMinX: 956,
        safeAreaTop: 32
    )
    #expect(result == nil)
}

@Test func notchFrameIsNilWhenEdgesDoNotLeaveAPositiveWidth() {
    let screenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let result = NotchGeometry.notchFrame(
        screenFrame: screenFrame,
        auxiliaryTopLeftMaxX: 956,
        auxiliaryTopRightMinX: 771,
        safeAreaTop: 32
    )
    #expect(result == nil)
}

@Test func notchFrameComputesExactEdgesForProbedHardware() {
    // Real values probed from the 16" MacBook Pro built-in Retina display:
    // frame width 1728, auxiliaryTopLeftArea.maxX = 771, auxiliaryTopRightArea.minX = 956,
    // safeAreaInsets.top = 32 — so the physical notch is x∈[771,956], width 185, midX 863.5.
    let screenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let result = NotchGeometry.notchFrame(
        screenFrame: screenFrame,
        auxiliaryTopLeftMaxX: 771,
        auxiliaryTopRightMinX: 956,
        safeAreaTop: 32
    )
    #expect(result == CGRect(x: 771, y: 1085, width: 185, height: 32))
    #expect(result?.midX == 863.5)
}

// MARK: - Phase 6: NotchGeometry.Mode (physical / synthetic) — SHELL-06/07

@Test func dampedPillWidthMatchesD09CheckValues() {
    // D-09 check values, formula 160 * (1 + (w/1440 - 1) * 0.3), unrounded — asserted
    // with ±0.5pt tolerance since the formula is not integral.
    #expect(abs(NotchGeometry.dampedPillWidth(screenWidth: 2560) - 197) < 0.5)
    #expect(abs(NotchGeometry.dampedPillWidth(screenWidth: 3200) - 219) < 0.5)
    #expect(abs(NotchGeometry.dampedPillWidth(screenWidth: 3840) - 240) < 0.5)
    #expect(abs(NotchGeometry.dampedPillWidth(screenWidth: 5120) - 283) < 0.5)
    // At the reference width the damping factor is zero — must be EXACTLY 160.
    #expect(NotchGeometry.dampedPillWidth(screenWidth: 1440) == 160)
}

@Test func syntheticHeightFallsBackToStatusBarWhenMenuBarReadsZero() {
    #expect(NotchGeometry.syntheticHeight(menuBarHeight: 0, statusBarThickness: 22) == 22)
    #expect(NotchGeometry.syntheticHeight(menuBarHeight: 30, statusBarThickness: 22) == 30)
    #expect(NotchGeometry.syntheticHeight(menuBarHeight: -1, statusBarThickness: 22) == 22)
    #expect(NotchGeometry.syntheticHeight(menuBarHeight: 0.5, statusBarThickness: 22) == 0.5)
}

@Test func syntheticAnchorIsTopCenterFlushWithTopEdge() {
    // Live Dell frame measured 2026-09-11 (06-CONTEXT.md D-08/D-09).
    let screenFrame = CGRect(x: 1728, y: 37, width: 2560, height: 1080)
    let result = NotchGeometry.syntheticAnchor(screenFrame: screenFrame, height: 30)
    // midX/width derive from the unrounded damped formula — ±0.5pt tolerance
    // (must_haves precision contract); maxY/height are exact integer arithmetic.
    #expect(abs(result.midX - 3008) < 0.5)
    #expect(result.maxY == 1117)
    #expect(result.height == 30)
    #expect(result.width == NotchGeometry.dampedPillWidth(screenWidth: 2560))
}

@Test func resolveModeIsPhysicalForProbedBuiltIn() {
    let screenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let result = NotchGeometry.resolveMode(
        screenFrame: screenFrame,
        auxiliaryTopLeftMaxX: 771,
        auxiliaryTopRightMinX: 956,
        safeAreaTop: 32,
        menuBarHeight: 33,
        statusBarThickness: 22
    )
    #expect(result == .physical(CGRect(x: 771, y: 1085, width: 185, height: 32)))
}

@Test func resolveModeIsSyntheticWheneverNotchFrameIsNil() {
    // Live Dell frame — no auxiliary areas, no safe-area inset (no camera housing).
    let dellFrame = CGRect(x: 1728, y: 37, width: 2560, height: 1080)
    let expected = NotchGeometry.Mode.synthetic(
        NotchGeometry.syntheticAnchor(screenFrame: dellFrame, height: 30)
    )
    let noAuxResult = NotchGeometry.resolveMode(
        screenFrame: dellFrame,
        auxiliaryTopLeftMaxX: nil,
        auxiliaryTopRightMinX: nil,
        safeAreaTop: 0,
        menuBarHeight: 30,
        statusBarThickness: 22
    )
    #expect(noAuxResult == expected)

    // The "promote" invariant (assumption_delta_decision): an inverted-edge input
    // (which notchFrame(...) also treats as nil, since notchWidth <= 0) must ALSO
    // resolve to .synthetic — never a bare nil-equivalent.
    let invertedResult = NotchGeometry.resolveMode(
        screenFrame: dellFrame,
        auxiliaryTopLeftMaxX: 956,
        auxiliaryTopRightMinX: 771,
        safeAreaTop: 0,
        menuBarHeight: 30,
        statusBarThickness: 22
    )
    #expect(invertedResult == expected)
}

@Test func modeAnchorRectAndIsPhysical() {
    let physicalRect = CGRect(x: 771, y: 1085, width: 185, height: 32)
    let physical = NotchGeometry.Mode.physical(physicalRect)
    #expect(physical.anchorRect == physicalRect)
    #expect(physical.isPhysical == true)

    let syntheticRect = CGRect(x: 2909.33, y: 1087, width: 197.33, height: 30)
    let synthetic = NotchGeometry.Mode.synthetic(syntheticRect)
    #expect(synthetic.anchorRect == syntheticRect)
    #expect(synthetic.isPhysical == false)
}

// MARK: - Phase 6 Task 2: D-11 collapsed-hover-target shrink

@Test func collapsedHoverRectIsCenteredAndTopPinned() {
    // Built-in notch: container is the expanded 407×400 panel, notch is the
    // physical 185×32 rect — hover target during collapse is centered
    // horizontally and pinned to the container's top edge.
    let result = NotchGeometry.collapsedHoverRect(
        containerSize: CGSize(width: 407, height: 400),
        notchSize: CGSize(width: 185, height: 32)
    )
    #expect(result == CGRect(x: 111, y: 368, width: 185, height: 32))
}

@Test func collapsedHoverRectForSyntheticPill() {
    // Dell synthetic pill: unrounded damped width means the centering math
    // must round the x origin (bottom-left-origin AppKit view coordinates),
    // while width/height carry the unrounded pill size through unchanged.
    let result = NotchGeometry.collapsedHoverRect(
        containerSize: CGSize(width: 407, height: 400),
        notchSize: CGSize(width: 197.33, height: 30)
    )
    #expect(result.origin.x == 105)
    #expect(result.origin.y == 370)
    #expect(result.size == CGSize(width: 197.33, height: 30))
}

@Test func collapsedHoverRectEqualsContainerWhenAlreadyCollapsed() {
    // Once the window itself has finished collapsing, container == notch
    // size — the hover rect degenerates to the full container, matching
    // `.inVisibleRect` tracking.
    let result = NotchGeometry.collapsedHoverRect(
        containerSize: CGSize(width: 185, height: 32),
        notchSize: CGSize(width: 185, height: 32)
    )
    #expect(result == CGRect(x: 0, y: 0, width: 185, height: 32))
}
