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

    /// Task 1 step D on-hardware measurement (macOS 26.6/25G72, see SUMMARY.md for the full
    /// transcript, both the fast-timing and generously-spaced reproduction runs): dimming to the
    /// absolute minimum then stepping the brightness-up key one physical press at a time, four of
    /// the sixteen presses (1-4) settled at the SAME raw reading (0.01) — a genuine, reproducible
    /// hardware floor confirmed via a direct registration probe that bypasses this file's own
    /// coalescing, not a measurement artifact. From press 5 onward the raw reading is linear
    /// (+0.0825/press) and fully distinguishable. This matches the reported symptom exactly: the
    /// bar rendered under 2% (indistinguishable from empty) while four notches of real key-press
    /// range remained above it.
    ///
    /// `notchCount` (16) is macOS's standard brightness-key step count, exercised directly in the
    /// measurement (16 presses, absolute minimum to absolute maximum). `rawAtLowestNonZeroNotch`
    /// (0.01) is press 1's settled reading, per the decision rule: raw < 0.10 for all four lowest
    /// notches triggers a curve correction.
    private static let notchCount: Float = 16
    private static let rawAtLowestNonZeroNotch: Float = 0.01

    /// Where `rawAtLowestNonZeroNotch` (press 1) should land: "one notch up", not "almost nothing".
    private static let floorTarget: Float = 1 / notchCount

    /// Slope of the above-floor segment, solved so raw = 1 maps to displayed = 1 (continuous with
    /// `floorTarget` at `rawAtLowestNonZeroNotch`, reaching exactly 1 at the top rail): `(1 -
    /// floorTarget) / (1 - rawAtLowestNonZeroNotch) ≈ 0.947`.
    ///
    /// **260801-7h2-regressions correction:** the previous curve was `pow(raw, 0.602)` applied
    /// across the FULL 0...1 range — solved to lift press 1 correctly, but its derivative (`0.602 *
    /// raw^-0.398`) exceeds 1 for every raw below ~0.28, amplifying step size through the entire
    /// lower-middle range instead of only at the floor it was meant to fix (confirmed live: a
    /// standalone calculation of this exact curve reproduced the user's reported symptom precisely
    /// — step size visibly grows starting right around displayed ≈30%, matching press 5→6). A
    /// two-piece **linear** map fixes this: below the floor, a steep-but-constant slope lifts press
    /// 1 to `floorTarget`; above it, a near-1 constant slope tracks `raw` almost 1:1 (matching "up
    /// tracks the real system change" — the behavior the user confirmed was already correct) with
    /// no region of super-linear amplification anywhere.
    private static let aboveFloorSlope: Float = (1 - floorTarget) / (1 - rawAtLowestNonZeroNotch)

    /// Maps a raw `DisplayServicesGetBrightness` reading (0...1, perceptual/slider scale, see
    /// RESEARCH §1.1) onto the HUD bar's fill fraction. A pure function of `raw` cannot invent
    /// information the hardware doesn't report — presses 2-4 will still render identically to
    /// press 1 (there is nothing in `raw` to distinguish them) — but below the floor the curve lifts
    /// that reading from near-invisible (~1%) to clearly visible (~6.25%), and above the floor it
    /// tracks `raw` at a near-1 constant slope, so step size stays consistent with the real change
    /// throughout the resolvable range instead of growing as brightness dims.
    public static func barFraction(for raw: Float) -> Float {
        let clamped = min(1, max(0, raw))
        guard clamped > 0 else { return 0 }
        guard clamped > rawAtLowestNonZeroNotch else {
            return clamped * (floorTarget / rawAtLowestNonZeroNotch)
        }
        return min(1, floorTarget + (clamped - rawAtLowestNonZeroNotch) * aboveFloorSlope)
    }
}
