import SwiftUI

/// Single source of truth for expanded-panel sizing and the open/close morph
/// animation, shared by the AppKit window sizing in `NotchPanelController`
/// and the SwiftUI content sizing in `NotchContentView` so they cannot drift.
enum NotchLayout {
    static let expandedWidthMultiplier: CGFloat = 2.2
    // Tall enough to show ExpandedPanelView's full content stack — title +
    // Timer group (mode switch, ring/readout, and the preset/Start row) +
    // Clipboard group. At 160 the preset row (incl. the "Start" button and
    // duration stepper) and the entire Clipboard section were clipped below
    // the panel's masked bottom edge, so a countdown could not be started
    // (measured natural height at width 407 ≈ 272pt; verified via render harness).
    static let expandedHeight: CGFloat = 320
    static let morphAnimation: Animation = .interactiveSpring(response: 0.38, dampingFraction: 0.8)

    /// Delay before the expanded content fades in, so it visually trails the
    /// box growth instead of popping in ahead of it (DEFECT B).
    static let expandContentDelay: TimeInterval = 0.08

    /// How long to wait after collapse begins before shrinking the AppKit
    /// window back to notch size — longer than `morphAnimation`'s 0.38s
    /// response so the window doesn't snap in while content is still visibly
    /// collapsing.
    static let collapseWindowDelay: TimeInterval = 0.45

    /// How long the cursor must dwell over the notch before it expands.
    /// Driven by `NotchPanelController`'s `NSTrackingArea`-based hover
    /// detection (SHELL-11 fix) rather than SwiftUI `.onHover`.
    static let hoverDwellDelay: TimeInterval = 0.25

    /// Grace period after the cursor leaves before the notch collapses —
    /// avoids flicker on momentary pointer blips.
    static let hoverCollapseGrace: TimeInterval = 0.1

    /// Gap between the notch's bottom edge and the top of the detached Ambient
    /// HUD glass pill that floats below it (HUDPillView) — kept tight so the
    /// pill reads as hanging just under the notch.
    static let hudPillGap: CGFloat = 2

    /// How long the HUD stays up after the LAST brightness/volume change
    /// before fading and reverting to the timer/idle collapsed content
    /// (D-05).
    static let hudFadeDelay: TimeInterval = 1.5
}
