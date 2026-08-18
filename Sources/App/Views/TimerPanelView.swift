import SwiftUI

/// The Timer stage body (popup-cockpit3-FINAL.html "Timer selected"): a
/// `Countdown | Pomodoro` segmented toggle pinned top-right, then the selected
/// mode's compact body. Countdown-idle = presets + minutes field + Start;
/// Countdown-running = the progress axis; Pomodoro = a single segmented
/// cycle-axis row + one-line caption. One unified content size (~12.5–13pt) —
/// the timer is never larger than the panel's other sections. Styled entirely
/// from `Tokens` — never a hardcoded color/spacing/typography value.
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
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            modeSwitch
                .frame(maxWidth: .infinity, alignment: .trailing)

            if selectedMode == .pomodoro {
                pomodoroBody
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
        HStack(spacing: 2) {
            modeButton(title: "Countdown", mode: .countdown)
            modeButton(title: "Pomodoro", mode: .pomodoro)
        }
        .padding(2)
        .background(Tokens.Color.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
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
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm - 2))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Countdown, idle (BL-05 variant F)

    /// One line: segmented presets, an EMPTY minutes field, and a filled Start.
    /// No readout and no ring while idle — there is nothing to read out. All at
    /// the unified content size (Start is NOT oversized here).
    private var idleRow: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            // fixedSize on both: DurationField is an NSViewRepresentable with no
            // width of its own, so SwiftUI hands it the free space and squeezes
            // the segments until "25" truncates to an ellipsis.
            segmentedPresets
                .fixedSize()

            HStack(spacing: 3) {
                DurationField(minutes: $customMinutes)
                    .frame(width: 34)
                    .accessibilityLabel("Duration in minutes")
                Text("min")
                    .font(Tokens.Font.bodyMD)
                    .foregroundStyle(Tokens.Color.textMuted)
            }
            .padding(.horizontal, Tokens.Spacing.sm)
            .frame(height: 28)
            .fixedSize()
            .background(Tokens.Color.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            .help("Type or scroll to set minutes")

            Spacer(minLength: Tokens.Spacing.xs)

            Button {
                guard let customMinutes else { return }
                timer.startCountdown(minutes: Double(customMinutes))
            } label: {
                Text("Start")
                    .font(Tokens.Font.buttonPrimary)
                    .foregroundStyle(Tokens.Color.accentInk)
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
            .accessibilityValue("\(Int(elapsed / 60)) of \(Int(timer.startedDuration / 60)) minutes")

            Text("\(Int(timer.startedDuration / 60))m")
                .font(Tokens.Font.label)
                .foregroundStyle(Tokens.Color.textMuted)

            transportControls
        }
    }

    private var knob: some View {
        // Minutes only — the collapsed notch's right wing carries the precise
        // m:ss, so seconds here would just be a second, noisier copy of it.
        Text("\(Int(elapsed / 60))m")
            .font(Tokens.Font.label)
            .monospacedDigit()
            .foregroundStyle(Tokens.Color.background)
            .frame(width: Self.knobWidth, height: 18)
            .background(Capsule().fill(Tokens.timerColor(for: timer.tokenState)))
            .overlay(Capsule().strokeBorder(Tokens.Color.surface, lineWidth: 2))
    }

    private static let knobWidth: CGFloat = 52

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
            iconButton(systemName: timer.isPaused ? "play.fill" : "pause.fill", help: timer.isPaused ? "Resume" : "Pause") {
                if timer.isPaused { timer.resume() } else { timer.pause() }
            }
            iconButton(systemName: "arrow.counterclockwise", help: "Reset") {
                timer.reset()
            }
        }
    }

    // MARK: - Pomodoro (compact single row)

    /// The compacted Pomodoro body: the mono readout (colored by state) + a
    /// segmented cycle axis (coral focus / mint break, elapsed at full opacity,
    /// future dimmed) + transport, then a one-line caption. Replaces the old
    /// 40pt ring + big-readout card + dot cycle-strip.
    private var pomodoroBody: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            HStack(spacing: Tokens.Spacing.sm) {
                Text(formatted(timer.isRunning ? timer.remaining : timer.focusDuration))
                    .font(Tokens.Font.data)
                    .foregroundStyle(timer.isRunning ? Tokens.timerColor(for: timer.tokenState) : Tokens.Color.textMuted)

                cycleAxis

                if timer.isRunning {
                    iconButton(systemName: timer.isPaused ? "play.fill" : "pause.fill", help: timer.isPaused ? "Resume" : "Pause") {
                        if timer.isPaused { timer.resume() } else { timer.pause() }
                    }
                    iconButton(systemName: "arrow.counterclockwise", help: "Reset") {
                        timer.reset()
                    }
                } else {
                    Button {
                        timer.startPomodoro()
                    } label: {
                        Text("Start")
                            .font(Tokens.Font.buttonPrimary)
                            .foregroundStyle(Tokens.Color.accentInk)
                            .padding(.horizontal, Tokens.Spacing.md)
                            .frame(height: 28)
                            .background(Tokens.Color.accent)
                            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(pomodoroCaption)
                .font(Tokens.Font.label)
                .foregroundStyle(timer.isRunning ? Tokens.timerColor(for: timer.tokenState) : Tokens.Color.textMuted)
        }
    }

    /// One continuous 8pt bar: for each cycle a coral focus block + a mint
    /// break block, widths proportional to the focus/break durations. Cycles
    /// before the current one render at full opacity (elapsed); the current and
    /// future ones dim, so the axis reads as "how far through the set am I."
    private var cycleAxis: some View {
        let total = max(timer.totalCycles, 1)
        let unit = timer.focusDuration + timer.breakDuration
        let denom = unit * Double(total)
        return GeometryReader { geo in
            let gap: CGFloat = 2
            let usable = max(0, geo.size.width - gap * CGFloat(total * 2 - 1))
            let focusW = denom > 0 ? usable * timer.focusDuration / denom : 0
            let breakW = denom > 0 ? usable * timer.breakDuration / denom : 0
            HStack(spacing: gap) {
                ForEach(1...total, id: \.self) { index in
                    let elapsedCycle = index < timer.cycle
                    let currentCycle = index == timer.cycle && timer.isRunning
                    Rectangle()
                        .fill(Tokens.Color.accentWarm)
                        .opacity(elapsedCycle || currentCycle ? 1 : 0.28)
                        .frame(width: focusW)
                    Rectangle()
                        .fill(Tokens.Color.accentCool)
                        .opacity(elapsedCycle ? 1 : 0.28)
                        .frame(width: breakW)
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
        }
        .frame(height: 8)
    }

    private var pomodoroCaption: String {
        if timer.isRunning {
            let phase = timer.mode == .pomodoroBreak ? "break" : "focus"
            return "\(phase) \u{00B7} cycle \(max(timer.cycle, 1)) of \(timer.totalCycles)"
        }
        return "\(Int(timer.focusDuration / 60))m focus \u{00B7} \(Int(timer.breakDuration / 60))m break"
    }

    // MARK: - Shared

    private func iconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(Tokens.Font.bodyMD)
                .foregroundStyle(Tokens.Color.text)
                .frame(width: 26, height: 26)
                .background(Tokens.Color.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func formatted(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
