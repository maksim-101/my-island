import AppKit
import SwiftUI
import MyIslandCore

/// The collapsed notch's "extended pill": a SINGLE continuous black shape that
/// spans the notch cutout AND equal strips of the visible menu-bar ears on both
/// sides, with the running-timer readout on the right and the Now Playing ear
/// (artwork tile only — see supersede note below) on the left.
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
///
/// **SUPERSEDED (2026-07-27, quick task 260727-sf0):** the left ear originally
/// carried both artwork and a scrolling "Title — Artist" text row (D-01/D-02).
/// The user compared the shipped ear against Alcove and found the text banner
/// distracting; the ear now shows the artwork tile alone. Full track identity
/// remains available in the expanded panel (D-08).
@MainActor
struct NotchBarView: View {
    let timer: TimerViewModel
    let model: NotchViewModel
    let nowPlaying: NowPlayingProvider
    let fullscreen: FullscreenObserver

    var body: some View {
        Group {
            // D-10/D-11: the Now Playing ear is suppressed — absent, not
            // dimmed — while the frontmost app is fullscreen, so a film's
            // title never scrolls over the film. The `timer.isRunning ||`
            // disjunct is deliberately OUTSIDE the suppressed parenthesis —
            // a running timer still shows in fullscreen and still keeps the
            // pill up on its own. Do not "simplify" this into a single
            // shared condition; that would silently re-suppress the timer
            // too and break Phase 4 D-01.
            if (timer.isRunning || (nowPlaying.displayEar && !fullscreen.isFrontmostFullscreen)) && !model.isOpen {
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
                        if nowPlaying.displayEar && !fullscreen.isFrontmostFullscreen {
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

/// The left ear's content: a fixed 20x20 artwork square (or its no-artwork
/// fallback), inset `Tokens.Spacing.lg` (16pt) from the pill's outer left
/// edge — mirroring the timer readout's 16pt inset on the opposite ear so the
/// pill reads as balanced. Laid out within the symmetric 84pt
/// `NotchPanelController.barEar` ear (D-03, unchanged) but no longer fills it
/// with track-identity text.
///
/// **SUPERSEDED (2026-07-27, quick task 260727-sf0):** this ear originally
/// also carried a scrolling "Title — Artist" text row alongside the artwork,
/// with the layout arithmetic (leading pad, tile, gap, clipped text viewport,
/// trailing pad) that implied. The track-identity text row was removed; the
/// ear now carries the artwork tile alone.
private struct NowPlayingEarView: View {
    let nowPlaying: NowPlayingProvider

    private static let artworkSize: CGFloat = 20
    private static let artworkCornerRadius: CGFloat = 5

    var body: some View {
        // Shared ArtworkTile so the hairline ring + artwork-derived bloom live
        // once (also used by the 44pt panel tile). Gentle bloom on the ear
        // (radius 6, opacity 0.5). The no-artwork fallback keeps the identical
        // 20x20 footprint — a real session with no art (spike 002: the Apple TV
        // app) reads as "playing, no art," never the empty-ear treatment.
        ArtworkTile(
            artwork: nowPlaying.artwork,
            size: Self.artworkSize,
            cornerRadius: Self.artworkCornerRadius,
            bloomRadius: 6,
            bloomOpacity: 0.5
        )
        .padding(.leading, Tokens.Spacing.lg)
        // UI-SPEC "Paused-in-grace visual distinction" (D-06/D-07): the artwork tile dims to 55%
        // opacity during the 30s post-stop grace window. No new icon, border or badge; the
        // existing content just dims, and there is no exit animation when the window expires (it
        // simply stops rendering, per NotchBarView's existing show/hide gate).
        .opacity(nowPlaying.isPausedInGrace ? 0.55 : 1)
    }
}
