import CoreGraphics
import Foundation
import OSLog
import MyIslandCore

/// A @convention(c) callback cannot capture context, so this file-private sink is how
/// `brightnessChangeCallback` (below) hands a new value back into `BrightnessProvider`. Mirrors
/// `pollTimer`'s `nonisolated(unsafe)` convention — `BrightnessProvider` is a single
/// lifetime-scoped instance owned by `NotchPanelController`, so there is exactly one sink alive
/// at a time.
nonisolated(unsafe) private var brightnessSink: (@Sendable (Float) -> Void)?

private typealias BrightnessChangeCallback = @convention(c) (
    CGDirectDisplayID, UnsafeRawPointer?, CFString?, UnsafeRawPointer?, CFDictionary?
) -> Void

/// Verified-working signature and argument use (RESEARCH.md §1.2, measured on macOS 26.6/25G72):
/// argument 1 (display ID) is NOT trustworthy — it arrives as `0`, never the real display ID.
/// Only `name` (argument 3, expected `"DisplayServicesBrightness"`) and `userInfo` (argument 5,
/// `["value": Float]`) carry real data.
private let brightnessChangeCallback: BrightnessChangeCallback = { _, _, _, _, userInfo in
    guard let userInfo, let value = (userInfo as? [String: Any])?["value"] as? Float else { return }
    brightnessSink?(value)
}

/// Reads display brightness via the private `DisplayServices.framework`
/// (HUD-01). No public API exists for this on macOS — see
/// `.claude/CLAUDE.md`'s "What NOT to Use" table. Every symbol lookup and
/// call result is nil/status-checked; on any failure `level` stays `nil` and
/// the HUD row degrades to hidden rather than crashing (T-03-B2).
///
/// Publishes from `DisplayServicesRegisterForBrightnessChangeNotifications` (RESEARCH §1.2 —
/// verified to fire on real hardware keys, Control Center, third-party brightness apps,
/// auto-brightness and lid/wake, since it's the system-wide notification, not a per-source hook).
/// Falls back to the previous `Timer` poll only if the register symbol is missing or registration
/// fails. There is deliberately no glitch suppressor here — RESEARCH measured the notification
/// stream to be smooth and monotonic, and the old 1s/0.5-jump suppressor was actively swallowing
/// the exact externally-caused jumps users reported (T-7h2-01, Pitfall 1: a wrong `@convention(c)`
/// signature on a private symbol is a SIGSEGV, so only the empirically-validated signatures above
/// are used, and `DisplayServicesUnregisterForBrightnessChangeNotifications` is never called since
/// its signature was not validated this session and the provider is never torn down).
@MainActor
final class BrightnessProvider {
    /// `nil` == unavailable — the caller must hide the brightness HUD row.
    private(set) var level: Float?
    var onChange: (() -> Void)?

    private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private var getBrightness: GetBrightnessFn?

    /// The one validated setter signature (RESEARCH Security Domain; MonitorControl
    /// `Bridging-Header.h`). The smoothing variant is never resolved: its signature is unvalidated
    /// and a wrong `@convention(c)` signature on a private symbol is a SIGSEGV (Pitfall 1).
    private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private var setBrightness: SetBrightnessFn?

    private typealias RegisterFn = @convention(c) (CGDirectDisplayID, UInt64, BrightnessChangeCallback) -> Int32

    // Accessed from `deinit`, which runs nonisolated — safe because
    // `Timer.invalidate()` is thread-agnostic and no other isolated state is
    // touched there (mirrors `TimerViewModel.tickTimer`).
    nonisolated(unsafe) private var pollTimer: Timer?

    /// Last value actually published to `level`/`onChange` — feeds `BrightnessScale.shouldPublish`
    /// so the ~60Hz notification stream during a held-key ramp (RESEARCH §1.2, Pitfall 6) is
    /// coalesced before touching the observable model.
    private var lastPublished: Float?

    private let logger = AppLog.make("BrightnessProvider")

    var isAvailable: Bool { getBrightness != nil }

    init() {
        // Hardcoded absolute path — never relative or user-influenced
        // (T-03-B1).
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_NOW
        ) else {
            level = nil
            return
        }
        guard let sym = dlsym(handle, "DisplayServicesGetBrightness") else {
            level = nil
            return
        }
        getBrightness = unsafeBitCast(sym, to: GetBrightnessFn.self)
        if let setSym = dlsym(handle, "DisplayServicesSetBrightness") {
            setBrightness = unsafeBitCast(setSym, to: SetBrightnessFn.self)
        }
        refresh()

        if !registerForChangeNotifications(handle: handle) {
            startPolling()
        }
    }

    private func registerForChangeNotifications(handle: UnsafeMutableRawPointer) -> Bool {
        guard let sym = dlsym(handle, "DisplayServicesRegisterForBrightnessChangeNotifications") else {
            return false
        }
        let register = unsafeBitCast(sym, to: RegisterFn.self)

        brightnessSink = { [weak self] value in
            // Hop to the main actor defensively rather than assuming the delivery thread
            // (RESEARCH Assumption A4).
            Task { @MainActor in
                self?.publish(value)
            }
        }

        guard let displayID = Self.builtInDisplayID(requireActive: false) else {
            brightnessSink = nil
            return false
        }
        let status = register(displayID, UInt64(displayID), brightnessChangeCallback)
        guard status == 0 else {
            brightnessSink = nil
            return false
        }
        return true
    }

    private func refresh() {
        guard let getBrightness else {
            level = nil
            return
        }
        var value: Float = 0
        // The built-in panel, never whichever display is main: the external is often main
        // (RESEARCH Pitfall 2).
        guard let displayID = Self.builtInDisplayID(requireActive: false) else { return }
        let status = getBrightness(displayID, &value)
        guard status == 0 else {
            return
        }
        publish(value)
    }

    /// The built-in display found by `CGDisplayIsBuiltin`, re-resolved on every call because display
    /// ids change across reconfiguration. `requireActive` excludes a built-in that is online but
    /// not drawing (clamshell), where the setter cannot work.
    static func builtInDisplayID(requireActive: Bool) -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first {
            CGDisplayIsBuiltin($0) != 0 && (!requireActive || CGDisplayIsActive($0) != 0)
        }
    }

    /// One key step on the built-in display, read fresh from the hardware rather than from the
    /// coalesced `level`. Returns the new level only when the setter reported success, so the tap
    /// swallows a press only when this ran (HUD-04: the key never goes dead).
    func step(up: Bool, fine: Bool) -> Float? {
        guard let getBrightness, let setBrightness,
              let displayID = Self.builtInDisplayID(requireActive: true) else { return nil }
        var current: Float = 0
        guard getBrightness(displayID, &current) == 0 else { return nil }
        let next = BrightnessKey.nextLevel(current: current, up: up, fine: fine)
        guard setBrightness(displayID, next) == 0 else { return nil }
        return next
    }

    private func publish(_ value: Float) {
        guard BrightnessScale.shouldPublish(new: value, lastPublished: lastPublished) else { return }
        lastPublished = value
        level = value
        // Task 1 step D evidence line — raw DisplayServices reading vs. the mapped bar fraction,
        // used to reproduce/verify the dark-end symptom on-hardware (Debug builds only; AppLog is
        // OSLog.disabled in Release).
        logger.debug("""
            raw=\(value, privacy: .public) \
            barFraction=\(BrightnessScale.barFraction(for: value), privacy: .public)
            """)
        onChange?()
    }

    private func startPolling() {
        // Fallback path only — used when the notification symbol is missing or registration
        // fails. 0.12s (~8 Hz) mirrors the previous always-on poll cadence.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    deinit {
        pollTimer?.invalidate()
    }
}
