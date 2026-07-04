import Testing
@testable import MyIslandCore

@Test func startsClosed() {
    let dwell = HoverDwell()
    #expect(dwell.state == .closed)
}

@Test func hoverBeganAloneDoesNotOpen() {
    var dwell = HoverDwell()
    dwell.hoverBegan()
    #expect(dwell.state == .closed)
}

@Test func dwellElapsedAfterHoverBeganOpens() {
    var dwell = HoverDwell()
    dwell.hoverBegan()
    dwell.dwellElapsed()
    #expect(dwell.state == .open)
}

@Test func dwellElapsedWithoutPriorHoverBeganDoesNotOpen() {
    var dwell = HoverDwell()
    dwell.dwellElapsed()
    #expect(dwell.state == .closed)
}

@Test func hoverEndedClosesAndClearsPendingIntent() {
    var dwell = HoverDwell()
    dwell.hoverBegan()
    dwell.hoverEnded()
    dwell.dwellElapsed()
    #expect(dwell.state == .closed)
}

@Test func hoverEndedClosesAnOpenState() {
    var dwell = HoverDwell()
    dwell.hoverBegan()
    dwell.dwellElapsed()
    dwell.hoverEnded()
    #expect(dwell.state == .closed)
}

@Test func toggleFlipsClosedToOpen() {
    var dwell = HoverDwell()
    dwell.toggle()
    #expect(dwell.state == .open)
}

@Test func toggleFlipsOpenToClosed() {
    var dwell = HoverDwell()
    dwell.toggle()
    dwell.toggle()
    #expect(dwell.state == .closed)
}

@Test func toggleClearsPendingIntent() {
    var dwell = HoverDwell()
    dwell.hoverBegan()
    dwell.toggle()
    dwell.toggle()
    dwell.dwellElapsed()
    #expect(dwell.state == .closed)
}
