import Testing
@testable import MyIslandCore

/// RESEARCH.md §1.3 measured built-in-speakers case: both `VirtualMainVolume` and
/// `VolumeScalar(main)` supported, per-channel unsupported — `VirtualMainVolume` must stay the
/// winner (it's the existing code's choice and the two values were measured identical).
@Test func bothVirtualMainAndScalarMainSupportedPicksVirtualMain() {
    let result = VolumeSource.select(hasVirtualMain: true, hasScalarMain: true, supportedChannels: [])
    #expect(result == .virtualMain)
}

@Test func onlyScalarMainSupportedPicksScalarMain() {
    let result = VolumeSource.select(hasVirtualMain: false, hasScalarMain: true, supportedChannels: [])
    #expect(result == .scalarMain)
}

/// RESEARCH Assumption A1 — the mirror case: a device where only per-channel scalars are supported.
@Test func onlyPerChannelSupportedPicksPerChannel() {
    let result = VolumeSource.select(hasVirtualMain: false, hasScalarMain: false, supportedChannels: [1, 2])
    #expect(result == .perChannel([1, 2]))
}

@Test func nothingSupportedPicksUnsupported() {
    let result = VolumeSource.select(hasVirtualMain: false, hasScalarMain: false, supportedChannels: [])
    #expect(result == .unsupported)
}

/// Priority is strict, not "most channels" or "most sources": VirtualMainVolume wins even when
/// per-channel scalars are also present.
@Test func virtualMainWinsOverPerChannelEvenWhenBothSupported() {
    let result = VolumeSource.select(hasVirtualMain: true, hasScalarMain: false, supportedChannels: [1, 2])
    #expect(result == .virtualMain)
}
