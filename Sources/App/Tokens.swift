import SwiftUI

/// Single Swift mirror of `DESIGN.md` 1.0's locked front-matter (colors,
/// typography, rounding, spacing). MUST be kept in sync with that file — if a
/// token value changes in DESIGN.md, update it here too, verbatim.
enum Tokens {
    enum Color {
        /// Identity color — every interactive/active affordance (primary
        /// buttons, now-playing accent, pane-jump arrow, selection).
        static let accent = SwiftUI.Color(hex: 0x7C6BFF)
        /// On-accent text/label color (e.g. the Join button's label sitting
        /// on an `accent` fill) — mirrors DESIGN.md
        /// `components.button-primary.color`. Never a stand-in for
        /// `Tokens.Color.text`.
        static let accentInk = SwiftUI.Color(hex: 0xF4F2FF)
        /// Reserved exclusively for attention ("needs you", warnings) —
        /// never decorative.
        static let signal = SwiftUI.Color(hex: 0xFFB338)
        /// Categorical secondary accent (e.g. Pomodoro focus) — never
        /// carries attention meaning, never replaces `accent`.
        static let accentWarm = SwiftUI.Color(hex: 0xFF6B5C)
        /// Categorical secondary accent (e.g. Pomodoro break).
        static let accentCool = SwiftUI.Color(hex: 0x3DDC97)
        static let background = SwiftUI.Color(hex: 0x0A0B0D)
        static let surface = SwiftUI.Color(hex: 0x15161A)
        static let surfaceRaised = SwiftUI.Color(hex: 0x1C1E23)
        static let text = SwiftUI.Color(hex: 0xE9E9EE)
        static let textMuted = SwiftUI.Color(hex: 0x83868F)
        static let textFaint = SwiftUI.Color(hex: 0x575A63)
        static let hairline = SwiftUI.Color(hex: 0x202128)
    }

    enum Radius {
        static let sm: CGFloat = 7
        static let md: CGFloat = 11
        static let lg: CGFloat = 16
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Font {
        static let title = SwiftUI.Font.system(size: 15, weight: .semibold)
        /// Exposed separately from `bodyMD` so non-`SwiftUI.Font` consumers (e.g. an `NSFont`
        /// used for manual text measurement) can reference the same point size without
        /// duplicating the literal.
        static let bodyMDSize: CGFloat = 12.5
        static let bodyMD = SwiftUI.Font.system(size: bodyMDSize, weight: .regular)
        static let label = SwiftUI.Font.system(size: 10, weight: .semibold).monospaced()
        static let data = SwiftUI.Font.system(size: 12, weight: .medium).monospaced()
    }

    /// Lightweight local stand-in for `PomodoroEngine`'s `TimerMode` (which
    /// doesn't exist until plan 03-02) so this file compiles standalone;
    /// 03-02 maps its engine's mode onto this at the call site.
    enum TimerState {
        case countdown
        case pomodoroFocus
        case pomodoroBreak
    }

    /// Locked D-09 timer-color mapping: color always means which
    /// timer/state is running, shared by collapsed dot and expanded ring.
    static func timerColor(for state: TimerState?) -> SwiftUI.Color {
        switch state {
        case .countdown: return Color.accent
        case .pomodoroFocus: return Color.accentWarm
        case .pomodoroBreak: return Color.accentCool
        case nil: return Color.textFaint
        }
    }
}

private extension SwiftUI.Color {
    /// Decodes a `0xRRGGBB` literal into a SwiftUI `Color`.
    init(hex: UInt32) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(red: red, green: green, blue: blue)
    }
}
