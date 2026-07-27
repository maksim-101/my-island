import AppKit
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
            // No-artwork fallback (D-01, UI-SPEC "Collapsed left ear"): the
            // exact same 20x20 footprint, never removed — a real session with
            // no artwork (spike 002: the Apple TV app) must read as "playing,
            // no art" rather than snapping to the empty-ear treatment.
            RoundedRectangle(cornerRadius: Self.artworkCornerRadius)
                .fill(Tokens.Color.surfaceRaised)
                .frame(width: Self.artworkSize, height: Self.artworkSize)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Tokens.Color.textFaint)
                }
        }
    }
}

/// The ear's "Title — Artist" text (D-04, resolved scroll mechanics per
/// UI-SPEC "Collapsed left ear"). Static (no motion at all) when the text
/// fits the viewport; otherwise exactly ONE restrained pass per track change:
/// hold at the start 4s, scroll left ~6s to reveal the end, hold at the end
/// 2s, then a 200ms fade-cut back to the start — never a repeating marquee
/// (the user's own words: "don't loop too quickly... not necessary to have
/// like an ad banner all the time"). Keyed on the text value via `.task(id:)`
/// so the pass re-triggers only on a track change or when the view reappears
/// after being absent — never on a decorative timer.
private struct ScrollingEarText: View {
    let text: String
    let viewportWidth: CGFloat

    @State private var offset: CGFloat = 0

    /// A hostile source (an arbitrary web page) could publish an extremely
    /// long title/artist string — cap the text handed to measurement/layout
    /// before the ear ever lays it out; the viewport only ever reveals a
    /// couple hundred points of text, so a longer string contributes nothing
    /// but layout cost (T-05-07).
    private static let maxCharacters = 300
    private static let startHoldSeconds: Double = 4
    private static let scrollSeconds: Double = 6
    private static let endHoldSeconds: Double = 2
    private static let snapBackSeconds: Double = 0.2
    /// Matches `Tokens.Font.bodyMD` (`SwiftUI.Font.system(size: 12.5, weight:
    /// .regular)`) — measured directly via `NSFont`/`NSString` sizing rather
    /// than a `GeometryReader` round-trip, so the scroll decision is made
    /// synchronously with no first-layout race.
    private static let measuringFont = NSFont.systemFont(ofSize: 12.5, weight: .regular)

    private var boundedText: String {
        String(text.prefix(Self.maxCharacters))
    }

    private var measuredWidth: CGFloat {
        (boundedText as NSString).size(withAttributes: [.font: Self.measuringFont]).width
    }

    var body: some View {
        Text(boundedText)
            .font(Tokens.Font.bodyMD)
            .foregroundStyle(Tokens.Color.text)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .offset(x: offset)
            .frame(width: viewportWidth, alignment: .leading)
            .clipped()
            .task(id: boundedText) {
                await runScrollPass()
            }
    }

    private func runScrollPass() async {
        offset = 0
        let overflow = measuredWidth - viewportWidth
        guard overflow > 0 else { return }

        try? await Task.sleep(for: .seconds(Self.startHoldSeconds))
        guard !Task.isCancelled else { return }

        withAnimation(.linear(duration: Self.scrollSeconds)) {
            offset = -overflow
        }
        try? await Task.sleep(for: .seconds(Self.scrollSeconds))
        guard !Task.isCancelled else { return }

        try? await Task.sleep(for: .seconds(Self.endHoldSeconds))
        guard !Task.isCancelled else { return }

        withAnimation(.easeInOut(duration: Self.snapBackSeconds)) {
            offset = 0
        }
        // Stays parked at the start indefinitely after this — one pass only,
        // never a looping/re-arming animation (D-04).
    }
}
