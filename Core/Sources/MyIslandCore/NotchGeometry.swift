import CoreGraphics

public enum NotchGeometry {
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
}
