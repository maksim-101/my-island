import SwiftUI

/// The Timer detail droplet (07-DESIGN-AGREEMENT.md §4, §9, sketch `DETAIL.timer`,
/// `.planning/sketches/006-design-round/index.html:648-658`): idle shows one-click presets
/// (PANEL-06 — a tap starts the timer immediately, no confirmation) plus the explicit minutes
/// field with its own Start; running shows the phase label, a big mono readout with a numeric-text
/// transition, a progress ring, and Pause/Resume/Stop. Both states end with the "Today" filler row
/// (agreement §9 — the droplet is taller than either state's own content). The old
/// Countdown/Pomodoro mode switch, the knob-and-axis progress bar and the icon transport cluster
/// are gone — the band's own cell (07-09) already carries the one-click start/pause/resume glyph;
/// this droplet is the detail view, not a second copy of the band.
@MainActor
struct TimerPanelView: View {
    let timer: TimerViewModel

    @State private var customMinutes: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            if timer.isRunning {
                runningBody
            } else {
                idleBody
            }

            Spacer(minLength: 0)

            todayRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Idle: presets + explicit minutes field

    private var idleBody: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            Text("START A TIMER")
                .font(.system(size: 9, weight: .bold).monospaced())
                .tracking(0.4)
                .foregroundStyle(Tokens.Color.textFaint)

            presetChips

            minutesRow
        }
    }

    /// Four presets, each its own `Button` — a tap starts the timer at once (PANEL-06), no
    /// confirmation step. "25m focus" is tinted `accentWarm` (the Pomodoro-focus color, D-09) as
    /// the default choice; the other three are plain countdowns.
    private var presetChips: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            presetChip(title: "5m", index: 0) { timer.startCountdown(minutes: 5) }
            presetChip(title: "15m", index: 1) { timer.startCountdown(minutes: 15) }
            presetChip(title: "25m focus", tinted: true, index: 2) { timer.startPomodoro() }
            presetChip(title: "50m", index: 3) { timer.startCountdown(minutes: 50) }
        }
    }

    private func presetChip(title: String, tinted: Bool = false, index: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium).monospaced())
                .foregroundStyle(tinted ? Tokens.Color.accentWarm : Tokens.Color.textMuted)
                .padding(.horizontal, Tokens.Spacing.sm)
                .padding(.vertical, 5)
                .background(tinted ? Tokens.Color.accentWarm.opacity(0.14) : Tokens.Color.surfaceRaised)
                .clipShape(Capsule())
        }
        .buttonStyle(GlyphButtonStyle())
        .accessibilityLabel("Start \(title) timer")
        .dropletFocusable(index: index, ring: .capsule, action: action)
    }

    /// The one control that stays a two-step flow by design (PANEL-06's own carve-out): an EMPTY
    /// `DurationField` plus its own explicit Start. `minutesFieldFocused` bridges 07-12's
    /// keyboard-index-4 "make it first responder" action to the real `NSTextField` inside
    /// `DurationField` — SwiftUI's `.focused(_:)` on an `NSViewRepresentable` drives
    /// `window.makeFirstResponder(_:)` on the wrapped view.
    @FocusState private var minutesFieldFocused: Bool

    private var minutesRow: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            HStack(spacing: 3) {
                DurationField(minutes: $customMinutes)
                    .frame(width: 34)
                    .accessibilityLabel("Duration in minutes")
                    .focused($minutesFieldFocused)
                Text("min")
                    .font(Tokens.Font.bodyMD)
                    .foregroundStyle(Tokens.Color.textMuted)
            }
            .padding(.horizontal, Tokens.Spacing.sm)
            .frame(height: 28)
            .background(Tokens.Color.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            .help("Type or scroll to set minutes")
            .dropletFocusable(index: 4, ring: .roundedRect(Tokens.Radius.sm)) {
                minutesFieldFocused = true
            }

            Spacer(minLength: Tokens.Spacing.xs)

            Button(action: startCustomTimer) {
                Text("Start")
                    .font(Tokens.Font.buttonPrimary)
                    .foregroundStyle(Tokens.Color.accentInk)
                    .padding(.horizontal, Tokens.Spacing.md)
                    .frame(height: 28)
                    .background(Tokens.Color.accent)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            }
            .buttonStyle(GlyphButtonStyle())
            .disabled(customMinutes == nil)
            .opacity(customMinutes == nil ? 0.45 : 1)
            .dropletFocusable(index: 5, ring: .roundedRect(Tokens.Radius.sm), action: startCustomTimer)
        }
    }

    private func startCustomTimer() {
        guard let customMinutes else { return }
        timer.startCountdown(minutes: Double(customMinutes))
    }

    // MARK: - Running: phase label, big readout, ring, transport

    private var runningBody: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
            HStack(alignment: .top, spacing: Tokens.Spacing.md) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(phaseLabel)
                        .font(.system(size: 9, weight: .bold).monospaced())
                        .tracking(0.4)
                        .foregroundStyle(Tokens.Color.textFaint)

                    Text(formatted(timer.remaining))
                        .font(.system(size: 30, weight: .medium).monospaced())
                        .foregroundStyle(Tokens.Color.text)
                        .contentTransition(.numericText())
                        .animation(.default, value: timer.remaining)
                }

                Spacer()

                progressRing
            }

            transportControls
        }
    }

    private var progressRing: some View {
        let color = Tokens.timerColor(for: timer.tokenState)
        return ZStack {
            Circle()
                .stroke(color.opacity(0.18), lineWidth: 3.5)
            Circle()
                .trim(from: 0, to: max(0, min(1, timer.progressFraction)))
                .stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: timer.progressFraction)
        }
        .frame(width: 46, height: 46)
        .accessibilityHidden(true)
    }

    private var transportControls: some View {
        HStack(spacing: Tokens.Spacing.md) {
            Button(action: pauseResume) {
                Image(systemName: timer.isPaused ? "play.fill" : "pause.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.Color.text)
                    .frame(width: 34, height: 34)
                    .background(Tokens.Color.surfaceRaised)
                    .clipShape(Circle())
            }
            .buttonStyle(GlyphButtonStyle())
            .help(timer.isPaused ? "Resume" : "Pause")
            .dropletFocusable(index: 0, ring: .circle, action: pauseResume)

            Button {
                timer.reset()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.Color.textMuted)
                    .frame(width: 34, height: 34)
                    .background(Tokens.Color.surfaceRaised)
                    .clipShape(Circle())
            }
            .buttonStyle(GlyphButtonStyle())
            .help("Stop")
            .dropletFocusable(index: 1, ring: .circle) { timer.reset() }
        }
    }

    private func pauseResume() {
        if timer.isPaused { timer.resume() } else { timer.pause() }
    }

    private var phaseLabel: String {
        switch timer.mode {
        case .pomodoroFocus:
            return "FOCUS \u{00B7} SESSION \(max(timer.cycle, 1)) OF \(timer.totalCycles)"
        case .pomodoroBreak:
            return "BREAK"
        case .countdown:
            return "COUNTDOWN"
        case nil:
            return ""
        }
    }

    // MARK: - Shared: today's total (agreement §9)

    private var todayRow: some View {
        let total = timer.todayTotal.total(on: Date.now, calendar: .current)
        return HStack {
            Text("Today")
                .foregroundStyle(Tokens.Color.textMuted)
            Spacer()
            Text("\(total.sessions) sessions \u{00B7} \(Int(total.seconds / 60))m")
                .foregroundStyle(Tokens.Color.text)
        }
        .font(.system(size: 11, weight: .medium).monospaced())
        .padding(.top, Tokens.Spacing.sm)
        .overlay(alignment: .top) {
            Rectangle().fill(Tokens.Color.hairline).frame(height: 1)
        }
    }

    private func formatted(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
