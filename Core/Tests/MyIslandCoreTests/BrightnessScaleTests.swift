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
    // The three leading measured values from RESEARCH §1.2, followed by a synthesized decelerating
    // (ease-out) tail interpolated down to the measured final value 0.4225 — RESEARCH recorded only
    // the first three and the last of the ~33-sample transcript ("... 30 more ...").
    var samples: [Float] = [0.2771429, 0.2921088, 0.3035115]
    let tailStart: Float = 0.3035115
    let finalValue: Float = 0.4225
    let tailCount = 29
    for index in 1...tailCount {
        let t = Float(index) / Float(tailCount)
        // Ease-out: fast early progress, slowing near the end — matches the shrinking deltas
        // RESEARCH measured between its first three logged samples.
        let eased = 1 - pow(1 - t, 2)
        samples.append(tailStart + (finalValue - tailStart) * eased)
    }
    samples[samples.count - 1] = finalValue

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
