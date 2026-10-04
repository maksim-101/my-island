import SwiftUI

/// D-06 Wave 2 (07-08): the old expanded-panel's own fixed sizing/content-delay/window-shrink-delay
/// constants and its SwiftUI cross-fade spring are retired entirely — the band's open/close motion
/// is driven purely by `FluidMotion`'s spring clock (`NotchPanelController.openFrame`/
/// `FluidMotion.whenSettled`), never by SwiftUI's own animation transactions (RESEARCH.md
/// Pitfall 2). What remains here are the hover/alert timing constants nothing in this plan touches.
enum NotchLayout {
    /// How long the cursor must dwell over the notch before it expands.
    /// Driven by `NotchPanelController`'s `NSTrackingArea`-based hover
    /// detection (SHELL-11 fix) rather than SwiftUI `.onHover`. Raised from 0.25 (quick 261004-ah2)
    /// so a pointer passing through the notch toward a tab bar just below does not open it.
    static let hoverDwellDelay: TimeInterval = 0.35

    /// Grace period after the cursor leaves before the notch collapses —
    /// avoids flicker on momentary pointer blips.
    static let hoverCollapseGrace: TimeInterval = 0.1

    /// How long the HUD stays up after the LAST brightness/volume change
    /// before fading and reverting to the timer/idle collapsed content
    /// (D-05).
    static let hudFadeDelay: TimeInterval = 1.5

    /// How long the meeting-countdown bump (CAL-01/D-02) stays up before
    /// fading — longer than `hudFadeDelay` because a full "{title} in {N}m"
    /// sentence needs more read time than the brightness/volume nudge; ~2.5s
    /// matches the locked sketch's bump dwell.
    static let meetingBumpFadeDelay: TimeInterval = 6.0
}
