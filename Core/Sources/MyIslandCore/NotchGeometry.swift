import CoreGraphics

public enum NotchGeometry {
    public static func notchFrame(
        screenFrame: CGRect,
        auxiliaryTopLeftWidth: CGFloat?,
        auxiliaryTopRightWidth: CGFloat?,
        safeAreaTop: CGFloat
    ) -> CGRect? {
        guard
            let leftWidth = auxiliaryTopLeftWidth,
            let rightWidth = auxiliaryTopRightWidth
        else { return nil }

        let notchWidth = screenFrame.width - leftWidth - rightWidth
        return CGRect(
            x: screenFrame.midX - notchWidth / 2,
            y: screenFrame.maxY - safeAreaTop,
            width: notchWidth,
            height: safeAreaTop
        )
    }
}
