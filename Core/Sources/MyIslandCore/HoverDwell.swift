public struct HoverDwell {
    public enum NotchState {
        case closed
        case open
    }

    public private(set) var state: NotchState = .closed
    private var pendingOpen = false

    public init() {}

    public mutating func hoverBegan() {
        pendingOpen = true
    }

    public mutating func dwellElapsed() {
        guard pendingOpen else { return }
        state = .open
    }

    public mutating func hoverEnded() {
        pendingOpen = false
        state = .closed
    }

    public mutating func toggle() {
        pendingOpen = false
        state = (state == .open) ? .closed : .open
    }
}
