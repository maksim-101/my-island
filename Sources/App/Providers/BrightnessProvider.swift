import CoreGraphics
import Foundation

/// Reads display brightness via the private `DisplayServices.framework`
/// (HUD-01). No public API exists for this on macOS — see
/// `.claude/CLAUDE.md`'s "What NOT to Use" table. Every symbol lookup and
/// call result is nil/status-checked; on any failure `level` stays `nil` and
/// the HUD row degrades to hidden rather than crashing (T-03-B2).
@MainActor
final class BrightnessProvider {
    /// `nil` == unavailable — the caller must hide the brightness HUD row.
    private(set) var level: Float?
    var onChange: (() -> Void)?

    private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private var getBrightness: GetBrightnessFn?

    // Accessed from `deinit`, which runs nonisolated — safe because
    // `Timer.invalidate()` is thread-agnostic and no other isolated state is
    // touched there (mirrors `TimerViewModel.tickTimer`).
    nonisolated(unsafe) private var pollTimer: Timer?

    /// Suppresses an implausible stale/glitch read (Pitfall 2): if a poll
    /// disagrees with the previous read by more than a full-step jump inside
    /// a short window, it is treated as a glitch rather than a real change.
    private var lastReadAt: Date?

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
        refresh()
        startPolling()
    }

    private func refresh() {
        guard let getBrightness else {
            level = nil
            return
        }
        var value: Float = 0
        // CGMainDisplayID() resolves to the built-in panel on this
        // single-machine target hardware (Assumption A2).
        let displayID = CGMainDisplayID()
        let status = getBrightness(displayID, &value)
        guard status == 0 else {
            return
        }

        let now = Date.now
        if let previous = level, let lastReadAt, now.timeIntervalSince(lastReadAt) < 1, abs(value - previous) > 0.5 {
            // Implausible stale read — suppress, keep the last known value.
            return
        }

        level = value
        lastReadAt = now
    }

    private func startPolling() {
        // 0.12s (~8 Hz): fine enough to track a held brightness key smoothly
        // (the old 0.3s sampled too coarsely, so the HUD bar jumped in big
        // steps and stuttered) while still a negligible number of private-API
        // reads at idle.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let previous = self.level
                self.refresh()
                if self.level != previous {
                    self.onChange?()
                }
            }
        }
    }

    deinit {
        pollTimer?.invalidate()
    }
}
