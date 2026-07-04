import Testing
@testable import MyIslandCore

@Test func bundleIDMatchesExpected() {
    #expect(AppIdentity.bundleID == "com.maksim101.myisland")
}

@Test func centeredOriginXCentersOverlay() {
    #expect(AppIdentity.centeredOriginX(screenWidth: 1000, overlayWidth: 200) == 400)
}

@Test func centeredOriginXReturnsZeroWhenOverlayFillsScreen() {
    #expect(AppIdentity.centeredOriginX(screenWidth: 200, overlayWidth: 200) == 0)
}
