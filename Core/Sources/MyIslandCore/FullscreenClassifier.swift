import Foundation

/// Facts about the frontmost app's fullscreen state, gathered by `FullscreenObserver` and fed to
/// `FullscreenClassifier.decide(_:)`. `axFocusedWindowTitleIsEmpty` deliberately carries a
/// **boolean**, not the title string: the emptiness test is the only thing the classifier needs,
/// so a window title from another process never crosses out of the AX read site (Pitfall 3 /
/// T-05-14 privacy posture).
public struct FullscreenFacts: Sendable, Equatable {
    public let isAppFullscreen: Bool
    public let isBrowser: Bool
    public let axFocusedWindowIsFullscreen: Bool?
    public let axFocusedWindowSubrole: String?
    public let axFocusedWindowTitleIsEmpty: Bool?

    public init(
        isAppFullscreen: Bool,
        isBrowser: Bool,
        axFocusedWindowIsFullscreen: Bool?,
        axFocusedWindowSubrole: String?,
        axFocusedWindowTitleIsEmpty: Bool?
    ) {
        self.isAppFullscreen = isAppFullscreen
        self.isBrowser = isBrowser
        self.axFocusedWindowIsFullscreen = axFocusedWindowIsFullscreen
        self.axFocusedWindowSubrole = axFocusedWindowSubrole
        self.axFocusedWindowTitleIsEmpty = axFocusedWindowTitleIsEmpty
    }
}

/// What the ambient collapsed row should do.
public enum AmbientRowDecision: Sendable, Equatable {
    case show
    case suppress
}

/// STUB — TDD RED phase. See FullscreenClassifierTests.swift for the behavior this must satisfy.
public enum FullscreenClassifier {
    public static let standardWindowSubrole = "AXStandardWindow"

    public static func decide(_ facts: FullscreenFacts) -> AmbientRowDecision {
        .show // stub: always show, so the RED tests fail
    }
}
