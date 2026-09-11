import Foundation

/// Pure threshold logic for the MediaRemote adapter's footprint-triggered recycle safety net
/// (260911-hx9). No AppKit, no Foundation process types, nothing about the adapter beyond a byte
/// count — mirrors `BrightnessScale`/`NowPlayingSessionClassifier`'s decoupling convention so
/// `NowPlayingService` stays a thin actor around a tested core.
///
/// **The 512 MiB default**, and the reasoning behind it: spike 001's largest observed legitimate
/// payload was 3.2 MB, a healthy adapter sits far below 200 MB, and the leaking adapter (root
/// cause: the vendored dylib's pre-260911-hx9 pin compiled `CIMediaRemote` without ARC) reached
/// 4233 MB after 19 days of uptime. 512 MiB is roughly 160x the largest real payload and about an
/// eighth of the observed failure — wide enough that no legitimate burst trips it, tight enough
/// that a regression is caught within minutes instead of weeks. A single sample decides whether to
/// recycle: with a two-orders-of-magnitude gap between healthy and leaking, requiring consecutive
/// confirmations would only add state for no discrimination.
public enum AdapterFootprintPolicy {
    /// The production recycle threshold, in megabytes.
    public static let defaultLimitMegabytes: UInt64 = 512

    /// How often `NowPlayingService`'s monitor samples the adapter child's footprint.
    public static let pollIntervalSeconds: Double = 60

    /// Resolves the recycle threshold in bytes. `overrideMegabytes` is read once at process start
    /// from the `MyIslandAdapterFootprintLimitMB` UserDefaults key — this override exists so the
    /// recycle path can be exercised on hardware without waiting weeks for a real leak, and only
    /// takes effect on relaunch.
    ///
    /// A `nil` OR `0` override both resolve to the default: a `0` limit would recycle the adapter
    /// on its very first poll forever, so it is treated as absent rather than obeyed.
    public static func limitBytes(overrideMegabytes: UInt64?) -> UInt64 {
        let megabytes: UInt64
        if let overrideMegabytes, overrideMegabytes > 0 {
            megabytes = overrideMegabytes
        } else {
            megabytes = defaultLimitMegabytes
        }
        return megabytes * 1024 * 1024
    }

    /// Whether the adapter child should be recycled given its currently measured footprint. The
    /// comparison is strictly-greater, so a footprint exactly at the limit is not a recycle.
    public static func shouldRecycle(footprintBytes: UInt64, limitBytes: UInt64) -> Bool {
        footprintBytes > limitBytes
    }
}
