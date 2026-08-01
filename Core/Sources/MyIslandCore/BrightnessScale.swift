import Foundation

/// Pure coalescing + display-curve logic for the brightness HUD (HUD-01). No AppKit, no Foundation
/// clock — mirrors `NowPlayingSessionClassifier`'s decoupling convention so `BrightnessProvider`
/// stays a thin adapter around a tested core.
///
/// Source: RESEARCH.md §1.2 (measured ~55-60 `DisplayServicesRegisterForBrightnessChangeNotifications`
/// callbacks/second during a held-key ramp, Pitfall 6) and CONTEXT.md's "Post-research decisions"
/// dark-end symptom.
public enum BrightnessScale {
    /// RESEARCH §1.2 measured a smooth animated ramp of ~16 callbacks per key press (e.g. 0.2575 ->
    /// 0.2771429 -> 0.2921088 -> 0.3035115 -> ... -> 0.4225 across two presses). Publishing every
    /// callback straight into an `@Observable` would drive ~16 SwiftUI invalidations per key press
    /// (Pitfall 6); 0.005 discards sub-perceptible deltas while still tracking the ramp closely
    /// enough to read as continuous.
    public static let coalescingThreshold: Float = 0.005

    /// Whether a new raw brightness reading should be published to the observable model.
    /// - `lastPublished == nil`: always publish — the first value must always render.
    /// - `new` is exactly the rail (0.0 or 1.0): always publish, so the dark/bright extremes are
    ///   never left stuck at whatever the coalescing window last let through.
    /// - Otherwise: publish only when `new` differs from `lastPublished` by at least
    ///   `coalescingThreshold`.
    public static func shouldPublish(new: Float, lastPublished: Float?) -> Bool {
        guard let lastPublished else { return true }
        if new <= 0 || new >= 1 { return true }
        return abs(new - lastPublished) >= coalescingThreshold
    }

    /// Maps a raw `DisplayServicesGetBrightness` reading (0...1, perceptual/slider scale, see
    /// RESEARCH §1.1) onto the HUD bar's fill fraction. Currently clamped identity — Task 1 step D's
    /// on-hardware dark-end measurement (see the SUMMARY for the recorded notch->raw-value table)
    /// found the reading already close to notch-linear, so no curve correction is applied here; the
    /// reported dark-end symptom was caused by the poll rate and the glitch suppressor, both removed
    /// from `BrightnessProvider`.
    public static func barFraction(for raw: Float) -> Float {
        min(1, max(0, raw))
    }
}
