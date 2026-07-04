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
}
