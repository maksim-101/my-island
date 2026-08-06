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

/// Decides whether the ambient collapsed row should suppress for the frontmost app's current
/// fullscreen state. This is a "chromeless takeover" test, not a "video" test (RESEARCH §2.5): any
/// app that presents a titleless, non-standard fullscreen window is treated the same as a video
/// player, which is broader than "video" but is the correct behavior for an ambient HUD — a
/// slideshow or presentation-mode app should suppress the row too.
///
/// Chromium-family browsers (Vivaldi, Chrome, Edge, Brave, Arc) are structurally undetectable
/// (RESEARCH §2.3 — measured negative result: element-fullscreen and Spaces-fullscreen are
/// byte-identical across AX subrole, `AXFullScreen`, bounds and child roles) and therefore land in
/// the never-suppress branch by measurement, not by omission — see README.md's "Known
/// Limitations" section.
public enum FullscreenClassifier {
    public static let standardWindowSubrole = "AXStandardWindow"

    public static func decide(_ facts: FullscreenFacts) -> AmbientRowDecision {
        guard facts.isAppFullscreen else { return .show }
        guard facts.isBrowser else { return .suppress }

        // Incomplete AX facts (Accessibility not granted, or any single field failed to resolve)
        // fail toward showing — matches the Chromium policy rather than guessing.
        guard let axFullscreen = facts.axFocusedWindowIsFullscreen, axFullscreen,
              let subrole = facts.axFocusedWindowSubrole,
              let titleIsEmpty = facts.axFocusedWindowTitleIsEmpty
        else {
            return .show
        }

        return (subrole != standardWindowSubrole || titleIsEmpty) ? .suppress : .show
    }
}
