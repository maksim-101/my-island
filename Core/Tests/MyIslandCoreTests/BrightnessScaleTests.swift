import Testing
import Foundation
@testable import MyIslandCore

@Test func firstValueAlwaysPublishesRegardlessOfMagnitude() {
    #expect(BrightnessScale.shouldPublish(new: 0.2575, lastPublished: nil))
}

/// RESEARCH §1.2's measured coalescing threshold: 0.2575 vs a last-published value 0.0025 away
/// (below 0.005) must NOT publish.
@Test func deltaBelowThresholdDoesNotPublish() {
    #expect(!BrightnessScale.shouldPublish(new: 0.2575, lastPublished: 0.2600))
}

@Test func deltaAboveThresholdPublishes() {
    #expect(BrightnessScale.shouldPublish(new: 0.2575, lastPublished: 0.2700))
}

/// The rail values always publish even when the delta from the last published value is inside the
/// coalescing window — the dark/bright extremes must never be left un-rendered.
@Test func exactZeroAlwaysPublishesEvenInsideThreshold() {
    #expect(BrightnessScale.shouldPublish(new: 0.0, lastPublished: 0.001))
}

@Test func exactOneAlwaysPublishesEvenInsideThreshold() {
    #expect(BrightnessScale.shouldPublish(new: 1.0, lastPublished: 0.999))
}

/// RESEARCH §1.2's measured callback transcript for a single BRIGHTNESS_UP key press: a smooth,
/// monotonically increasing ramp from 0.2575 to 0.4225 across ~33 samples. Coalescing must publish
/// strictly fewer times than the number of samples fed, and the final published value must be the
/// ramp's true endpoint — a held key must never leave the HUD short of where the finger actually let
/// go.
@Test func measuredRampCoalescesToFewerPublishesEndingAtTheTrueFinalValue() {
    // The three leading measured values from RESEARCH §1.2, followed by a synthesized plateau of
    // sub-threshold micro-steps (representing the tail of the ~33-sample transcript RESEARCH
    // summarized as "... 30 more ...") and ending at the measured final value 0.4225.
    let finalValue: Float = 0.4225
    let samples: [Float] = [
        0.2771429, 0.2921088, 0.3035115,
        0.3037, 0.3039, 0.3041, 0.3043, 0.3045,
        finalValue,
    ]

    var lastPublished: Float?
    var publishCount = 0
    for sample in samples {
        if BrightnessScale.shouldPublish(new: sample, lastPublished: lastPublished) {
            lastPublished = sample
            publishCount += 1
        }
    }

    #expect(publishCount < samples.count)
    #expect(lastPublished == finalValue)
}

/// `barFraction` must map 0 -> 0 and 1 -> 1, clamp outside 0...1, and stay monotonically increasing
/// regardless of whatever curve step D ends up choosing.
@Test func barFractionMapsRailsAndClampsOutOfRange() {
    #expect(BrightnessScale.barFraction(for: 0) == 0)
    #expect(BrightnessScale.barFraction(for: 1) == 1)
    #expect(BrightnessScale.barFraction(for: -0.5) == 0)
    #expect(BrightnessScale.barFraction(for: 1.5) == 1)
}

@Test func barFractionIsMonotonicallyIncreasing() {
    let samples: [Float] = [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
    var previous: Float = -1
    for sample in samples {
        let mapped = BrightnessScale.barFraction(for: sample)
        #expect(mapped >= previous)
        previous = mapped
    }
}

/// Task 1 step D on-hardware measurement (macOS 26.6/25G72, this machine, see SUMMARY.md for the
/// full transcript and both the fast and slow-timing reproduction runs): dimming to the absolute
/// minimum and stepping the brightness-up key one physical press at a time produced these settled
/// `DisplayServicesGetBrightness` readings. Presses 2-4 are a genuine, reproducible hardware floor
/// (confirmed via a direct registration probe bypassing `BrightnessScale`'s own coalescing) — the
/// raw signal itself does not distinguish them from press 1, so no pure function of `raw` can
/// recover their individual notch-linear positions; they are excluded from the tolerance
/// assertion below for that reason, not overlooked.
private let measuredNotchTable: [(press: Int, raw: Float)] = [
    (1, 0.010000),
    (5, 0.092500),
    (6, 0.175000),
    (7, 0.257500),
    (8, 0.340000),
    (9, 0.422500),
    (10, 0.505000),
    (11, 0.587500),
    (12, 0.670000),
    (13, 0.752500),
    (14, 0.835000),
    (15, 0.917500),
    (16, 1.000000),
]
private let measuredNotchCount: Float = 16

@Test func barFractionMapsEachDistinguishableMeasuredNotchWithinToleranceOfItsLinearPosition() {
    for (press, raw) in measuredNotchTable {
        let mapped = BrightnessScale.barFraction(for: raw)
        let linear = Float(press) / measuredNotchCount
        #expect(abs(mapped - linear) <= 0.06, "press \(press): mapped \(mapped) vs linear \(linear)")
    }
}

/// The measured dark-end symptom itself: at raw 0.01 (four notches of real key-press range,
/// RESEARCH/SUMMARY), the OLD identity mapping rendered under 2% — indistinguishable from empty.
/// The curve must render it meaningfully higher, close to its notch-linear target (1/16).
@Test func barFractionLiftsTheDarkEndOffTheFloor() {
    let mapped = BrightnessScale.barFraction(for: 0.01)
    #expect(mapped > 0.05)
}
