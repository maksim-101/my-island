import Testing
@testable import MyIslandCore

@Test func volumePolicyAutomaticHidesWhileFineTuneRuns() {
    #expect(VolumeHUDPolicy.shouldShow(override: nil, fineTuneRunning: true) == false)
}

@Test func volumePolicyAutomaticShowsWithoutFineTune() {
    #expect(VolumeHUDPolicy.shouldShow(override: nil, fineTuneRunning: false) == true)
}

@Test func volumePolicyOverrideOnWinsWhileFineTuneRuns() {
    #expect(VolumeHUDPolicy.shouldShow(override: true, fineTuneRunning: true) == true)
}

@Test func volumePolicyOverrideOnWithoutFineTune() {
    #expect(VolumeHUDPolicy.shouldShow(override: true, fineTuneRunning: false) == true)
}

@Test func volumePolicyOverrideOffWithoutFineTune() {
    #expect(VolumeHUDPolicy.shouldShow(override: false, fineTuneRunning: false) == false)
}

@Test func volumePolicyOverrideOffWhileFineTuneRuns() {
    #expect(VolumeHUDPolicy.shouldShow(override: false, fineTuneRunning: true) == false)
}
