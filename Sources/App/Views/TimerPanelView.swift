import SwiftUI

/// Expanded-panel Timer group (TIME-01): mode switch, ring + readout, state
/// chip, pause/reset, and either the countdown preset row or the Pomodoro
/// cycle strip depending on the selected mode. Styled entirely from
/// `Tokens` — never a hardcoded color/spacing/typography value.
@MainActor
struct TimerPanelView: View {
    let timer: TimerViewModel

    private enum ModeSelection: Equatable {
        case countdown
        case pomodoro
    }

    @State private var selectedMode: ModeSelection
    @State private var customMinutes: Int = 10

    init(timer: TimerViewModel) {
        self.timer = timer
        let initial: ModeSelection = (timer.mode == .pomodoroFocus || timer.mode == .pomodoroBreak) ? .pomodoro : .countdown
        _selectedMode = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            Text("Timer")
                .font(Tokens.Font.label)
                .foregroundStyle(Tokens.Color.textMuted)

            modeSwitch
            timerCard

            if selectedMode == .pomodoro {
                cycleStrip
            } else {
                presetRow
            }
        }
    }

    private var modeSwitch: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            modeButton(title: "Countdown", mode: .countdown)
            modeButton(title: "Pomodoro", mode: .pomodoro)
        }
    }

    private func modeButton(title: String, mode: ModeSelection) -> some View {
        let selected = selectedMode == mode
        return Button {
            selectedMode = mode
        } label: {
            Text(title)
                .font(Tokens.Font.bodyMD)
                .foregroundStyle(selected ? Tokens.Color.text : Tokens.Color.textMuted)
                .padding(.horizontal, Tokens.Spacing.sm)
                .padding(.vertical, Tokens.Spacing.xs)
                .background(selected ? Tokens.Color.accent.opacity(0.2) : SwiftUI.Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        }
        .buttonStyle(.plain)
    }

    private var ringFraction: Double {
        guard timer.startedDuration > 0 else { return 0 }
        return max(0, min(1, timer.remaining / timer.startedDuration))
    }

    private var stateChipText: String? {
        switch timer.mode {
        case .countdown: return "Countdown"
        case .pomodoroFocus: return "Focus"
        case .pomodoroBreak: return "Break"
        case nil: return nil
        }
    }

    private var timerCard: some View {
        HStack(spacing: Tokens.Spacing.md) {
            ZStack {
                Circle()
                    .stroke(Tokens.Color.hairline, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: ringFraction)
                    .stroke(Tokens.timerColor(for: timer.tokenState), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(formatted(timer.remaining))
                    .font(Tokens.Font.data)
                    .foregroundStyle(Tokens.Color.text)

                if let stateChipText {
                    Text(stateChipText)
                        .font(Tokens.Font.label)
                        .foregroundStyle(Tokens.timerColor(for: timer.tokenState))
                }
            }

            Spacer()

            HStack(spacing: Tokens.Spacing.xs) {
                Button {
                    if timer.isPaused {
                        timer.resume()
                    } else {
                        timer.pause()
                    }
                } label: {
                    Image(systemName: timer.isPaused ? "play.fill" : "pause.fill")
                        .foregroundStyle(Tokens.Color.textMuted)
                }
                .buttonStyle(.plain)
                .disabled(!timer.isRunning)
                .help(timer.isPaused ? "Resume" : "Pause")

                Button {
                    timer.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .foregroundStyle(Tokens.Color.textMuted)
                }
                .buttonStyle(.plain)
                .help("Reset")
            }
        }
        .padding(Tokens.Spacing.sm)
        .background(Tokens.Color.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md))
    }

    private var presetRow: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            presetButton(minutes: 5)
            presetButton(minutes: 15)
            presetButton(minutes: 25)

            Stepper(value: $customMinutes, in: 1...180) {
                Text("\(customMinutes)m")
                    .font(Tokens.Font.bodyMD)
                    .foregroundStyle(Tokens.Color.textMuted)
            }

            Button("Start") {
                timer.startCountdown(minutes: Double(customMinutes))
            }
            .buttonStyle(.plain)
            .font(Tokens.Font.bodyMD)
            .foregroundStyle(Tokens.Color.accent)
        }
    }

    private func presetButton(minutes: Double) -> some View {
        Button {
            timer.startCountdown(minutes: minutes)
        } label: {
            Text("\(Int(minutes))m")
                .font(Tokens.Font.bodyMD)
                .foregroundStyle(Tokens.Color.textMuted)
                .padding(.horizontal, Tokens.Spacing.sm)
                .padding(.vertical, Tokens.Spacing.xs)
                .background(Tokens.Color.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        }
        .buttonStyle(.plain)
    }

    private var cycleStrip: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            ForEach(1...max(timer.totalCycles, 1), id: \.self) { index in
                Circle()
                    .fill(dotColor(for: index))
                    .frame(width: 6, height: 6)
            }

            Text("cycle \(timer.cycle) of \(timer.totalCycles) \u{00B7} \(Int(timer.focusDuration / 60))m focus / \(Int(timer.breakDuration / 60))m break")
                .font(Tokens.Font.label)
                .foregroundStyle(Tokens.Color.textMuted)

            Spacer()

            if !timer.isRunning {
                Button("Start") {
                    timer.startPomodoro()
                }
                .buttonStyle(.plain)
                .font(Tokens.Font.bodyMD)
                .foregroundStyle(Tokens.Color.accent)
            }
        }
    }

    private func dotColor(for index: Int) -> SwiftUI.Color {
        if index < timer.cycle { return Tokens.Color.textFaint }
        if index == timer.cycle { return Tokens.timerColor(for: timer.tokenState) }
        return Tokens.Color.hairline
    }

    private func formatted(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
