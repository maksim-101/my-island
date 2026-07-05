import Foundation
import Testing
@testable import MyIslandCore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@Test func countdownRemainingComputesFromDeadline() {
    var engine = TimerEngine()
    engine.startCountdown(duration: 60, now: t0)
    #expect(engine.remaining(now: t0.addingTimeInterval(30)) == 30)
}

@Test func countdownRemainingClampsToZeroPastDeadline() {
    var engine = TimerEngine()
    engine.startCountdown(duration: 60, now: t0)
    #expect(engine.remaining(now: t0.addingTimeInterval(90)) == 0)
}

@Test func countdownCompletionEndsTimer() {
    var engine = TimerEngine()
    engine.startCountdown(duration: 60, now: t0)
    let completed = engine.tick(now: t0.addingTimeInterval(60))
    #expect(completed == true)
    #expect(engine.mode == nil)
}

@Test func pomodoroFocusTransitionsToBreak() {
    var engine = TimerEngine()
    engine.startPomodoro(now: t0)
    #expect(engine.mode == .pomodoroFocus)
    #expect(engine.cycle == 1)

    let focusDeadline = t0.addingTimeInterval(engine.config.focusDuration)
    let completed = engine.tick(now: focusDeadline)
    #expect(completed == true)
    #expect(engine.mode == .pomodoroBreak)
    #expect(engine.cycle == 1)
}

@Test func pomodoroBreakTransitionsToFocusAndIncrementsCycle() {
    var engine = TimerEngine()
    engine.startPomodoro(now: t0)

    let focusDeadline = t0.addingTimeInterval(engine.config.focusDuration)
    engine.tick(now: focusDeadline)

    let breakDeadline = focusDeadline.addingTimeInterval(engine.config.breakDuration)
    let completed = engine.tick(now: breakDeadline)
    #expect(completed == true)
    #expect(engine.mode == .pomodoroFocus)
    #expect(engine.cycle == 2)
}

@Test func finalCycleCompletionEndsTimer() {
    var config = PomodoroConfig()
    config.totalCycles = 1
    var engine = TimerEngine()
    engine.startPomodoro(config: config, now: t0)

    let focusDeadline = t0.addingTimeInterval(config.focusDuration)
    let completed = engine.tick(now: focusDeadline)
    #expect(completed == true)
    #expect(engine.mode == nil)
}

@Test func tickIsIdempotentBeforeNextDeadline() {
    var engine = TimerEngine()
    engine.startPomodoro(now: t0)

    let focusDeadline = t0.addingTimeInterval(engine.config.focusDuration)
    #expect(engine.tick(now: focusDeadline) == true)
    #expect(engine.mode == .pomodoroBreak)

    // Calling tick again before the break's real deadline must not double-advance.
    #expect(engine.tick(now: focusDeadline.addingTimeInterval(1)) == false)
    #expect(engine.mode == .pomodoroBreak)
    #expect(engine.cycle == 1)
}

@Test func pauseFreezesRemainingAcrossLaterNow() {
    var engine = TimerEngine()
    engine.startCountdown(duration: 60, now: t0)
    engine.pause(now: t0.addingTimeInterval(10))
    #expect(engine.isPaused == true)
    #expect(engine.remaining(now: t0.addingTimeInterval(50)) == 50)
}

@Test func resumeContinuesCountdownFromPausedRemaining() {
    var engine = TimerEngine()
    engine.startCountdown(duration: 60, now: t0)
    engine.pause(now: t0.addingTimeInterval(10))
    engine.resume(now: t0.addingTimeInterval(100))
    #expect(engine.isPaused == false)
    #expect(engine.remaining(now: t0.addingTimeInterval(100)) == 50)
    #expect(engine.remaining(now: t0.addingTimeInterval(130)) == 20)
}

@Test func resetClearsModeRemainingAndCycle() {
    var engine = TimerEngine()
    engine.startPomodoro(now: t0)
    engine.reset()
    #expect(engine.mode == nil)
    #expect(engine.remaining(now: t0) == 0)
    #expect(engine.cycle == 1)
}
