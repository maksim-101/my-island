import Foundation

/// Which CoreAudio property `VolumeProvider` should read the current output device's volume from,
/// resolved by a strict priority order rather than "most channels" or any other heuristic (HUD-02).
///
/// Source: RESEARCH.md §1.3 — measured on this machine's built-in speakers, `VirtualMainVolume` and
/// `VolumeScalar(main)` return identical values and both are supported; per-channel scalars
/// (`VolumeScalar(ch1)`/`VolumeScalar(ch2)`) return `kAudioHardwareUnknownPropertyError`. Some
/// external/USB/aggregate devices are assumed to be the mirror image — main element unsupported,
/// per-channel supported (RESEARCH Assumption A1) — hence the fallback chain below.
public enum VolumeSource: Sendable, Equatable {
    case virtualMain
    case scalarMain
    case perChannel([UInt32])
    case unsupported

    /// `hasVirtualMain`/`hasScalarMain` come from `AudioObjectHasProperty` probes on the current
    /// default output device; `supportedChannels` are the channel numbers (1-based CoreAudio
    /// elements) for which `kAudioDevicePropertyVolumeScalar` is supported. Priority is strict:
    /// `VirtualMainVolume` wins whenever it's supported, even alongside per-channel support — the
    /// measured built-in-speakers case is `(true, true, [])`, and the existing code's choice
    /// (`VirtualMainVolume`) stays the winner there.
    public static func select(
        hasVirtualMain: Bool,
        hasScalarMain: Bool,
        supportedChannels: [UInt32]
    ) -> VolumeSource {
        if hasVirtualMain { return .virtualMain }
        if hasScalarMain { return .scalarMain }
        if !supportedChannels.isEmpty { return .perChannel(supportedChannels) }
        return .unsupported
    }
}
