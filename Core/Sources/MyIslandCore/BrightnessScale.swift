import Foundation

/// Pure coalescing + display-curve logic for the brightness HUD (HUD-01).
/// STUB — TDD RED phase. See BrightnessScaleTests.swift for the behavior this must satisfy.
public enum BrightnessScale {
    public static let coalescingThreshold: Float = 0.005

    public static func shouldPublish(new: Float, lastPublished: Float?) -> Bool {
        false // stub: always reject, so the RED tests fail
    }

    public static func barFraction(for raw: Float) -> Float {
        raw // stub: no clamping
    }
}
