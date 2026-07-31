import SwiftUI
import AppKit
import OSLog
import MyIslandCore

/// `@MainActor`-isolated shell around the pure `TimerEngine` (mirrors how
/// `NotchViewModel` wraps `HoverDwell`). Drives a 1s tick that recomputes
/// `remaining` from the engine's deadline and republishes it for SwiftUI.
@MainActor
@Observable
final class TimerViewModel {
    private var engine = TimerEngine()
    private let logger = AppLog.make("TimerViewModel")

    // Accessed from `deinit`, which runs nonisolated — safe because
    // `Timer.invalidate()` is thread-agnostic and no other isolated state is
    // touched there (mirrors `NotchPanelController.screenObserver`).
    nonisolated(unsafe) private var tickTimer: Timer?

    private(set) var remaining: TimeInterval = 0
    private(set) var startedDuration: TimeInterval = 0

    /// Fired once when a running timer completes (countdown ends, or the
    /// final Pomodoro cycle's focus period ends) — after the built-in sound +
    /// flash side effect below. Optional extension point; not required for
    /// D-11 itself.
    var onCompletion: (() -> Void)?

    /// Toggled once per completion (D-11). `NotchContentView` observes this
    /// to trigger a brief neutral/indigo flash overlay on the notch shape —
    /// never amber, and never a system notification (that's the whole point
    /// of D-11: no Notification Center TCC grant).
    private(set) var flashPulse: Bool = false

    var mode: TimerMode? { engine.mode }
    var cycle: Int { engine.cycle }
    var totalCycles: Int { engine.config.totalCycles }
    var focusDuration: TimeInterval { engine.config.focusDuration }
    var breakDuration: TimeInterval { engine.config.breakDuration }
    var isRunning: Bool { engine.isRunning }
    var isPaused: Bool { engine.isPaused }

    /// Maps the engine's `TimerMode` onto `Tokens.TimerState` so
    /// `Tokens.timerColor(for:)` drives both the collapsed dot and the
    /// expanded ring/chip from the SAME source (D-09).
    var tokenState: Tokens.TimerState? {
        switch engine.mode {
        case .countdown: return .countdown
        case .pomodoroFocus: return .pomodoroFocus
        case .pomodoroBreak: return .pomodoroBreak
        case nil: return nil
        }
    }

    func startCountdown(minutes: Double) {
        let duration = minutes * 60
        startedDuration = duration
        engine.startCountdown(duration: duration, now: .now)
        remaining = engine.remaining(now: .now)
        startTicking()
    }

    func startPomodoro() {
        let config = PomodoroConfig()
        startedDuration = config.focusDuration
        engine.startPomodoro(config: config, now: .now)
        remaining = engine.remaining(now: .now)
        startTicking()
    }

    func pause() {
        engine.pause(now: .now)
        remaining = engine.remaining(now: .now)
    }

    func resume() {
        engine.resume(now: .now)
        remaining = engine.remaining(now: .now)
        startTicking()
    }

    func reset() {
        engine.reset()
        remaining = 0
        startedDuration = 0
        stopTicking()
    }

    private func startTicking() {
        stopTicking()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.handleTick()
            }
        }
    }

    private func handleTick() {
        let now = Date.now
        let transitioned = engine.tick(now: now)
        remaining = engine.remaining(now: now)

        guard transitioned else { return }

        switch engine.mode {
        case .pomodoroFocus:
            startedDuration = engine.config.focusDuration
        case .pomodoroBreak:
            startedDuration = engine.config.breakDuration
        case .countdown, nil:
            break
        }

        if engine.mode == nil {
            logger.info("Timer completed")
            stopTicking()
            // Fixed, compile-time system-sound constant (never a user-
            // influenced path) — guarded optional, skips silently if
            // unavailable (T-03-T1).
            NSSound(named: "Glass")?.play()
            flashPulse.toggle()
            onCompletion?()
        }
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    deinit {
        tickTimer?.invalidate()
    }
}
