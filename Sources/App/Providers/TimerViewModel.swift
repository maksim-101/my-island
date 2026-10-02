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

    /// Per-local-day session count/seconds for the Timer droplet's "Today" filler row
    /// (07-DESIGN-AGREEMENT.md §9) — persisted as JSON under `com.myisland.timerToday`. Loaded
    /// once at init; a hand-edited/undecodable stored value reads back as an empty total (T-07-05)
    /// rather than crash.
    private(set) var todayTotal: DailyTimerTotal
    private static let todayTotalKey = "com.myisland.timerToday"

    // `@Observable`'s macro expansion rejects `Self.loadTodayTotal()` as a stored-property
    // default (covariant `Self` in a stored-property initializer) — loaded explicitly here instead.
    init() {
        todayTotal = Self.loadTodayTotal()
    }

    /// Fired once when a running timer completes (countdown ends, or the
    /// final Pomodoro cycle's focus period ends) — after the built-in sound +
    /// flash side effect below. Optional extension point; not required for
    /// D-11 itself.
    var onCompletion: (() -> Void)?

    /// Set once per completion (D-11, replaced 07-04 Task 2 — the old completion-toggle field drove
    /// a flat accent flash; `FluidOverlayView` now reads this to draw the three-ring pulse instead).
    /// `nil` whenever no timer has JUST finished — cleared automatically after `FluidPulse.duration`
    /// by `scheduleFinishedClear()`, and immediately by any new start/reset. Never amber, and never
    /// a system notification (that's the whole point of D-11: no Notification Center TCC grant).
    private(set) var finishedAt: Date?
    /// The `tokenState` that WAS running right before this completion — captured in `handleTick()`
    /// before `engine.tick(now:)` clears `engine.mode` to nil, so the finished pulse still knows
    /// which color (coral/mint/indigo) to draw even though `tokenState` itself reads nil once a
    /// timer has ended.
    private(set) var finishedTokenState: Tokens.TimerState?
    private var finishedClearWork: DispatchWorkItem?

    var mode: TimerMode? { engine.mode }
    var cycle: Int { engine.cycle }
    var totalCycles: Int { engine.config.totalCycles }
    var focusDuration: TimeInterval { engine.config.focusDuration }
    var breakDuration: TimeInterval { engine.config.breakDuration }
    var isRunning: Bool { engine.isRunning }
    var isPaused: Bool { engine.isPaused }

    /// Elapsed-fraction of the current run, clamped 0...1 — the single source both the expanded
    /// panel's progress axis (`TimerPanelView.axisRow`) and the collapsed notch's right-wing
    /// progress ring (pre-fluid renderer, quick 260925-osd) read, so the two views can never disagree
    /// about how far along the timer is. 0 when `startedDuration` is not yet set (before a timer
    /// starts, or right after `reset()`).
    var progressFraction: Double {
        guard startedDuration > 0 else { return 0 }
        return min(1, max(0, (startedDuration - remaining) / startedDuration))
    }

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
        clearFinished()
        let duration = minutes * 60
        startedDuration = duration
        engine.startCountdown(duration: duration, now: .now)
        remaining = engine.remaining(now: .now)
        startTicking()
    }

    func startPomodoro() {
        clearFinished()
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
        clearFinished()
        engine.reset()
        remaining = 0
        startedDuration = 0
        stopTicking()
    }

    /// Any new start/reset clears a still-showing finished pulse immediately (07-04 Task 2) —
    /// cancels the pending auto-clear work item so it can never fire late and null out state a
    /// FRESH run has since repopulated.
    private func clearFinished() {
        finishedClearWork?.cancel()
        finishedClearWork = nil
        finishedAt = nil
        finishedTokenState = nil
    }

    private func scheduleFinishedClear() {
        finishedClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.finishedAt = nil
            self.finishedTokenState = nil
            self.finishedClearWork = nil
        }
        finishedClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + FluidPulse.duration, execute: work)
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
        // Captured BEFORE `engine.tick(now:)` below — by the time `engine.mode == nil` is
        // checked further down, `engine.tick` has already cleared it, so `tokenState` (computed
        // from `engine.mode`) would read nil right when the completion branch needs to know which
        // color WAS running (07-04 Task 2).
        let completingTokenState = tokenState
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

        // Today's total counts a completed countdown or a completed Pomodoro FOCUS phase — never
        // a break. A focus phase "completes" two ways: transitioning into a break (cycle <
        // totalCycles) or ending the run outright on the final cycle (engine.mode == nil straight
        // from .pomodoroFocus, PomodoroEngine.tick's own last-cycle branch) — both are covered by
        // checking `completingTokenState` alone, with no dependency on what `engine.mode` became.
        switch completingTokenState {
        case .countdown where engine.mode == nil:
            recordCompletedSession(duration: startedDuration, at: now)
        case .pomodoroFocus:
            recordCompletedSession(duration: engine.config.focusDuration, at: now)
        default:
            break
        }

        if engine.mode == nil {
            logger.info("Timer completed")
            stopTicking()
            // Fixed, compile-time system-sound constant (never a user-
            // influenced path) — guarded optional, skips silently if
            // unavailable (T-03-T1).
            NSSound(named: "Glass")?.play()
            // 07-13 (FEEL-06): the one haptic call in the app — a threshold crossing (the timer
            // reaching zero), never an ordinary click. Felt only with a finger resting on the
            // trackpad, and only if macOS's own trackpad-haptics setting allows it — the system
            // framework below already honors that preference on its own, no local gate needed.
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            finishedAt = now
            finishedTokenState = completingTokenState
            scheduleFinishedClear()
            onCompletion?()
        }
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func recordCompletedSession(duration: TimeInterval, at date: Date) {
        todayTotal.record(duration: duration, at: date, calendar: .current)
        persistTodayTotal()
    }

    private static func loadTodayTotal() -> DailyTimerTotal {
        guard let data = UserDefaults.standard.data(forKey: todayTotalKey),
              let decoded = try? JSONDecoder().decode(DailyTimerTotal.self, from: data) else {
            return DailyTimerTotal()
        }
        return decoded
    }

    private func persistTodayTotal() {
        guard let data = try? JSONEncoder().encode(todayTotal) else { return }
        UserDefaults.standard.set(data, forKey: Self.todayTotalKey)
    }

    deinit {
        tickTimer?.invalidate()
    }
}
