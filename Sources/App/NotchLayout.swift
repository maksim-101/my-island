import SwiftUI

/// Single source of truth for expanded-panel sizing and the open/close morph
/// animation, shared by the AppKit window sizing in `NotchPanelController`
/// and the SwiftUI content sizing in `NotchContentView` so they cannot drift.
enum NotchLayout {
    static let expandedWidthMultiplier: CGFloat = 2.2
    static let expandedHeight: CGFloat = 160
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
}
