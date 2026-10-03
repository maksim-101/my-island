import Foundation

/// Pure decoding and step math for the brightness-key tap (HUD-04). No AppKit: the tap callback
/// hands in plain integers read from the `NX_SYSDEFINED` event.
///
/// Layout (RESEARCH Pattern 2): `subtype` 8 is the aux-control-buttons subtype; in `data1` the top
/// 16 bits are the key code (2 brightness up, 3 brightness down), the next byte is the state
/// (0x0A down, 0x0B up) and bit 0 is the auto-repeat flag.
public enum BrightnessKey {
    public struct Event: Equatable, Sendable {
        public let up: Bool
        public let isDown: Bool
        public let isRepeat: Bool
        public let fine: Bool

        public init(up: Bool, isDown: Bool, isRepeat: Bool, fine: Bool) {
            self.up = up
            self.isDown = isDown
            self.isRepeat = isRepeat
            self.fine = fine
        }
    }

    public static let auxControlButtonsSubtype: Int16 = 8
    public static let brightnessUpCode = 2
    public static let brightnessDownCode = 3
    public static let keyDownState = 0x0A
    public static let keyUpState = 0x0B

    public static let shiftMask: UInt64 = 0x20000
    public static let controlMask: UInt64 = 0x40000
    public static let optionMask: UInt64 = 0x80000
    public static let commandMask: UInt64 = 0x100000

    /// A decision, not a measurement (RESEARCH Open Question 1 / A6): a uniform 1/16 grid so
    /// sixteen presses span the range with no dead presses.
    public static let standardStep: Float = 1.0 / 16.0
    public static let fineStep: Float = 1.0 / 64.0

    /// About 16 steps per second while a key is held (BrightBoi's value, RESEARCH A13); tune here.
    public static let repeatInterval: TimeInterval = 0.06

    /// A held key's auto-repeats apply at most one step per `repeatInterval`; the first press is
    /// never throttled.
    public static func isThrottled(isRepeat: Bool, now: TimeInterval, lastApplied: TimeInterval?) -> Bool {
        guard isRepeat, let lastApplied else { return false }
        return now - lastApplied < repeatInterval
    }

    /// `nil` unless this is a brightness key event. Ignores modifiers, so a key-up or auto-repeat
    /// whose modifiers changed mid-hold still pairs with the key-down that started it.
    public static func decodeIgnoringModifiers(subtype: Int16, data1: Int) -> Event? {
        guard subtype == auxControlButtonsSubtype else { return nil }
        let code = (data1 & 0xFFFF0000) >> 16
        guard code == brightnessUpCode || code == brightnessDownCode else { return nil }
        let state = (data1 & 0xFF00) >> 8
        guard state == keyDownState || state == keyUpState else { return nil }
        return Event(up: code == brightnessUpCode, isDown: state == keyDownState, isRepeat: data1 & 1 != 0, fine: false)
    }

    /// `nil` unless this is a brightness key press my-island should handle. Command, Control or
    /// Option alone keep their system meaning (external display, Displays settings, mirroring) and
    /// pass through; Shift is accepted as a plain press and Option+Shift selects the fine step.
    public static func decode(subtype: Int16, data1: Int, flags: UInt64) -> Event? {
        guard let raw = decodeIgnoringModifiers(subtype: subtype, data1: data1) else { return nil }
        let held = flags & (shiftMask | controlMask | optionMask | commandMask)
        let fine: Bool
        switch held {
        case 0, shiftMask: fine = false
        case optionMask | shiftMask: fine = true
        default: return nil
        }
        return Event(up: raw.up, isDown: raw.isDown, isRepeat: raw.isRepeat, fine: fine)
    }

    /// Grid-snapped so repeated presses land on clean values; clamped to 0...1.
    public static func nextLevel(current: Float, up: Bool, fine: Bool) -> Float {
        let step = fine ? fineStep : standardStep
        let index = (current / step).rounded()
        let moved = up ? index + 1 : index - 1
        return min(1, max(0, moved * step))
    }
}

/// What the brightness-bezel setting is doing right now (HUD-03). Derived from the silent trust
/// read, never from a nil tap (A3: the tap can exist without a grant).
public enum BrightnessBezelState: String, Equatable, Sendable {
    case off
    case active
    case needsAccessibility
    case failed

    public static func resolve(enabled: Bool, trusted: Bool, tapActive: Bool) -> BrightnessBezelState {
        guard enabled else { return .off }
        guard trusted else { return .needsAccessibility }
        return tapActive ? .active : .failed
    }
}
