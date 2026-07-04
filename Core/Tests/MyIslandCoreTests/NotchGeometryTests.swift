import Testing
import CoreGraphics
@testable import MyIslandCore

@Test func notchFrameIsNilWhenRightAuxiliaryWidthAbsent() {
    let screenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let result = NotchGeometry.notchFrame(
        screenFrame: screenFrame,
        auxiliaryTopLeftWidth: 650,
        auxiliaryTopRightWidth: nil,
        safeAreaTop: 32
    )
    #expect(result == nil)
}

@Test func notchFrameIsNilWhenLeftAuxiliaryWidthAbsent() {
    let screenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let result = NotchGeometry.notchFrame(
        screenFrame: screenFrame,
        auxiliaryTopLeftWidth: nil,
        auxiliaryTopRightWidth: 650,
        safeAreaTop: 32
    )
    #expect(result == nil)
}

@Test func notchFrameComputesExactCenteredRectForKnownScreen() {
    let screenFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    let result = NotchGeometry.notchFrame(
        screenFrame: screenFrame,
        auxiliaryTopLeftWidth: 650,
        auxiliaryTopRightWidth: 650,
        safeAreaTop: 32
    )
    #expect(result == CGRect(x: 650, y: 1085, width: 428, height: 32))
}
