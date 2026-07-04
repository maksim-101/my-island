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
