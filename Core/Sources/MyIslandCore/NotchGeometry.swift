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

    /// D-01: the content-driven floor for the synthetic pill's drawn width —
    /// idle stays at the damped formula's `idleWidth`; the live readout
    /// layout (artwork + center text + timer) may widen it further, never
    /// shrink it below the formula.
    public static func syntheticWidth(idleWidth: CGFloat, contentWidth: CGFloat) -> CGFloat {
        max(idleWidth, contentWidth)
    }

    /// D-04: every readout on the drawn pill scales proportionally to the
    /// pill's own height, referenced against the built-in's physical notch
    /// height (32pt) — the size the v1.0 readouts were designed for. Never
    /// exceeds 1 (a taller-than-32pt pill does not enlarge readouts), and a
    /// degenerate (zero or negative) height never collapses them to nothing.
    public static func readoutScale(pillHeight: CGFloat) -> CGFloat {
        guard pillHeight > 0 else { return 1 }
        return min(1, pillHeight / 32)
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

    /// 260912 iterm2-fullscreen-detection: whether `bounds` fills `displayBounds` from
    /// `topInset` down, within `tolerance` on every edge — a generic geometry primitive, `topInset`
    /// entirely caller-supplied. **260912-menubar-coverage-rule:** `FullscreenObserver` originally
    /// tried three candidate insets per screen (0 / safe-area height / menu-bar height); it now
    /// calls this with `topInset: 0` only — "fills the literal full display frame," i.e. the menu
    /// bar is actually obscured — since the wider set let a window that leaves the menu bar visible
    /// still count as fullscreen, which the user does not consider fullscreen. This function itself
    /// is unchanged and still general; only its one caller's argument narrowed.
    public static func fillsDisplay(bounds: CGRect, displayBounds: CGRect, topInset: CGFloat, tolerance: CGFloat) -> Bool {
        let candidate = CGRect(
            x: displayBounds.minX,
            y: displayBounds.minY + topInset,
            width: displayBounds.width,
            height: displayBounds.height - topInset
        )
        return abs(bounds.minX - candidate.minX) <= tolerance &&
            abs(bounds.minY - candidate.minY) <= tolerance &&
            abs(bounds.width - candidate.width) <= tolerance &&
            abs(bounds.height - candidate.height) <= tolerance
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
