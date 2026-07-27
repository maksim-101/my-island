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
            ScrollingEarText(text: earText, viewportWidth: Self.textViewportWidth, isFrozen: nowPlaying.isPausedInGrace)
        }
        .padding(.leading, Tokens.Spacing.sm)
        .padding(.trailing, Tokens.Spacing.sm)
        // UI-SPEC "Paused-in-grace visual distinction" (D-06/D-07): the whole ear — artwork tile and
        // text together — dims to 55% opacity during the 30s post-stop grace window. No new icon,
        // border or badge; the existing content just dims, and there is no exit animation when the
        // window expires (it simply stops rendering, per NotchBarView's existing show/hide gate).
        .opacity(nowPlaying.isPausedInGrace ? 0.55 : 1)
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
    /// True during the paused-in-grace window (UI-SPEC): halts the scroll pass immediately at
    /// whatever offset it currently holds and suppresses any further animation while set.
    let isFrozen: Bool

    @State private var offset: CGFloat = 0
    /// Live mirror of `isFrozen`, kept current via `.onChange` — read from inside `runScrollPass()`
    /// instead of `isFrozen` directly, because the pass's `.task(id:)` is keyed on the text alone and
    /// does NOT restart when `isFrozen` changes, so a plain captured `let` would go stale the moment
    /// the grace window opens or closes mid-pass. `@State`'s storage is shared across renders, so this
    /// mirror stays live even inside a task launched by an earlier render.
    @State private var frozenNow = false

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
    /// The scroll-out phase below drives `offset` via manual, un-animated per-tick assignment rather
    /// than a single `withAnimation(.linear(duration: scrollSeconds))` block, specifically so
    /// `frozenNow` can be sampled every tick — this is what makes the `isFrozen` doc comment's
    /// "halts the scroll pass immediately" claim true, instead of only true at the three coarse
    /// `await` points a single animated block would leave.
    private static let scrollTickInterval: Double = 1.0 / 30.0
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
            .onChange(of: isFrozen, initial: true) { _, newValue in
                frozenNow = newValue
            }
            .task(id: boundedText) {
                await runScrollPass()
            }
    }

    private func runScrollPass() async {
        offset = 0
        let overflow = measuredWidth - viewportWidth
        guard overflow > 0 else { return }

        try? await Task.sleep(for: .seconds(Self.startHoldSeconds))
        guard !Task.isCancelled, !frozenNow else { return }

        let scrollStart = Date()
        while true {
            guard !Task.isCancelled, !frozenNow else { return }
            let elapsed = Date().timeIntervalSince(scrollStart)
            guard elapsed < Self.scrollSeconds else { break }
            offset = -overflow * CGFloat(elapsed / Self.scrollSeconds)
            try? await Task.sleep(for: .seconds(Self.scrollTickInterval))
        }
        offset = -overflow

        try? await Task.sleep(for: .seconds(Self.endHoldSeconds))
        guard !Task.isCancelled, !frozenNow else { return }

        withAnimation(.easeInOut(duration: Self.snapBackSeconds)) {
            offset = 0
        }
        // Stays parked at the start indefinitely after this — one pass only,
        // never a looping/re-arming animation (D-04).
    }
}
