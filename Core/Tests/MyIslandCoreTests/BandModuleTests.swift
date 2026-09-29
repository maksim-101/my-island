import Testing
@testable import MyIslandCore

// Ported per D-02 from .planning/sketches/006-design-round/index.html:242-248 (MODS) and
// :763-771 (module switch handler) — MOD-01, 07-DESIGN-AGREEMENT.md §3, §8.

@Test func moduleOrderAndWidths() {
    #expect(BandModule.allCases == [.nowPlaying, .timer, .nextMeeting, .clipboard])
    #expect(BandModule.nowPlaying.dropletWidth == 250)
    #expect(BandModule.timer.dropletWidth == 236)
    #expect(BandModule.nextMeeting.dropletWidth == 256)
    #expect(BandModule.clipboard.dropletWidth == 280)
    #expect(BandModule.nowPlaying.displayName == "Now Playing")
    #expect(BandModule.timer.displayName == "Timer")
    #expect(BandModule.nextMeeting.displayName == "Next meeting")
    #expect(BandModule.clipboard.displayName == "Clipboard")
}

@Test func enabledSanitizes() {
    #expect(BandModules.enabled(from: nil) == BandModule.allCases)
    #expect(BandModules.enabled(from: []) == BandModule.allCases)
    #expect(BandModules.enabled(from: ["clipboard", "bogus", "timer"]) == [.timer, .clipboard])
}

@Test func lastModuleStays() {
    #expect(BandModules.toggling(.timer, in: [.timer]) == [.timer])
    #expect(BandModules.canDisable(.timer, in: [.timer]) == false)
}

@Test func reenableRestoresPosition() {
    #expect(BandModules.toggling(.nowPlaying, in: [.timer, .clipboard]) == [.nowPlaying, .timer, .clipboard])
}
