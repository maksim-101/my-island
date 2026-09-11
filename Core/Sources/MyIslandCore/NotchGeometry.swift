import CoreGraphics

public enum NotchGeometry {
    /// A screen either has a physical camera-housing cutout, or gets a drawn
    /// synthetic pill anchored top-center — every screen resolves to exactly
    /// one case, never "no island" (Phase 6 SHELL-06/07; supersedes the
    /// optional `notchFrame` for panel-identity purposes — see `resolveMode`).
    public enum Mode: Equatable, Sendable {
        case physical(CGRect)
        case synthetic(CGRect)

        public var anchorRect: CGRect {
            switch self {
            case .physical(let rect), .synthetic(let rect):
                return rect
            }
        }

        public var isPhysical: Bool {
            if case .physical = self { return true }
            return false
        }
    }

    public static func notchFrame(
        screenFrame: CGRect,
        auxiliaryTopLeftMaxX: CGFloat?,
        auxiliaryTopRightMinX: CGFloat?,
        safeAreaTop: CGFloat
    ) -> CGRect? {
        guard
            let leftMaxX = auxiliaryTopLeftMaxX,
            let rightMinX = auxiliaryTopRightMinX
        else { return nil }

        let notchWidth = rightMinX - leftMaxX
        guard notchWidth > 0 else { return nil }

        return CGRect(
            x: leftMaxX,
            y: screenFrame.maxY - safeAreaTop,
            width: notchWidth,
            height: safeAreaTop
        )
    }

    /// The locked damped-width formula (D-06/D-09, SHELL-06): `160` at the
    /// 1440pt reference width, growing 0.3× as fast as the screen itself
    /// widens beyond that. Unrounded — callers needing display pixels rely on
    /// AppKit's own frame pixel-alignment on `setFrame`, never rounding here.
    public static func dampedPillWidth(screenWidth: CGFloat) -> CGFloat {
        160 * (1 + (screenWidth / 1440 - 1) * 0.3)
    }

    /// D-04/D-06: the pill never exceeds the screen's menu-bar height; when
    /// that reads 0 (auto-hidden menu bar), fall back to the status-bar
    /// thickness so the pill is never zero-height.
    public static func syntheticHeight(menuBarHeight: CGFloat, statusBarThickness: CGFloat) -> CGFloat {
        menuBarHeight > 0 ? menuBarHeight : statusBarThickness
    }

    /// D-06: top-center, flush with the screen's top edge — the synthetic
    /// pill's anchor rect on a notchless screen.
    public static func syntheticAnchor(screenFrame: CGRect, height: CGFloat) -> CGRect {
        let width = dampedPillWidth(screenWidth: screenFrame.width)
        return CGRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
    }

    /// The single call site deciding "notched or not" for a screen — always
    /// returns a usable anchor, never nil (assumption_delta_decision: the
    /// promote invariant). `.physical` when the unchanged `notchFrame(...)`
    /// resolves a cutout, `.synthetic` with the drawn top-center pill
    /// otherwise (including the inverted-aux-edges case, which `notchFrame`
    /// also treats as nil).
    /// D-11: the hover-tracking rect while a panel is collapsed or mid-collapse
    /// — bottom-left-origin AppKit view coordinates matching
    /// `HoverTrackingView.resizeSubviews`. Centered horizontally (x rounded, since
    /// AppKit view geometry is pixel-snapped there) and pinned to the container's
    /// top edge; degenerates to the full container once it has actually shrunk to
    /// the notch's own size. Never consults collapse timing/state — purely a
    /// function of the two sizes involved.
    public static func collapsedHoverRect(containerSize: CGSize, notchSize: CGSize) -> CGRect {
        CGRect(
            x: ((containerSize.width - notchSize.width) / 2).rounded(),
            y: containerSize.height - notchSize.height,
            width: notchSize.width,
            height: notchSize.height
        )
    }

    public static func resolveMode(
        screenFrame: CGRect,
        auxiliaryTopLeftMaxX: CGFloat?,
        auxiliaryTopRightMinX: CGFloat?,
        safeAreaTop: CGFloat,
        menuBarHeight: CGFloat,
        statusBarThickness: CGFloat
    ) -> Mode {
        if let rect = notchFrame(
            screenFrame: screenFrame,
            auxiliaryTopLeftMaxX: auxiliaryTopLeftMaxX,
            auxiliaryTopRightMinX: auxiliaryTopRightMinX,
            safeAreaTop: safeAreaTop
        ) {
            return .physical(rect)
        }
        let height = syntheticHeight(menuBarHeight: menuBarHeight, statusBarThickness: statusBarThickness)
        return .synthetic(syntheticAnchor(screenFrame: screenFrame, height: height))
    }
}
