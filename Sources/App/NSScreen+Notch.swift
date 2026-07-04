import AppKit
import MyIslandCore

extension NSScreen {
    var hasNotch: Bool {
        notchFrame != nil
    }

    var notchFrame: NSRect? {
        NotchGeometry.notchFrame(
            screenFrame: frame,
            auxiliaryTopLeftWidth: auxiliaryTopLeftArea?.width,
            auxiliaryTopRightWidth: auxiliaryTopRightArea?.width,
            safeAreaTop: safeAreaInsets.top
        )
    }
}
