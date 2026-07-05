import SwiftUI

/// The collapsed notch's "extended pill": a SINGLE continuous black shape that
/// spans the notch cutout AND equal strips of the visible menu-bar ears on both
/// sides, with the running-timer readout on the right.
///
/// Why one shape (not separate wings): the collapsed strip over the camera
/// cutout has no visible pixels, so the timer readout must live in the ears —
/// but butting separate rounded shapes against the notch always leaves a seam
/// at the join. Drawing the whole thing as one wide `NotchShape` (full-width
/// top, rounded bottom/outer corners) makes it a seamless extension by
/// construction. The symmetric left strip is empty for now (reserved for
/// Phase 5 Now Playing); it keeps the extended notch balanced.
///
/// Shown only while a timer runs AND the panel is collapsed (the expanded panel
/// already shows the timer). Rendered by its own window, sized to span the
/// cutout plus both ear strips.
@MainActor
struct NotchBarView: View {
    let timer: TimerViewModel
    let model: NotchViewModel

    var body: some View {
        Group {
            if timer.isRunning && !model.isOpen {
                NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
                    .fill(Color.black)
                    .overlay(alignment: .trailing) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Tokens.timerColor(for: timer.tokenState))
                                .frame(width: 6, height: 6)
                            Text(formatted(timer.remaining))
                                .font(Tokens.Font.data)
                                .foregroundStyle(Tokens.Color.text)
                                .fixedSize()
                        }
                        .padding(.trailing, Tokens.Spacing.lg)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formatted(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
