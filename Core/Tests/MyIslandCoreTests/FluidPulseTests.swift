import Foundation
import Testing
@testable import MyIslandCore

/// 07-04 Task 2 (PANEL-07 amended, agreement §6): `FluidPulse.ring`/`glowBeat` port the sketch's
/// finished-timer pulse formulas (index.html:565-575) verbatim — RED phase, written against the
/// plan's own `<behavior>` spec before `FluidPulse.swift` exists.
private let tolerance: CGFloat = 1e-9

@Test func ringBeforeStartIsNil() {
    #expect(FluidPulse.ring(n: 0, elapsed: 0.44, depth: 36) == nil)
    #expect(FluidPulse.ring(n: 0, elapsed: 0.45, depth: 36)?.k == 0)
}

@Test func ringStagger() {
    #expect(FluidPulse.ring(n: 1, elapsed: 1.24, depth: 36) == nil)
    #expect(FluidPulse.ring(n: 1, elapsed: 1.25, depth: 36) != nil)
}

@Test func ringScaleForPill() {
    let ring = FluidPulse.ring(n: 0, elapsed: 1.55, depth: 36)
    #expect(ring != nil)
    #expect(abs((ring?.k ?? -1) - 1) < tolerance)
    #expect(abs((ring?.sx ?? 0) - 1.10) < tolerance)
    #expect(abs((ring?.sy ?? 0) - 1.36) < tolerance)
    #expect(abs((ring?.opacity ?? -1) - 0) < tolerance)
    #expect(abs((ring?.lineWidth ?? 0) - (1.6 / 1.10)) < tolerance)
}

@Test func ringScaleForBulge() {
    let ring = FluidPulse.ring(n: 0, elapsed: 1.55, depth: 9)
    #expect(ring != nil)
    let expectedSy: CGFloat = 1 + 0.9 * (12.0 / 9.0)
    #expect(abs((ring?.sy ?? 0) - expectedSy) < tolerance)
}

@Test func ringAfterWindowIsNil() {
    for n in 0..<3 {
        #expect(FluidPulse.ring(n: n, elapsed: 3.2, depth: 36) == nil)
    }
}

@Test func glowBeatPeaks() {
    #expect(abs(FluidPulse.glowBeat(elapsed: 0.45 + 0.4) - (0.2 + 0.35)) < tolerance)
    #expect(abs(FluidPulse.glowBeat(elapsed: 0.2) - 0.2) < tolerance)
}
