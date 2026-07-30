import SwiftUI
import Foundation

/// The Cockpit-3 tile strip (popup-cockpit3-FINAL.html "tiles3"): three tappable
/// tiles — Timer / Next / Playing — each a leading SF Symbol plus a mono
/// label + live value, sized by the locked flex weights (1 / 1.28 / 1.15). The
/// active tile brightens its icon to `text`, tints its border, and pins a 2px
/// `accent` underline to its bottom edge. Tapping a tile selects that stage.
/// Styled entirely from `Tokens` — never a hardcoded color/spacing/type value.
@MainActor
struct CockpitTileStripView: View {
    @Binding var stage: ExpandedPanelView.Stage
    let timer: TimerViewModel
    let calendar: CalendarProvider
    let nowPlaying: NowPlayingProvider

    /// Locked relative widths from the mockup (Timer / Next / Playing).
    private static let weights: [CGFloat] = [1, 1.28, 1.15]
    private static let gap = Tokens.Spacing.sm
    private static let tileHeight: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            let totalWeight = Self.weights.reduce(0, +)
            let available = geo.size.width - Self.gap * CGFloat(Self.weights.count - 1)
            HStack(spacing: Self.gap) {
                tile(
                    .timer,
                    width: available * Self.weights[0] / totalWeight,
                    icon: "stopwatch",
                    label: "TIMER",
                    value: timerValue,
                    valueColor: timerValueColor
                )
                tile(
                    .calendar,
                    width: available * Self.weights[1] / totalWeight,
                    icon: "calendar",
                    label: "NEXT",
                    value: calendarValue,
                    valueColor: Tokens.Color.text
                )
                tile(
                    .nowPlaying,
                    width: available * Self.weights[2] / totalWeight,
                    icon: "music.note",
                    label: "PLAYING",
                    value: nowPlayingValue,
                    valueColor: Tokens.Color.text
                )
            }
        }
        .frame(height: Self.tileHeight)
    }

    private func tile(
        _ target: ExpandedPanelView.Stage,
        width: CGFloat,
        icon: String,
        label: String,
        value: String,
        valueColor: SwiftUI.Color
    ) -> some View {
        let active = stage == target
        return Button {
            stage = target
        } label: {
            HStack(spacing: Tokens.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(active ? Tokens.Color.text : Tokens.Color.textMuted)
                    .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(Tokens.Font.label)
                        .foregroundStyle(Tokens.Color.textMuted)
                    Text(value)
                        .font(Tokens.Font.data)
                        .foregroundStyle(valueColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Tokens.Spacing.sm)
            .frame(width: width, height: Self.tileHeight, alignment: .leading)
            .background(Tokens.Color.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                    .stroke(active ? Tokens.Color.accent.opacity(0.25) : Tokens.Color.hairline, lineWidth: 1)
            }
            .overlay(alignment: .bottom) {
                if active {
                    Capsule()
                        .fill(Tokens.Color.accent)
                        .frame(height: 2)
                        .padding(.horizontal, Tokens.Spacing.sm)
                        .offset(y: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) tab")
    }

    // MARK: - Live tile values

    private var timerValue: String {
        timer.isRunning ? Self.clock(timer.remaining) : "Idle"
    }

    private var timerValueColor: SwiftUI.Color {
        timer.isRunning ? Tokens.timerColor(for: timer.tokenState) : Tokens.Color.textMuted
    }

    private var calendarValue: String {
        guard let event = calendar.events.first else { return "None" }
        let short = event.title.split(separator: " ").first.map(String.init) ?? event.title
        return "\(Self.compactCountdown(to: event.startDate)) \u{00B7} \(short)"
    }

    private var nowPlayingValue: String {
        guard let title = nowPlaying.currentModel?.title, !title.isEmpty else { return "\u{2014}" }
        return title
    }

    private static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Glanceable "{N}h"/"{N}m" summary for the tile — coarser than the pill's
    /// per-minute countdown, since the tile is a one-line dashboard readout.
    private static func compactCountdown(to date: Date) -> String {
        let minutes = Int(max(0, date.timeIntervalSinceNow) / 60)
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }
}
