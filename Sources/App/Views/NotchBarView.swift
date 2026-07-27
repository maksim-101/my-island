import SwiftUI
import MyIslandCore

/// The collapsed notch's "extended pill": a SINGLE continuous black shape that
/// spans the notch cutout AND equal strips of the visible menu-bar ears on both
/// sides, with the running-timer readout on the right and the Now Playing ear
/// (artwork + "Title — Artist", D-01/D-02) on the left.
///
/// Why one shape (not separate wings): the collapsed strip over the camera
/// cutout has no visible pixels, so the timer readout must live in the ears —
/// but butting separate rounded shapes against the notch always leaves a seam
/// at the join. Drawing the whole thing as one wide `NotchShape` (full-width
/// top, rounded bottom/outer corners) makes it a seamless extension by
/// construction.
///
/// Shown while EITHER a timer runs OR the Now Playing ear has content (D-05
/// disjunction), and the panel is collapsed (the expanded panel already shows
/// both). Rendered by its own window, sized to span the cutout plus both ear
/// strips.
@MainActor
struct NotchBarView: View {
    let timer: TimerViewModel
    let model: NotchViewModel
    let nowPlaying: NowPlayingProvider

    var body: some View {
        Group {
            if (timer.isRunning || nowPlaying.displayEar) && !model.isOpen {
                NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
                    .fill(Color.black)
                    .overlay(alignment: .trailing) {
                        if timer.isRunning {
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
                    .overlay(alignment: .leading) {
                        if nowPlaying.displayEar {
                            NowPlayingEarView(nowPlaying: nowPlaying)
                        }
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

/// The left ear's content (D-01): a fixed 20x20 artwork square plus the
/// "Title — Artist" text (D-02), laid out to match the symmetric 84pt
/// `NotchPanelController.barEar` ear exactly (D-03) — 8pt leading pad, the
/// 20pt tile, an 8pt gap (`Tokens.Spacing.sm`, UI-SPEC's off-grid exception),
/// a clipped text viewport, and an 8pt trailing pad before the notch cutout
/// edge (84 − (8+20+8+8) = 40pt of viewport). Never widens the ear (D-03) —
/// overflow is absorbed entirely inside the clipped viewport.
private struct NowPlayingEarView: View {
    let nowPlaying: NowPlayingProvider

    private static let artworkSize: CGFloat = 20
    private static let artworkCornerRadius: CGFloat = 4
    private static let totalEarWidth: CGFloat = 84
    static var textViewportWidth: CGFloat {
        totalEarWidth - Tokens.Spacing.sm - artworkSize - Tokens.Spacing.sm - Tokens.Spacing.sm
    }

    var body: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            artworkTile
            ScrollingEarText(text: earText, viewportWidth: Self.textViewportWidth)
        }
        .padding(.leading, Tokens.Spacing.sm)
        .padding(.trailing, Tokens.Spacing.sm)
    }

    private var earText: String {
        NowPlayingFormatting.earText(title: nowPlaying.currentModel?.title, artist: nowPlaying.currentModel?.artist)
    }

    @ViewBuilder
    private var artworkTile: some View {
        if let artwork = nowPlaying.artwork {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Self.artworkSize, height: Self.artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: Self.artworkCornerRadius))
        } else {
            // Footprint preserved even without artwork (D-01) — Task 2 adds
            // the styled `surfaceRaised` + `music.note` placeholder tile.
            Color.clear
                .frame(width: Self.artworkSize, height: Self.artworkSize)
        }
    }
}

/// The ear's "Title — Artist" text (D-04). This tracer-slice version renders
/// statically, clipped to the fixed viewport width so overflow is hidden
/// rather than widening the ear (D-03) — Task 2 replaces this with the
/// restrained single-pass scroll mechanics.
private struct ScrollingEarText: View {
    let text: String
    let viewportWidth: CGFloat

    var body: some View {
        Text(text)
            .font(Tokens.Font.bodyMD)
            .foregroundStyle(Tokens.Color.text)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: viewportWidth, alignment: .leading)
            .clipped()
    }
}
