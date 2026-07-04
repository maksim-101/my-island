public enum AppIdentity {
    public static let bundleID = "com.maksim101.myisland"

    public static func centeredOriginX(screenWidth: Double, overlayWidth: Double) -> Double {
        (screenWidth - overlayWidth) / 2
    }
}
