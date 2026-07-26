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
    @State private var customMinutes: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

            if selectedMode == .pomodoro {
                timerCard
                cycleStrip
            } else if timer.isRunning {
                // Running countdown: the readout is the axis, not a number —
                // the collapsed notch's right wing already carries the
                // remaining time (BL-05 / NotchBarView).
                axisRow
            } else {
                idleRow
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

    // MARK: - Countdown, idle (BL-05 variant F)

    /// One line: segmented presets, an EMPTY minutes field, and a filled Start.
    /// No readout and no ring while idle — there is nothing to read out.
    private var idleRow: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            segmentedPresets

            HStack(spacing: 1) {
                DurationField(minutes: $customMinutes)
                    .accessibilityLabel("Duration in minutes")
                Text("min")
                    .font(Tokens.Font.bodyMD)
                    .foregroundStyle(Tokens.Color.textMuted)
            }
            .padding(.horizontal, Tokens.Spacing.sm)
            .frame(height: 28)
            .background(Tokens.Color.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            .help("Type or scroll to set minutes")

            Spacer(minLength: Tokens.Spacing.xs)

            Button {
                guard let customMinutes else { return }
                timer.startCountdown(minutes: Double(customMinutes))
            } label: {
                // 14pt bold, not 12.5 semibold: no text color reaches 4.5:1 on
                // the indigo accent, so Start must qualify as LARGE text (3:1).
                Text("Start")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Tokens.Spacing.md)
                    .frame(height: 28)
                    .background(Tokens.Color.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            }
            .buttonStyle(.plain)
            .disabled(customMinutes == nil)
            .opacity(customMinutes == nil ? 0.45 : 1)
        }
    }

    /// The four presets read as one "pick a duration" control rather than four
    /// loose buttons — one tab stop instead of four.
    private var segmentedPresets: some View {
        HStack(spacing: 0) {
            ForEach(Array([5, 15, 25, 45].enumerated()), id: \.offset) { index, minutes in
                if index > 0 {
                    Rectangle()
                        .fill(Tokens.Color.hairline)
                        .frame(width: 1, height: 28)
                }
                Button {
                    timer.startCountdown(minutes: Double(minutes))
                } label: {
                    Text("\(minutes)")
                        .font(Tokens.Font.bodyMD)
                        .foregroundStyle(Tokens.Color.text)
                        .padding(.horizontal, Tokens.Spacing.md)
                        .frame(height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(minutes) minute timer")
            }
        }
        .background(Tokens.Color.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
    }

    // MARK: - Countdown, running (BL-05 variant I)

    /// Progress axis: nothing at the left (zero is implied), a labelled knob
    /// carrying elapsed time, and the full duration anchored right as what
    /// 100% means.
    private var axisRow: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            GeometryReader { geo in
                let width = geo.size.width
                let fraction = progressFraction
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Tokens.Color.hairline)
                        .frame(height: 6)
                    Capsule()
                        .fill(Tokens.timerColor(for: timer.tokenState))
                        .frame(width: max(0, width * fraction), height: 6)
                    knob
                        .offset(x: knobOffset(width: width, fraction: fraction))
                }
                .frame(height: geo.size.height, alignment: .center)
                .animation(reduceMotion ? nil : .linear(duration: 0.3), value: fraction)
            }
            .frame(height: 24)
            .accessibilityElement()
            .accessibilityLabel("Timer progress")
            .accessibilityValue("\(formatted(elapsed)) of \(Int(timer.startedDuration / 60)) minutes")

            Text("\(Int(timer.startedDuration / 60))m")
                .font(Tokens.Font.label)
                .foregroundStyle(Tokens.Color.textMuted)

            transportControls
        }
    }

    private var knob: some View {
        Text(formatted(elapsed))
            .font(Tokens.Font.label)
            .monospacedDigit()
            .foregroundStyle(Tokens.Color.background)
            .frame(width: Self.knobWidth, height: 18)
            .background(Capsule().fill(Tokens.timerColor(for: timer.tokenState)))
            .overlay(Capsule().strokeBorder(Tokens.Color.surface, lineWidth: 2))
    }

    private static let knobWidth: CGFloat = 46

    /// Centre the knob on its position, but pin it inside the track at both
    /// ends — otherwise it hangs off the left at 0% and collides with the
    /// total label at 100%.
    private func knobOffset(width: CGFloat, fraction: Double) -> CGFloat {
        let centered = width * fraction - Self.knobWidth / 2
        return min(max(centered, 0), max(0, width - Self.knobWidth))
    }

    private var elapsed: TimeInterval {
        max(0, timer.startedDuration - timer.remaining)
    }

    private var progressFraction: Double {
        guard timer.startedDuration > 0 else { return 0 }
        return min(1, max(0, elapsed / timer.startedDuration))
    }

    private var transportControls: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Button {
                if timer.isPaused { timer.resume() } else { timer.pause() }
            } label: {
                Image(systemName: timer.isPaused ? "play.fill" : "pause.fill")
                    .foregroundStyle(Tokens.Color.text)
                    .frame(width: 28, height: 28)
                    .background(Tokens.Color.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            }
            .buttonStyle(.plain)
            .help(timer.isPaused ? "Resume" : "Pause")

            Button {
                timer.reset()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .foregroundStyle(Tokens.Color.text)
                    .frame(width: 28, height: 28)
                    .background(Tokens.Color.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            }
            .buttonStyle(.plain)
            .help("Reset")
        }
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
