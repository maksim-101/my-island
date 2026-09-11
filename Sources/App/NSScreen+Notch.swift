import AppKit
import MyIslandCore

extension NSScreen {
    var hasNotch: Bool {
        notchFrame != nil
    }

    var notchFrame: NSRect? {
        NotchGeometry.notchFrame(
            screenFrame: frame,
            auxiliaryTopLeftMaxX: auxiliaryTopLeftArea?.maxX,
            auxiliaryTopRightMinX: auxiliaryTopRightArea?.minX,
            safeAreaTop: safeAreaInsets.top
        )
    }

    /// The menu-bar strip height on THIS screen — `frame` includes it,
    /// `visibleFrame` doesn't (Pitfall 3: reads 0 from a bare process before
    /// `NSApplication` finishes launching; only meaningful once launched).
    var menuBarHeight: CGFloat {
        frame.maxY - visibleFrame.maxY
    }

    /// Physical cutout or drawn synthetic pill — every screen resolves to
    /// exactly one case (Phase 6 SHELL-06/07).
    var notchMode: NotchGeometry.Mode {
        NotchGeometry.resolveMode(
            screenFrame: frame,
            auxiliaryTopLeftMaxX: auxiliaryTopLeftArea?.maxX,
            auxiliaryTopRightMinX: auxiliaryTopRightArea?.minX,
            safeAreaTop: safeAreaInsets.top,
            menuBarHeight: menuBarHeight,
            statusBarThickness: NSStatusBar.system.thickness
        )
    }

    /// Mirrors `FullscreenObserver.swift`'s `NSDeviceDescriptionKey("NSScreenNumber")`
    /// idiom — the CoreGraphics display identifier backing this `NSScreen`.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    /// A stable identifier across reconnects to the same physical display —
    /// nil only when `displayID` itself is unavailable, or the display has no
    /// resolvable UUID (some virtual/ghost displays). Callers use `displayKey`
    /// for a fallback that is never nil.
    var displayUUID: String? {
        guard let displayID, let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        return CFUUIDCreateString(nil, cfUUID.takeRetainedValue()) as String
    }

    /// Panel-identity key (Phase 6 SHELL-07): fragile-signal convention — a
    /// nil UUID degrades to a still-stable `displayID`-based key, then to the
    /// frame string, never to "no panel" (T-06-02).
    var displayKey: String {
        displayUUID ?? displayID.map { "id:\($0)" } ?? "frame:" + NSStringFromRect(frame)
    }
}
