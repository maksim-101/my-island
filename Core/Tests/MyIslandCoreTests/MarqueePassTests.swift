import CoreGraphics
import Testing
@testable import MyIslandCore

/// Test names trace back to 05-06-PLAN.md's `<behavior>` list, one test per pinned rule.

// MARK: - bounded (T-05-07 hostile-metadata cap)

@Test func boundedLeavesShortStringUnchanged() {
    let text = String(repeating: "a", count: 300)
    #expect(MarqueePass.bounded(text) == text)
}

@Test func boundedTruncatesLongStringToExactlyMaxCharacters() {
    let text = String(repeating: "a", count: 500)
    let bounded = MarqueePass.bounded(text)
    #expect(bounded.count == MarqueePass.maxCharacters)
    #expect(bounded == String(text.prefix(MarqueePass.maxCharacters)))
}

// MARK: - overflow

@Test func overflowIsZeroWhenTextNarrowerThanViewport() {
    #expect(MarqueePass.overflow(textWidth: 100, viewportWidth: 200) == 0)
}

@Test func overflowIsZeroWhenTextExactlyFillsViewport() {
    #expect(MarqueePass.overflow(textWidth: 150, viewportWidth: 150) == 0)
}

@Test func overflowIsPositiveDifferenceWhenTextWiderThanViewport() {
    #expect(MarqueePass.overflow(textWidth: 250, viewportWidth: 150) == 100)
}

@Test func overflowIsZeroWhenViewportWidthIsZeroOrNegative() {
    #expect(MarqueePass.overflow(textWidth: 250, viewportWidth: 0) == 0)
    #expect(MarqueePass.overflow(textWidth: 250, viewportWidth: -10) == 0)
}

// MARK: - scrollSeconds (rate-based, clamped 2...12)

@Test func scrollSecondsForOverflow300IsTenSecondsAtThirtyPointsPerSecond() {
    #expect(MarqueePass.scrollSeconds(overflow: 300) == 10)
}

@Test func scrollSecondsFloorsAtTwoSecondsForSmallOverflow() {
    // 15pt / 30pt/s = 0.5s, floored to the 2s minimum.
    #expect(MarqueePass.scrollSeconds(overflow: 15) == 2)
}

@Test func scrollSecondsCeilingsAtTwelveSecondsForLargeOverflow() {
    // 600pt / 30pt/s = 20s, clamped to the 12s maximum.
    #expect(MarqueePass.scrollSeconds(overflow: 600) == 12)
}

// MARK: - offset: fitting text never moves

@Test func offsetIsZeroAtEveryElapsedValueWhenOverflowIsZero() {
    for elapsed in [0.0, 1.0, 5.0, 100.0, 1000.0] {
        #expect(MarqueePass.offset(overflow: 0, elapsed: elapsed) == 0)
    }
}

// MARK: - offset: opening hold

@Test func offsetIsZeroThroughoutOpeningHold() {
    let overflow: CGFloat = 300
    #expect(MarqueePass.offset(overflow: overflow, elapsed: 0) == 0)
    #expect(MarqueePass.offset(overflow: overflow, elapsed: 0.5) == 0)
    #expect(MarqueePass.offset(overflow: overflow, elapsed: 1.499) == 0)
}

// MARK: - offset: scroll-out phase

@Test func offsetIsNegativeStrictlyDecreasingAndBoundedDuringScrollOut() {
    let overflow: CGFloat = 300
    let scrollStart = MarqueePass.startHoldSeconds
    let scrollDuration = MarqueePass.scrollSeconds(overflow: overflow)
    let samples = stride(from: 0.0, through: scrollDuration, by: scrollDuration / 10)
        .map { MarqueePass.offset(overflow: overflow, elapsed: scrollStart + $0) }

    for value in samples {
        #expect(value <= 0)
        #expect(abs(value) <= overflow)
    }
    for i in 1..<samples.count {
        #expect(samples[i] < samples[i - 1])
    }
}

@Test func offsetEqualsNegatedOverflowAtInstantScrollOutEnds() {
    let overflow: CGFloat = 300
    let holdEndStart = MarqueePass.startHoldSeconds + MarqueePass.scrollSeconds(overflow: overflow)
    #expect(MarqueePass.offset(overflow: overflow, elapsed: holdEndStart) == -overflow)
}

// MARK: - offset: end hold

@Test func offsetStaysAtNegatedOverflowThroughoutEndHold() {
    let overflow: CGFloat = 300
    let holdEndStart = MarqueePass.startHoldSeconds + MarqueePass.scrollSeconds(overflow: overflow)
    #expect(MarqueePass.offset(overflow: overflow, elapsed: holdEndStart) == -overflow)
    #expect(MarqueePass.offset(overflow: overflow, elapsed: holdEndStart + 1) == -overflow)
    #expect(MarqueePass.offset(overflow: overflow, elapsed: holdEndStart + MarqueePass.endHoldSeconds - 0.001) == -overflow)
}

// MARK: - offset: return phase

@Test func offsetRisesBackToZeroAcrossReturnPhaseAndReachesZeroAtCycleEnd() {
    let overflow: CGFloat = 300
    let returnStart = MarqueePass.startHoldSeconds + MarqueePass.scrollSeconds(overflow: overflow) + MarqueePass.endHoldSeconds
    let returnDuration = MarqueePass.returnSeconds(overflow: overflow)
    let cycle = MarqueePass.cycleSeconds(overflow: overflow)
    #expect(cycle == returnStart + returnDuration)

    let mid = MarqueePass.offset(overflow: overflow, elapsed: returnStart + returnDuration / 2)
    #expect(mid > -overflow)
    #expect(mid < 0)

    // Elapsed wraps to exactly 0 at the top of the next cycle, which is offset 0 (opening hold).
    #expect(MarqueePass.offset(overflow: overflow, elapsed: cycle) == 0)
}

// MARK: - offset: periodicity

@Test func offsetRepeatsWithNoDriftAcrossCycleBoundary() {
    let overflow: CGFloat = 300
    let cycle = MarqueePass.cycleSeconds(overflow: overflow)
    for t in [0.0, 1.0, 5.0, 12.0, 16.0] {
        #expect(MarqueePass.offset(overflow: overflow, elapsed: t + cycle) == MarqueePass.offset(overflow: overflow, elapsed: t))
    }
}

// MARK: - offset: degenerate inputs

@Test func offsetIsZeroForNegativeElapsed() {
    #expect(MarqueePass.offset(overflow: 300, elapsed: -1) == 0)
}

@Test func offsetIsAlwaysFinite() {
    let overflows: [CGFloat] = [-100, 0, 0.001, 15, 300, 600, 10000]
    let elapsedValues = [-100.0, -1.0, 0.0, 0.5, 1.5, 5.0, 18.5, 1000.0]
    for overflow in overflows {
        for elapsed in elapsedValues {
            let value = MarqueePass.offset(overflow: overflow, elapsed: elapsed)
            #expect(value.isFinite)
        }
    }
}
