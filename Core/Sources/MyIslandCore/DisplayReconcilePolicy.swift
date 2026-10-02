import CoreGraphics

/// One display's geometry as `NotchPanelController.rebuildPanels()` compares it between two
/// reconciles (Phase 8 SHELL-09). Frames are in global screen coordinates; the policy only ever
/// compares them relative to the display's own origin.
public struct DisplayGeometry: Equatable, Sendable {
    public let screenFrame: CGRect
    public let anchorRect: CGRect
    public let isPhysical: Bool
    public let menuBarHeight: CGFloat

    public init(screenFrame: CGRect, anchorRect: CGRect, isPhysical: Bool, menuBarHeight: CGFloat) {
        self.screenFrame = screenFrame
        self.anchorRect = anchorRect
        self.isPhysical = isPhysical
        self.menuBarHeight = menuBarHeight
    }
}

/// Decides, per surviving display key, whether its panel set must be rebuilt or only repositioned
/// (`NotchPanelController.rebuildPanels()` is the caller; no AppKit here).
///
/// Root cause of the Phase 6 `rebuilt=2` on the Dell resize: the old check compared anchor rect and
/// `frame.maxY` in global coordinates, and resizing one display shifts the global origin of every
/// display arranged beside it, so an untouched built-in looked changed. Here a display counts as
/// changed only when its own geometry changed: mode, size, or the anchor rect relative to its own
/// screen origin. A pure translation keeps the set; the caller re-asserts the windows through
/// `reapplyFrames`.
///
/// Menu-bar height (2026-09-27 regression): `NSScreen.menuBarHeight` is `frame.maxY -
/// visibleFrame.maxY` and reads 0 whenever any app goes native fullscreen and the menu bar
/// auto-hides; `didChangeScreenParametersNotification` fires on exactly that transition. Rebuilding
/// then reset every `FluidMotion` channel, including a running timer's outline spring, to 0.
/// `FluidParams.macBookPill` already floors depth at the notch height, so a transient 0 changes no
/// drawn geometry, and only a currently-visible reading that differs from the stored one rebuilds.
public enum DisplayReconcilePolicy {
    public enum Reason: String, Equatable, Sendable {
        case mode, size, anchor, menuBar
    }

    public enum Decision: Equatable, Sendable {
        case keep
        case rebuild(Reason)
    }

    private static let tolerance: CGFloat = 0.01

    public static func decide(previous: DisplayGeometry, current: DisplayGeometry) -> Decision {
        if previous.isPhysical != current.isPhysical { return .rebuild(.mode) }
        if !close(previous.screenFrame.width, current.screenFrame.width)
            || !close(previous.screenFrame.height, current.screenFrame.height) {
            return .rebuild(.size)
        }
        if !relativeAnchorMatches(previous, current) { return .rebuild(.anchor) }
        if current.menuBarHeight > 0, !close(previous.menuBarHeight, current.menuBarHeight) {
            return .rebuild(.menuBar)
        }
        return .keep
    }

    private static func relativeAnchorMatches(_ a: DisplayGeometry, _ b: DisplayGeometry) -> Bool {
        close(a.anchorRect.minX - a.screenFrame.minX, b.anchorRect.minX - b.screenFrame.minX)
            && close(a.anchorRect.minY - a.screenFrame.minY, b.anchorRect.minY - b.screenFrame.minY)
            && close(a.anchorRect.width, b.anchorRect.width)
            && close(a.anchorRect.height, b.anchorRect.height)
    }

    private static func close(_ a: CGFloat, _ b: CGFloat) -> Bool {
        abs(a - b) < tolerance
    }
}
