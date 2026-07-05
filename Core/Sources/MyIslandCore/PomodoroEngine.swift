import Foundation

public enum TimerMode: Equatable {
    case countdown
    case pomodoroFocus
    case pomodoroBreak
}

public struct PomodoroConfig: Equatable {
    public var focusDuration: TimeInterval = 25 * 60
    public var breakDuration: TimeInterval = 5 * 60
    public var totalCycles: Int = 4

    public init() {}
}

public struct TimerEngine: Equatable {
    public private(set) var mode: TimerMode?
    public var config = PomodoroConfig()
    public private(set) var cycle: Int = 1

    private var deadline: Date?
    private var pausedRemaining: TimeInterval?

    public init() {}

    public var isRunning: Bool { mode != nil }
    public var isPaused: Bool { pausedRemaining != nil }

    public mutating func startCountdown(duration: TimeInterval, now: Date = .now) {
        mode = .countdown
        deadline = now.addingTimeInterval(duration)
        pausedRemaining = nil
        cycle = 1
    }

    public mutating func startPomodoro(config: PomodoroConfig = PomodoroConfig(), now: Date = .now) {
        self.config = config
        mode = .pomodoroFocus
        deadline = now.addingTimeInterval(config.focusDuration)
        pausedRemaining = nil
        cycle = 1
    }

    public mutating func pause(now: Date = .now) {
        guard mode != nil, deadline != nil else { return }
        pausedRemaining = remaining(now: now)
        deadline = nil
    }

    public mutating func resume(now: Date = .now) {
        guard let pausedRemaining else { return }
        deadline = now.addingTimeInterval(pausedRemaining)
        self.pausedRemaining = nil
    }

    public mutating func reset() {
        mode = nil
        deadline = nil
        pausedRemaining = nil
        cycle = 1
    }

    /// Call on every UI tick; advances state exactly once when the deadline
    /// passes (idempotent — calling again before the next real deadline is a
    /// no-op). Returns `true` when a transition/completion happened.
    public mutating func tick(now: Date = .now) -> Bool {
        guard let deadline, now >= deadline else { return false }
        switch mode {
        case .pomodoroFocus where cycle < config.totalCycles:
            mode = .pomodoroBreak
            self.deadline = now.addingTimeInterval(config.breakDuration)
        case .pomodoroFocus:
            mode = nil
            self.deadline = nil
        case .pomodoroBreak:
            cycle += 1
            mode = .pomodoroFocus
            self.deadline = now.addingTimeInterval(config.focusDuration)
        case .countdown, .none:
            mode = nil
            self.deadline = nil
        }
        return true
    }

    public func remaining(now: Date = .now) -> TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        guard let deadline else { return 0 }
        return max(0, deadline.timeIntervalSince(now))
    }
}
