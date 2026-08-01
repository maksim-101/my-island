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
///
/// **T-7h2 Task 3 — fullscreen notch-locator glow.** `NotchPanelController.makeBarPanel` grows
/// this view's window `glowOutset` (3pt) taller than the notch, downward only, so there's real,
/// rendered panel below the (otherwise-invisible) camera cutout for a hairline to actually show
/// on. `notchLocalFrame` is the notch's position within that taller view (SwiftUI's top-down
/// coordinate space, so `y: 0` is the physical notch top, unchanged by the outward growth). The
/// pill above stays pinned to exactly `notchLocalFrame.height` so it renders pixel-identically to
/// before this task; the glow draws in the space below/beside it, gated on
/// `fullscreen.isFrontmostFullscreen` — the plain APP-fullscreen signal, deliberately NOT Task 2's
/// content-fullscreen rule, since the physical notch is hidden by the black bar in every
/// fullscreen mode, media or not.
@MainActor
struct NotchBarView: View {
    let timer: TimerViewModel
    let model: NotchViewModel
    let nowPlaying: NowPlayingProvider
    let fullscreen: FullscreenObserver
    let notchLocalFrame: CGRect

    /// How far the glow's stroke extends past the notch's own edges — only left, right and
    /// bottom (never top, which is the physical screen edge/cutout with nothing to gain by
    /// outsetting) — so the visible half of a centered 1pt stroke lands on real, rendered pixels
    /// beside and below the cutout rather than half inside the never-displayed camera housing.
    private static let glowLineOutset: CGFloat = 1.5

    var body: some View {
        VStack(spacing: 0) {
            pill
                .frame(height: notchLocalFrame.height)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if fullscreen.isFrontmostFullscreen {
                NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
                    .stroke(Tokens.Color.accent.opacity(0.45), lineWidth: 1)
                    .shadow(color: Tokens.Color.accent.opacity(0.35), radius: 3)
                    .frame(
                        width: notchLocalFrame.width + Self.glowLineOutset * 2,
                        height: notchLocalFrame.height + Self.glowLineOutset
                    )
                    .offset(x: notchLocalFrame.minX - Self.glowLineOutset, y: notchLocalFrame.minY)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: fullscreen.isFrontmostFullscreen)
    }

    private var pill: some View {
        Group {
            // T-7h2 Task 2: the Now Playing ear is suppressed — absent, not dimmed — by
            // FullscreenClassifier's content-takeover rule (chromeless/titleless fullscreen
            // window), NOT plain app-fullscreen — see FullscreenObserver's doc comment and
            // CONTEXT.md's post-research decisions. Safari content-fullscreen (a video/player
            // element taking over) suppresses; Safari/Vivaldi Spaces-fullscreen browsing does
            // not (the user is "still operating within the browser"); any non-browser
            // fullscreen app (IINA, QuickTime, TV.app, games) suppresses on plain
            // app-fullscreen. The `timer.isRunning ||` disjunct is deliberately OUTSIDE the
            // suppressed parenthesis — a running timer still shows in every fullscreen state
            // and still keeps the pill up on its own. Do not "simplify" this into a single
            // shared condition; that would silently re-suppress the timer too and break Phase 4
            // D-01.
            if (timer.isRunning || (nowPlaying.displayEar && !fullscreen.isAmbientSuppressed)) && !model.isOpen {
                NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
                    .fill(Color.black)
                    .overlay(alignment: .trailing) {
                        // The timer readout always wins the right wing. Only when
                        // no timer is running and music is playing does the wing
                        // instead show the animated sound-wave equalizer.
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
                        } else if nowPlaying.displayEar && !fullscreen.isAmbientSuppressed {
                            SoundWaveView()
                                .padding(.trailing, Tokens.Spacing.lg)
                                .opacity(nowPlaying.isPausedInGrace ? 0.55 : 1)
                        }
                    }
                    .overlay(alignment: .leading) {
                        if nowPlaying.displayEar && !fullscreen.isAmbientSuppressed {
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
        // Shared ArtworkTile so the neon-edge treatment lives once (also used by
        // the 44pt panel tile). The no-artwork fallback keeps the identical
        // 20x20 footprint — a real session with no art (spike 002: the Apple TV
        // app) reads as "playing, no art," never the empty-ear treatment.
        ArtworkTile(
            artwork: nowPlaying.artwork,
            size: Self.artworkSize,
            cornerRadius: Self.artworkCornerRadius
        )
        .padding(.leading, Tokens.Spacing.lg)
        // UI-SPEC "Paused-in-grace visual distinction" (D-06/D-07): the artwork tile dims to 55%
        // opacity during the 30s post-stop grace window. No new icon, border or badge; the
        // existing content just dims, and there is no exit animation when the window expires (it
        // simply stops rendering, per NotchBarView's existing show/hide gate).
        .opacity(nowPlaying.isPausedInGrace ? 0.55 : 1)
    }
}

/// The right wing's sound-wave equalizer, shown while music plays and no timer is running
/// (idle-wing-and-chrome.html). Five thin neutral bars (`Tokens.Color.text` @ 0.8) whose overall
/// amplitude tracks REAL system-audio output level via `SystemAudioLevelProvider` — so the bars
/// pump with the music and, crucially, go flat and still the instant playback pauses (no audio →
/// `level` decays to 0). A gentle per-bar travelling sinusoid gives the equalizer its life, but it
/// is scaled by the live level, so silence is genuinely still. The tap is started on appear and
/// stopped on disappear, so it only runs while the wave is actually shown. Reduce Motion drops the
/// sinusoid and shows a pure amplitude bar. If the tap can't start (permission/OS), `level` stays 0
/// and the bars simply stay flat — never the old fake animation.
private struct SoundWaveView: View {
    @State private var audio = SystemAudioLevelProvider()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let barCount = 5
    private static let barWidth: CGFloat = 2
    private static let barSpacing: CGFloat = 2
    private static let maxHeight: CGFloat = 12
    private static let minHeight: CGFloat = 4

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let level = CGFloat(min(1, max(0, audio.level)))
            HStack(alignment: .center, spacing: Self.barSpacing) {
                ForEach(0..<Self.barCount, id: \.self) { index in
                    Capsule()
                        // Indigo `accent` is DESIGN.md's now-playing color; graded across the row
                        // (darker `accent` at the two ends → lighter toward `accentInk` in the
                        // middle) with a same-hue glow for the Alcove-style neon finish. On-token
                        // only (never amber, never the coral/mint timer hues).
                        .fill(Self.barColor(index: index))
                        .frame(width: Self.barWidth, height: barHeight(index: index, time: t, level: level))
                        .shadow(color: Tokens.Color.accent.opacity(0.8), radius: 2.5)
                        .shadow(color: Tokens.Color.accent.opacity(0.5), radius: 4)
                }
            }
            .frame(height: Self.maxHeight)
        }
        .frame(height: Self.maxHeight)
        .onAppear { audio.start() }
        .onDisappear { audio.stop() }
        .accessibilityHidden(true)
    }

    /// Horizontal color grade: pure `accent` at the outer bars, lightened toward `accentInk` at the
    /// center, symmetric about the middle bar.
    private static func barColor(index: Int) -> SwiftUI.Color {
        let center = Double(barCount - 1) / 2
        let distance = center == 0 ? 0 : abs(Double(index) - center) / center // 0 center … 1 ends
        let lightness = (1 - distance) * 0.5
        return Tokens.Color.accent.mix(with: Tokens.Color.accentInk, by: lightness)
    }

    private func barHeight(index: Int, time: Double, level: CGFloat) -> CGFloat {
        let span = Self.maxHeight - Self.minHeight
        guard !reduceMotion else { return Self.minHeight + level * span }
        // Per-bar travelling shape in 0.4…1.0, scaled by the live level — so amplitude follows the
        // music and silence (level 0) is a flat, still row.
        let shape = (sin(time * 6 + Double(index) * 0.9) + 1) / 2 * 0.6 + 0.4
        return Self.minHeight + level * span * CGFloat(shape)
    }
}
