import Testing
import Foundation
@testable import MyIslandCore

@Test func limitBytesWithNoOverrideReturnsDefault512MiB() {
    let expected = AdapterFootprintPolicy.defaultLimitMegabytes * 1024 * 1024
    #expect(AdapterFootprintPolicy.limitBytes(overrideMegabytes: nil) == expected)
}

@Test func limitBytesWithOverrideHonoursIt() {
    #expect(AdapterFootprintPolicy.limitBytes(overrideMegabytes: 64) == 64 * 1024 * 1024)
}

/// A zero override would recycle the adapter on its very first poll, forever — treated as absent
/// rather than obeyed.
@Test func limitBytesWithZeroOverrideFallsBackToDefault() {
    let expected = AdapterFootprintPolicy.defaultLimitMegabytes * 1024 * 1024
    #expect(AdapterFootprintPolicy.limitBytes(overrideMegabytes: 0) == expected)
}

@Test func shouldRecycleIsFalseOneByteBelowLimit() {
    let limit = AdapterFootprintPolicy.limitBytes(overrideMegabytes: nil)
    #expect(!AdapterFootprintPolicy.shouldRecycle(footprintBytes: limit - 1, limitBytes: limit))
}

/// Strictly-greater comparison: a footprint exactly at the limit is not a recycle.
@Test func shouldRecycleIsFalseExactlyAtLimit() {
    let limit = AdapterFootprintPolicy.limitBytes(overrideMegabytes: nil)
    #expect(!AdapterFootprintPolicy.shouldRecycle(footprintBytes: limit, limitBytes: limit))
}

@Test func shouldRecycleIsTrueOneByteAboveLimit() {
    let limit = AdapterFootprintPolicy.limitBytes(overrideMegabytes: nil)
    #expect(AdapterFootprintPolicy.shouldRecycle(footprintBytes: limit + 1, limitBytes: limit))
}

/// The measured real-world leak value (4233 MB, this session's diagnosis) is an explicit
/// regression case against the production default limit.
@Test func shouldRecycleIsTrueForTheMeasuredRealWorldLeakValue() {
    let limit = AdapterFootprintPolicy.limitBytes(overrideMegabytes: nil)
    let leakedFootprint: UInt64 = 4_233 * 1024 * 1024
    #expect(AdapterFootprintPolicy.shouldRecycle(footprintBytes: leakedFootprint, limitBytes: limit))
}
