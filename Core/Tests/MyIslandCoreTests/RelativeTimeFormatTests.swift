import Testing
import Foundation
@testable import MyIslandCore

@Test func relativeTimeZeroReadsNow() {
    #expect(RelativeTimeFormat.string(remaining: 0, rounding: .floor) == "now")
}

@Test func relativeTimeNegativeReadsNow() {
    #expect(RelativeTimeFormat.string(remaining: -5, rounding: .floor) == "now")
}

@Test func relativeTimeSixtyMinutesInclusiveStaysInMinutes() {
    #expect(RelativeTimeFormat.string(remaining: 3600, rounding: .floor) == "60m")
}

@Test func relativeTimeJustOverSixtyMinutesSwitchesToHours() {
    #expect(RelativeTimeFormat.string(remaining: 3601, rounding: .floor) == "1h")
}

@Test func relativeTimeFloorsFractionalHours() {
    // 282 minutes = 16920s, matches the reported 282-minute event reading "4h"
    #expect(RelativeTimeFormat.string(remaining: 16920, rounding: .floor) == "4h")
}

@Test func relativeTimeFloorVsNearestDivergeAtAntiJitterBoundary() {
    // 899s is the exact case the .nearest exception exists for: a threshold bump firing a
    // fraction of a second before the 15m mark must not read "14m".
    #expect(RelativeTimeFormat.string(remaining: 899, rounding: .floor) == "14m")
    #expect(RelativeTimeFormat.string(remaining: 899, rounding: .nearest) == "15m")
}

@Test func relativeTimeLargeValueFloors() {
    #expect(RelativeTimeFormat.string(remaining: 36000, rounding: .floor) == "10h")
}

@Test func relativeTimeNearestNeverReadsZeroMinutes() {
    // Anti-jitter floor-at-1: .nearest must never announce "0m".
    #expect(RelativeTimeFormat.string(remaining: 10, rounding: .nearest) == "1m")
}
