/// Pure playing / paused-in-grace / hidden state machine for the Now Playing ear and panel (D-06,
/// D-07, D-12). No AppKit, no adapter/model types — the caller (`NowPlayingProvider`) adapts its own
/// `NowPlayingModel` into the plain, `Sendable` inputs here, mirroring `CalendarEventFilter.swift`'s
/// EventKit-decoupling convention.
///
/// Spike 001 established the real failure mode this guards against: a forgotten Safari tab held a
/// complete, non-playing payload indefinitely, and the adapter falls back to it the moment the active
/// player (Apple Music) quits. A now-playing display that shows anything with a payload — rather than
/// anything the user is *currently listening to* — would surface that stale session as if it were
/// live. The classifier is the single boundary that decides what the user is actually told.
///
/// Source: .planning/phases/05-now-playing/05-CONTEXT.md D-06, D-07, D-12.
import Foundation

/// A session's identity for grace-window purposes (05-01's assumption-delta decision): the primary
/// noun is the *session* (bundle identifier + title/artist pair), not the individual track. A change
/// in any field starts a brand-new session — the previous session's classification and grace deadline
/// are never inherited by it.
public struct NowPlayingSessionIdentity: Sendable, Equatable {
    public let bundleIdentifier: String
    public let title: String
    public let artist: String

    public init(bundleIdentifier: String, title: String, artist: String) {
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.artist = artist
    }
}

/// What the ear/panel currently show for a session.
public enum NowPlayingVisibility: Sendable, Equatable {
    case hidden
    case playing
    case pausedInGrace
}

/// A classification result: the visibility to render, plus the deadline (if any) at which a
/// paused-in-grace session should be re-evaluated and, absent a resume, hidden.
public struct NowPlayingClassification: Sendable, Equatable {
    public let visibility: NowPlayingVisibility
    public let graceDeadline: Date?

    public init(visibility: NowPlayingVisibility, graceDeadline: Date? = nil) {
        self.visibility = visibility
        self.graceDeadline = graceDeadline
    }
}

/// D-06's 30-second grace window and the D-07/D-12 rules that decide when a session earns it.
/// `now` is ALWAYS an injected parameter — no live-clock call inside — so "the app just launched and
/// the session was already stopped" is unit-testable without waiting 30 seconds, exactly as
/// `ThresholdScheduler` does for the calendar countdown.
public enum NowPlayingSessionClassifier {
    public static let gracePeriod: TimeInterval = 30

    public static func classify(
        identity: NowPlayingSessionIdentity?,
        isPlaying: Bool,
        previous: NowPlayingClassification?,
        previousIdentity: NowPlayingSessionIdentity?,
        now: Date
    ) -> NowPlayingClassification {
        // D-12: no session at all is never a pause — the adapter reporting empty is hidden
        // immediately, regardless of whatever was previously showing.
        guard let identity else {
            return NowPlayingClassification(visibility: .hidden, graceDeadline: nil)
        }

        // A different session (bundle identifier, title or artist changed) is evaluated on its own
        // merits — the previous session's classification and grace deadline are discarded before
        // evaluating (D-07 applies per session, not once per app launch).
        let effectivePrevious = (previousIdentity == identity) ? previous : nil

        // A playing session is always visible, with no grace deadline pending — covers both a fresh
        // session and a resume from paused-in-grace in one branch.
        if isPlaying {
            return NowPlayingClassification(visibility: .playing, graceDeadline: nil)
        }

        switch effectivePrevious?.visibility {
        case .playing:
            // D-07: the observed stop transition is the ONLY thing that starts the grace clock.
            return NowPlayingClassification(
                visibility: .pausedInGrace,
                graceDeadline: now.addingTimeInterval(gracePeriod)
            )
        case .pausedInGrace:
            // D-06: keep the existing deadline — paused-in-grace while `now` is strictly before it,
            // hidden once `now` reaches or passes it.
            if let deadline = effectivePrevious?.graceDeadline, now < deadline {
                return NowPlayingClassification(visibility: .pausedInGrace, graceDeadline: deadline)
            }
            return NowPlayingClassification(visibility: .hidden, graceDeadline: nil)
        case .hidden, nil:
            // D-07: an already-stopped session has no claim on the notch — at app launch, any time
            // the ear has been absent, or for a stale fallback session a quit player leaves behind.
            return NowPlayingClassification(visibility: .hidden, graceDeadline: nil)
        }
    }
}
