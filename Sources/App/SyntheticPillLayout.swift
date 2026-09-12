import CoreGraphics
import MyIslandCore

/// The single width/center-text derivation for the drawn (synthetic) pill on
/// a notchless screen — shared by `NotchBarView`'s layout and
/// `NotchPanelController`'s wing-hover math, so the two can never disagree
/// about how wide the pill currently is (D-01/D-02/D-04; SHELL-08's "hover
/// region equals the drawn pill" truth). Every component metric here is a
/// point value at scale 1; every call site multiplies by the live
/// `NotchGeometry.readoutScale(pillHeight:)`. The physical notch's pill
/// (`NotchBarView.pill`, `NotchPanelController.barFrame`) is untouched by
/// this type — it keeps its own asymmetric 48/76pt ear geometry.
@MainActor
enum SyntheticPillLayout {
    static let artworkSize: CGFloat = 20
    static let waveWidth: CGFloat = 18
    static let centerViewportWidth: CGFloat = 160
    static let timerReadoutWidth: CGFloat = 54
    static let idleMarkSize: CGFloat = 4
    /// 2026-09-12 amendment ("Fullscreen sliver on synthetic displays"): the drawn height of the
    /// sliver a synthetic display collapses to while `FullscreenObserver.isFrontmostFullscreen(on:)`
    /// is true — `Tokens.Spacing.xs` reused verbatim, fixed across every synthetic display
    /// regardless of that screen's own menu-bar height (the sliver represents no menu-bar surface,
    /// so it needs no per-screen height like the normal pill does).
    static let fullscreenSliverHeight: CGFloat = Tokens.Spacing.xs
    static let edgePadding: CGFloat = Tokens.Spacing.md
    static let clusterGap: CGFloat = Tokens.Spacing.sm
    static let sectionGap: CGFloat = Tokens.Spacing.md
    static let bottomCornerRadius: CGFloat = 14

    /// D-01/D-02: the width the live readout layout actually needs — the sum
    /// of every shown section (the left artwork+wave cluster counts as ONE
    /// section) plus one `sectionGap` between each pair of shown sections,
    /// plus `edgePadding` on both ends. Zero when nothing is shown at all —
    /// the idle state draws only the dim dot, never this formula, so an
    /// all-flags-false call must not report the padding alone.
    static func contentWidth(
        scale: CGFloat,
        showsArtwork: Bool,
        showsWave: Bool,
        showsCenter: Bool,
        showsTimer: Bool
    ) -> CGFloat {
        var sectionWidths: [CGFloat] = []
        if showsArtwork || showsWave {
            var cluster: CGFloat = 0
            if showsArtwork { cluster += artworkSize }
            if showsArtwork && showsWave { cluster += clusterGap }
            if showsWave { cluster += waveWidth }
            sectionWidths.append(cluster)
        }
        if showsCenter { sectionWidths.append(centerViewportWidth) }
        if showsTimer { sectionWidths.append(timerReadoutWidth) }

        guard !sectionWidths.isEmpty else { return 0 }

        let gaps = CGFloat(sectionWidths.count - 1) * sectionGap
        let total = edgePadding * 2 + sectionWidths.reduce(0, +) + gaps
        return total * scale
    }

    /// D-01: the drawn pill's actual width — content-driven, floored at
    /// `idleWidth` (the damped formula), capped at the expanded panel's own
    /// width so hostile/oversized content can never draw a pill wider than
    /// what will cover it once the panel opens.
    static func pillWidth(
        idleWidth: CGFloat,
        scale: CGFloat,
        showsArtwork: Bool,
        showsWave: Bool,
        showsCenter: Bool,
        showsTimer: Bool
    ) -> CGFloat {
        let content = contentWidth(
            scale: scale,
            showsArtwork: showsArtwork,
            showsWave: showsWave,
            showsCenter: showsCenter,
            showsTimer: showsTimer
        )
        return min(NotchLayout.expandedWidth, NotchGeometry.syntheticWidth(idleWidth: idleWidth, contentWidth: content))
    }

    /// The bar window's fixed width — every readout shown at once — so the
    /// window is always at least as wide as the pill can ever draw at the
    /// current scale.
    static func maxPillWidth(idleWidth: CGFloat, scale: CGFloat) -> CGFloat {
        pillWidth(idleWidth: idleWidth, scale: scale, showsArtwork: true, showsWave: true, showsCenter: true, showsTimer: true)
    }

    /// D-02's center-slot rule: the next-meeting countdown while a timer runs
    /// AND a meeting is upcoming, otherwise the Now Playing title/artist while
    /// music plays, otherwise nil (the idle dot). A running timer with no
    /// upcoming meeting falls through to the music branch — it does not
    /// suppress the center slot.
    static func centerText(
        timer: TimerViewModel,
        calendar: CalendarProvider,
        nowPlaying: NowPlayingProvider,
        earVisible: Bool
    ) -> String? {
        if timer.isRunning,
           let event = calendar.displayedEvents.first,
           let countdown = calendar.countdowns[event.id] {
            return countdown == "now" ? "\(event.title) now" : "\(event.title) in \(countdown)"
        }
        if earVisible {
            let model = nowPlaying.currentModel
            let text = NowPlayingFormatting.earText(title: model?.title, artist: model?.artist)
            return text.isEmpty ? nil : text
        }
        return nil
    }
}
