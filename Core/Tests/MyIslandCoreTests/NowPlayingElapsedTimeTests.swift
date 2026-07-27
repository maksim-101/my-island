import Testing
import Foundation
@testable import MyIslandCore

/// Covers `NowPlayingElapsed`'s `<behavior>` list (05-04 plan): local interpolation while playing,
/// the paused/rate-zero/no-timestamp non-advancing cases, and the progress-fraction clamp/omit
/// rules. Driven entirely through the injected `now`/timestamp parameters — no test sleeps.
/// Units are microseconds throughout, matching the payload's own `elapsedTimeMicros`/
/// `durationMicros`/`timestampEpochMicros` fields (spike 002).
private let microsPerSecond: Double = 1_000_000

@Test func currentMicrosInterpolatesForwardWhilePlaying() {
    let now = Date(timeIntervalSince1970: 1_000)
    let timestamp = now.addingTimeInterval(-5).timeIntervalSince1970 * microsPerSecond
    let result = NowPlayingElapsed.currentMicros(
        elapsedTimeMicros: 30 * microsPerSecond,
        timestampEpochMicros: timestamp,
        playbackRate: 1,
        isPlaying: true,
        now: now
    )
    #expect(result == 35 * microsPerSecond)
}

@Test func currentMicrosStaysAtElapsedWhenPlaybackRateIsZero() {
    let now = Date(timeIntervalSince1970: 1_000)
    let timestamp = now.addingTimeInterval(-60).timeIntervalSince1970 * microsPerSecond
    let result = NowPlayingElapsed.currentMicros(
        elapsedTimeMicros: 30 * microsPerSecond,
        timestampEpochMicros: timestamp,
        playbackRate: 0,
        isPlaying: true,
        now: now
    )
    #expect(result == 30 * microsPerSecond)
}

@Test func currentMicrosStaysAtElapsedWhenNotPlaying() {
    let now = Date(timeIntervalSince1970: 1_000)
    let timestamp = now.addingTimeInterval(-60).timeIntervalSince1970 * microsPerSecond
    let result = NowPlayingElapsed.currentMicros(
        elapsedTimeMicros: 30 * microsPerSecond,
        timestampEpochMicros: timestamp,
        playbackRate: 1,
        isPlaying: false,
        now: now
    )
    #expect(result == 30 * microsPerSecond)
}

@Test func currentMicrosReturnsNilWithNoElapsedValue() {
    let result = NowPlayingElapsed.currentMicros(
        elapsedTimeMicros: nil,
        timestampEpochMicros: 0,
        playbackRate: 1,
        isPlaying: true,
        now: Date(timeIntervalSince1970: 1_000)
    )
    #expect(result == nil)
}

@Test func currentMicrosReturnsElapsedUnchangedWithNoTimestamp() {
    let result = NowPlayingElapsed.currentMicros(
        elapsedTimeMicros: 30 * microsPerSecond,
        timestampEpochMicros: nil,
        playbackRate: 1,
        isPlaying: true,
        now: Date(timeIntervalSince1970: 1_060)
    )
    #expect(result == 30 * microsPerSecond)
}

@Test func fractionComputesRatioWithinDuration() {
    let result = NowPlayingElapsed.fraction(elapsedMicros: 30 * microsPerSecond, durationMicros: 120 * microsPerSecond)
    #expect(result == 0.25)
}

@Test func fractionIsNilForZeroOrNegativeDuration() {
    #expect(NowPlayingElapsed.fraction(elapsedMicros: 10 * microsPerSecond, durationMicros: 0) == nil)
    #expect(NowPlayingElapsed.fraction(elapsedMicros: 10 * microsPerSecond, durationMicros: -5 * microsPerSecond) == nil)
}

@Test func fractionIsNilForMissingElapsedOrDuration() {
    #expect(NowPlayingElapsed.fraction(elapsedMicros: nil, durationMicros: 120 * microsPerSecond) == nil)
    #expect(NowPlayingElapsed.fraction(elapsedMicros: 30 * microsPerSecond, durationMicros: nil) == nil)
}

@Test func fractionClampsBeyondDurationToOne() {
    let result = NowPlayingElapsed.fraction(elapsedMicros: 150 * microsPerSecond, durationMicros: 120 * microsPerSecond)
    #expect(result == 1)
}

@Test func fractionClampsNegativeElapsedToZero() {
    let result = NowPlayingElapsed.fraction(elapsedMicros: -10 * microsPerSecond, durationMicros: 120 * microsPerSecond)
    #expect(result == 0)
}
