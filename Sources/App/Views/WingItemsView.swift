import SwiftUI
import MyIslandCore

/// The collapsed fluid pill's 16pt wing items (07-02 Task 2, D-02/agreement §2): a left and a
/// right slot sitting against the camera housing, ported unchanged in behaviour from the retired
/// pre-fluid ear renderers. Positions are the sketch's `WING` table
/// (`.planning/sketches/006-design-round/index.html:699`): physical ±103.5pt at y 18, synthetic
/// ±56pt at y 15, both measured from the pill's own center (`cx`) — this view is given the SAME
/// frame the fluid fill draws in (`NotchContentView`'s `openSize`), so its own local center lines
/// up with that `cx` for free.
///
/// Slot rule, amended 2026-10-02 (user decision). The wings show music only: artwork left and
/// sound wave right, whenever music is visible. A running or just-finished timer never takes a
/// wing; on every display it is `FluidOverlayView`'s outline timer line.
@MainActor
struct WingItemsView: View {
    let nowPlaying: NowPlayingProvider
    let fullscreen: FullscreenObserver
    let displayID: CGDirectDisplayID?
    let isPhysical: Bool
    let isOpen: Bool
    /// 07-04 Task 1 (FLUID-01, agreement §5): whether this display's collapsed surface is
    /// currently the fullscreen bulge — while true neither wing shows, and only the outline
    /// timer line (`FluidOverlayView`) and the alert drops draw on the bulge.
    let isBulge: Bool

    private static let builtinX: CGFloat = 92.5 + 3 + 8
    private static let builtinY: CGFloat = 18
    private static let dellX: CGFloat = 56
    private static let dellY: CGFloat = 15

    private var wingX: CGFloat { isPhysical ? Self.builtinX : Self.dellX }
    private var wingY: CGFloat { isPhysical ? Self.builtinY : Self.dellY }

    /// Mirrors the pre-fluid pill's music-visible gate exactly (T-7h2 Task 2 idiom): suppressed —
    /// absent, not dimmed — during content-fullscreen.
    private var musicVisible: Bool {
        nowPlaying.displayEar && !fullscreen.isAmbientSuppressed(on: displayID)
    }

    private var showsMusic: Bool { !isBulge && musicVisible }

    var body: some View {
        GeometryReader { proxy in
            let cx = proxy.size.width / 2
            ZStack(alignment: .topLeading) {
                if showsMusic {
                    ArtworkTile(artwork: nowPlaying.artwork, size: 16, cornerRadius: 4)
                        .opacity(nowPlaying.isPausedInGrace ? 0.55 : 1)
                        .position(x: cx - wingX, y: wingY)
                    WingSoundWaveView()
                        .opacity(nowPlaying.isPausedInGrace ? 0.55 : 1)
                        .position(x: cx + wingX, y: wingY)
                }
            }
        }
        .opacity(isOpen ? 0 : 1)
        .allowsHitTesting(false)
    }
}

/// Ported from the pre-fluid SoundWaveView (07-02 Task 2, "unchanged in behaviour"): five thin
/// bars whose amplitude tracks the real system-audio output level via `SystemAudioLevelProvider`,
/// fitted into the 16pt wing slot.
private struct WingSoundWaveView: View {
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
                        .fill(Self.barColor(index: index))
                        .frame(width: Self.barWidth, height: barHeight(index: index, time: t, level: level))
                        .shadow(color: Tokens.Color.accent.opacity(0.8), radius: 2.5)
                        .shadow(color: Tokens.Color.accent.opacity(0.5), radius: 4)
                }
            }
            .frame(width: 16, height: 16)
        }
        .frame(width: 16, height: 16)
        .onAppear { audio.start() }
        .onDisappear { audio.stop() }
        .accessibilityHidden(true)
    }

    private static func barColor(index: Int) -> SwiftUI.Color {
        let center = Double(barCount - 1) / 2
        let distance = center == 0 ? 0 : abs(Double(index) - center) / center
        let lightness = (1 - distance) * 0.5
        return Tokens.Color.accent.mix(with: Tokens.Color.accentInk, by: lightness)
    }

    private func barHeight(index: Int, time: Double, level: CGFloat) -> CGFloat {
        guard !reduceMotion else { return Self.minHeight + level * (Self.maxHeight - Self.minHeight) }
        let shape = (sin(time * 6 + Double(index) * 0.9) + 1) / 2 * 0.6 + 0.4
        return Self.minHeight + level * (Self.maxHeight - Self.minHeight) * CGFloat(shape)
    }
}
