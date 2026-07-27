import Testing
import Foundation
@testable import MyIslandCore

private let baseDate = Date(timeIntervalSince1970: 0)

private let musicSession = NowPlayingSessionIdentity(
    bundleIdentifier: "com.apple.Music",
    title: "Track A",
    artist: "Artist A"
)

private let safariSession = NowPlayingSessionIdentity(
    bundleIdentifier: "com.apple.Safari",
    title: "Episode 1",
    artist: "Some Show"
)

@Test func playingSessionWithNoPreviousVisibilityIsVisible() {
    let result = NowPlayingSessionClassifier.classify(
        identity: musicSession,
        isPlaying: true,
        previous: nil,
        previousIdentity: nil,
        now: baseDate
    )
    #expect(result.visibility == .playing)
    #expect(result.graceDeadline == nil)
}

/// The launched-while-stopped case (D-07): a session that is not playing and has no previous
/// visibility — either the app just launched, or the ear has been absent — is hidden immediately and
/// arms no grace window. This is the stale-forgotten-tab case from spike 001.
@Test func notPlayingSessionWithNoPreviousVisibilityIsHiddenAndArmsNoGrace() {
    let result = NowPlayingSessionClassifier.classify(
        identity: safariSession,
        isPlaying: false,
        previous: nil,
        previousIdentity: nil,
        now: baseDate
    )
    #expect(result.visibility == .hidden)
    #expect(result.graceDeadline == nil)
}

@Test func sessionThatWasPlayingAndStopsEntersPausedInGraceWithA30SecondDeadline() {
    let previous = NowPlayingClassification(visibility: .playing, graceDeadline: nil)
    let result = NowPlayingSessionClassifier.classify(
        identity: musicSession,
        isPlaying: false,
        previous: previous,
        previousIdentity: musicSession,
        now: baseDate
    )
    #expect(result.visibility == .pausedInGrace)
    #expect(result.graceDeadline == baseDate.addingTimeInterval(NowPlayingSessionClassifier.gracePeriod))
}

@Test func sameNonPlayingSessionAtOrAfterTheGraceDeadlineIsHiddenButOneSecondBeforeIsStillPausedInGrace() {
    let stopInstant = baseDate
    let deadline = stopInstant.addingTimeInterval(NowPlayingSessionClassifier.gracePeriod)
    let previous = NowPlayingClassification(visibility: .pausedInGrace, graceDeadline: deadline)

    let atDeadline = NowPlayingSessionClassifier.classify(
        identity: musicSession,
        isPlaying: false,
        previous: previous,
        previousIdentity: musicSession,
        now: deadline
    )
    #expect(atDeadline.visibility == .hidden)
    #expect(atDeadline.graceDeadline == nil)

    let oneSecondBeforeDeadline = NowPlayingSessionClassifier.classify(
        identity: musicSession,
        isPlaying: false,
        previous: previous,
        previousIdentity: musicSession,
        now: deadline.addingTimeInterval(-1)
    )
    #expect(oneSecondBeforeDeadline.visibility == .pausedInGrace)
    #expect(oneSecondBeforeDeadline.graceDeadline == deadline)

    let afterDeadline = NowPlayingSessionClassifier.classify(
        identity: musicSession,
        isPlaying: false,
        previous: previous,
        previousIdentity: musicSession,
        now: deadline.addingTimeInterval(1)
    )
    #expect(afterDeadline.visibility == .hidden)
    #expect(afterDeadline.graceDeadline == nil)
}

@Test func sameNonPlayingSession29SecondsAfterStopIsStillPausedInGrace() {
    let stopInstant = baseDate
    let deadline = stopInstant.addingTimeInterval(NowPlayingSessionClassifier.gracePeriod)
    let previous = NowPlayingClassification(visibility: .pausedInGrace, graceDeadline: deadline)

    let result = NowPlayingSessionClassifier.classify(
        identity: musicSession,
        isPlaying: false,
        previous: previous,
        previousIdentity: musicSession,
        now: stopInstant.addingTimeInterval(29)
    )
    #expect(result.visibility == .pausedInGrace)
    #expect(result.graceDeadline == deadline)
}

@Test func sessionThatResumesPlayingWhilePausedInGraceIsVisibleAgainWithNoDeadline() {
    let deadline = baseDate.addingTimeInterval(NowPlayingSessionClassifier.gracePeriod)
    let previous = NowPlayingClassification(visibility: .pausedInGrace, graceDeadline: deadline)

    let result = NowPlayingSessionClassifier.classify(
        identity: musicSession,
        isPlaying: true,
        previous: previous,
        previousIdentity: musicSession,
        now: baseDate.addingTimeInterval(5)
    )
    #expect(result.visibility == .playing)
    #expect(result.graceDeadline == nil)
}

/// The adapter's empty state (D-12) is never a pause — it is hidden immediately regardless of
/// whatever visibility preceded it, including mid-grace.
@Test func emptyFrameIsHiddenImmediatelyRegardlessOfPreviousVisibility() {
    let deadline = baseDate.addingTimeInterval(NowPlayingSessionClassifier.gracePeriod)
    let previous = NowPlayingClassification(visibility: .pausedInGrace, graceDeadline: deadline)

    let result = NowPlayingSessionClassifier.classify(
        identity: nil,
        isPlaying: false,
        previous: previous,
        previousIdentity: musicSession,
        now: baseDate.addingTimeInterval(5)
    )
    #expect(result.visibility == .hidden)
    #expect(result.graceDeadline == nil)
}

/// A different session arriving while the previous one is paused-in-grace does not inherit that
/// deadline: it is shown only if it is itself playing, hidden otherwise.
@Test func differentSessionArrivingDuringAnothersGraceWindowDoesNotInheritThatDeadline() {
    let oldDeadline = baseDate.addingTimeInterval(NowPlayingSessionClassifier.gracePeriod)
    let previous = NowPlayingClassification(visibility: .pausedInGrace, graceDeadline: oldDeadline)

    let newSessionPlaying = NowPlayingSessionClassifier.classify(
        identity: safariSession,
        isPlaying: true,
        previous: previous,
        previousIdentity: musicSession,
        now: baseDate.addingTimeInterval(5)
    )
    #expect(newSessionPlaying.visibility == .playing)
    #expect(newSessionPlaying.graceDeadline == nil)

    let newSessionNotPlaying = NowPlayingSessionClassifier.classify(
        identity: safariSession,
        isPlaying: false,
        previous: previous,
        previousIdentity: musicSession,
        now: baseDate.addingTimeInterval(5)
    )
    #expect(newSessionNotPlaying.visibility == .hidden)
    #expect(newSessionNotPlaying.graceDeadline == nil)
}
