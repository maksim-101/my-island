import SwiftUI

/// Collapsed-notch right-half timer readout (TIME-02, D-01/D-02): a
/// state-colored dot + mm:ss remaining, shown only while a timer is running
/// — otherwise empty, so the right half stays quiet without widening the
/// fixed notch shape. MUST occupy only the notch's right half; the caller
/// (`NotchContentView`) is responsible for constraining/positioning this
/// view so it never draws over the centered camera housing.
@MainActor
struct TimerCollapsedView: View {
    let timer: TimerViewModel

    var body: some View {
        if timer.isRunning {
            HStack(spacing: 3) {
                Circle()
                    .fill(Tokens.timerColor(for: timer.tokenState))
                    .frame(width: 5, height: 5)
                Text(formatted(timer.remaining))
                    .font(Tokens.Font.data)
                    .foregroundStyle(Tokens.Color.textMuted)
            }
        }
    }

    private func formatted(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
