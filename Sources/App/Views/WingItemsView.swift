import SwiftUI
import MyIslandCore

/// The collapsed fluid pill's 16pt wing items (07-02 Task 2, D-02/agreement §2): a left and a
/// right slot sitting against the camera housing, ported unchanged in behaviour from the retired
/// `NotchBarView`'s ear renderers. Positions are the sketch's `WING` table
/// (`.planning/sketches/006-design-round/index.html:699`): physical ±103.5pt at y 18, synthetic
/// ±56pt at y 15, both measured from the pill's own center (`cx`) — this view is given the SAME
/// frame the collapsed fill draws in (`NotchContentView`'s `collapsedSize`), so its own local
/// center lines up with that `cx` for free.
///
/// Slot rule (agreement §2): music alone → left artwork, right sound wave; a running timer alone →
/// right clock-face only; both together → right clock-face (the timer always wins the right wing),
/// left = the Settings-picked choice below (07-02 Task 3, default artwork — with no timer running
/// this setting has no visible effect, per its own invariant test). The timer disjunct for the
/// right slot sits OUTSIDE the fullscreen suppression — a running timer keeps showing in every
/// fullscreen state, mirroring the physical wing's pre-fluid gate exactly.
@MainActor
struct WingItemsView: View {
    let timer: TimerViewModel
    let nowPlaying: NowPlayingProvider
    let fullscreen: FullscreenObserver
    let displayID: CGDirectDisplayID?
    let isPhysical: Bool
    let isOpen: Bool

    /// 07-02 Task 3: read live so flipping the Settings picker updates the wing immediately with
    /// no panel rebuild. An unknown stored value (T-06-08) degrades to `.artwork` in `leftSlot`
    /// below, never crashes and never silently reads as `.wave`.
    @AppStorage(NotchPanelController.wingLeftContentKey) private var wingLeftContent = NotchPanelController.wingLeftContentDefault

    private static let builtinX: CGFloat = 92.5 + 3 + 8
    private static let builtinY: CGFloat = 18
    private static let dellX: CGFloat = 56
    private static let dellY: CGFloat = 15

    private var wingX: CGFloat { isPhysical ? Self.builtinX : Self.dellX }
    private var wingY: CGFloat { isPhysical ? Self.builtinY : Self.dellY }

    /// Mirrors `NotchBarView.pill`'s music-visible gate exactly (T-7h2 Task 2 idiom): suppressed —
    /// absent, not dimmed — during content-fullscreen, never gated by the plain app-fullscreen
    /// signal the timer disjunct below deliberately ignores.
    private var musicVisible: Bool {
        nowPlaying.displayEar && !fullscreen.isAmbientSuppressed(on: displayID)
    }

    private enum Slot {
        case artwork
        case wave
        case timerFace
    }

    private var leftSlot: Slot? {
        guard musicVisible else { return nil }
        // The Settings choice only ever matters when the timer ALSO runs — with no timer, music
        // alone is always artwork (agreement §2), so this branch is the setting's one visible
        // effect, and the invariant test (no timer → no visible effect) holds by construction.
        guard timer.isRunning else { return .artwork }
        return wingLeftContent == "wave" ? .wave : .artwork
    }

    private var rightSlot: Slot? {
        // The timer disjunct sits OUTSIDE `musicVisible`'s fullscreen suppression — a running
        // timer still shows in every fullscreen state, same as the pre-fluid physical wing.
        if timer.isRunning { return .timerFace }
        if musicVisible { return .wave }
        return nil
    }

    var body: some View {
        GeometryReader { proxy in
            let cx = proxy.size.width / 2
            ZStack(alignment: .topLeading) {
                if let leftSlot {
                    slotView(leftSlot)
                        .position(x: cx - wingX, y: wingY)
                }
                if let rightSlot {
                    slotView(rightSlot)
                        .position(x: cx + wingX, y: wingY)
                }
            }
        }
        .opacity(isOpen ? 0 : 1)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func slotView(_ slot: Slot) -> some View {
        switch slot {
        case .artwork:
            ArtworkTile(artwork: nowPlaying.artwork, size: 16, cornerRadius: 4)
                .opacity(nowPlaying.isPausedInGrace ? 0.55 : 1)
        case .wave:
            WingSoundWaveView()
                .opacity(nowPlaying.isPausedInGrace ? 0.55 : 1)
        case .timerFace:
            WingTimerClockFace(timer: timer)
        }
    }
}

/// Ported from `NotchBarView.SoundWaveView` (07-02 Task 2, "unchanged in behaviour"): five thin
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

/// Ported from `NotchBarView.timerRing` (07-02 Task 2, "unchanged in behaviour"): a 16pt clock-face
/// whose wedge sweeps from 12 o'clock over `timer.progressFraction`, in the timer's own state
/// color, with the same accessibility label/value.
private struct WingTimerClockFace: View {
    let timer: TimerViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            let color = Tokens.timerColor(for: timer.tokenState)
            Circle()
                .fill(color.opacity(0.18))
            Circle()
                .inset(by: 4)
                .trim(from: 0, to: timer.progressFraction)
                .stroke(color.opacity(0.65), style: StrokeStyle(lineWidth: 8, lineCap: .butt))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .linear(duration: 1), value: timer.progressFraction)
            Circle()
                .strokeBorder(color.opacity(0.35), lineWidth: 0.5)
        }
        .frame(width: Tokens.Spacing.lg, height: Tokens.Spacing.lg)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timer")
        .accessibilityValue("\(formatted(timer.remaining)) remaining")
    }

    private func formatted(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
