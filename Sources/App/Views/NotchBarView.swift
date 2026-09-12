import AppKit
import SwiftUI
import OSLog
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
///
/// **Phase 6 Plan 02 (2026-09-11, D-01..D-04) — the synthetic pill on a notchless screen.**
/// `body` now branches on `mode.isPhysical`: the physical branch (`physicalBody`/`pill`, above)
/// is untouched byte-for-byte — same ears, same asymmetric geometry, same fullscreen glow. The
/// synthetic branch (`syntheticPill`) is a genuinely different layout, not a re-parameterized
/// `pill`: after wave 1 shipped the Dell's drawn pill with the physical ear layout (artwork far
/// left, sound wave far right, empty center mimicking the camera housing), the user said
/// verbatim "the space is not really filled at all, or intelligently, or aesthetically." The
/// synthetic pill instead treats its whole content-driven width as live real estate — left
/// artwork+wave cluster, center track/meeting text, right timer — scaled to the pill's own
/// height (`NotchGeometry.readoutScale`), and is never hidden even when nothing is playing (a
/// dim center dot, D-03) since there is no physical cutout to fall back to.
@MainActor
struct NotchBarView: View {
    let timer: TimerViewModel
    let model: NotchViewModel
    let nowPlaying: NowPlayingProvider
    let fullscreen: FullscreenObserver
    let notchLocalFrame: CGRect
    /// Phase 6 Plan 02 (D-01..D-04): `calendar` feeds the synthetic pill's
    /// center-slot meeting countdown (`SyntheticPillLayout.centerText`);
    /// `mode` selects which branch of `body` renders — the physical pill is
    /// untouched, the synthetic pill is new. Both are unused by the physical
    /// branch.
    let calendar: CalendarProvider
    let mode: NotchGeometry.Mode
    /// Phase 6 Plan 03 (D-06): the screen this view is drawn on. Every suppression/glow read
    /// gates on THIS display, not the global fullscreen signal — a fullscreen window on one
    /// screen must never blank the other screen's island.
    let displayID: CGDirectDisplayID?

    /// Synthetic pill render diagnostics: derived width, shown-section flags, and the pill's
    /// own live-drawn geometry — the only observability into what the synthetic pill actually
    /// renders on a notchless display. `.notice` so it survives Release builds, but only reaches
    /// the log store when `MyIslandVerboseLogging` is set (see AppLog.swift) — silent no-op
    /// otherwise, zero cost to a normal run.
    private let pillDiagLogger = AppLog.make("SyntheticPillDiag")
    @State private var pillDiagWindowFrame: CGRect = .zero
    @State private var pillDiagPillBounds: CGRect = .zero

    /// How far the glow's stroke extends past the notch's own edges — only left, right and
    /// bottom (never top, which is the physical screen edge/cutout with nothing to gain by
    /// outsetting) — so the visible half of a centered 1pt stroke lands on real, rendered pixels
    /// beside and below the cutout rather than half inside the never-displayed camera housing.
    private static let glowLineOutset: CGFloat = 1.5

    /// 260801-7h2-regressions round 5: the deliberate gap between each wing's content and the
    /// notch cutout's own edge, now that both wings anchor toward the notch rather than toward
    /// the pill's outer edges. Reuses round 4's already-verified artwork clearance (`Tokens
    /// .Spacing.md`, 12pt) — the amount that took the artwork from "scraping the border" (4pt) to
    /// comfortable (12pt) — so this fix cannot recreate that complaint by hugging tighter than
    /// what was already confirmed to read as intentional spacing, not crowding.
    fileprivate static let wingNotchGap: CGFloat = Tokens.Spacing.md

    var body: some View {
        if mode.isPhysical {
            physicalBody
        } else {
            // Phase 6 Plan 02 (D-01..D-04, 2026-09-11): the synthetic pill on a
            // notchless screen never mimics the physical notch's asymmetric
            // ear geometry or its empty camera-housing center — the whole
            // drawn width is live real estate (user feedback after wave 1:
            // "the space is not really filled at all"). No fullscreen glow —
            // there is no cutout to locate, the pill is always visible (D-03).
            //
            // 2026-09-12 amendment ("Fullscreen sliver on synthetic displays"): UAT row 5 found
            // that suppressing readouts alone still leaves the full-height pill sitting on real
            // fullscreen picture, since there is no camera housing here to justify the occupied
            // pixels. While `isFrontmostFullscreenHere` (the same signal driving the built-in's
            // own notch-locator glow, not the narrower `isAmbientSuppressed`) is true, the pill
            // withdraws to a 4pt glowing `Capsule` marker instead of drawing content.
            VStack(spacing: 0) {
                Group {
                    if isFrontmostFullscreenHere {
                        fullscreenSliver
                    } else {
                        syntheticPill
                            .transition(.opacity)
                    }
                }
                .frame(height: isFrontmostFullscreenHere ? SyntheticPillLayout.fullscreenSliverHeight : notchLocalFrame.height)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(NotchLayout.morphAnimation, value: isFrontmostFullscreenHere)
            .onChange(of: isFrontmostFullscreenHere) { _, newValue in
                pillDiagLogger.notice("""
                    sliverState display=\(displayID.map(String.init) ?? "none", privacy: .public) \
                    active=\(newValue, privacy: .public)
                    """)
            }
        }
    }

    /// 2026-09-12 amendment: the fullscreen sliver — a pure hover affordance, never
    /// content-driven. Width is pinned to `notchLocalFrame.width` (the idle damped-width formula,
    /// unconditionally — never `SyntheticPillLayout.pillWidth`'s content floor, since the sliver
    /// draws no readout content regardless of what is playing or running). Reuses the built-in's
    /// own fullscreen-glow numbers verbatim (`glowLineOutset`'s stroke/shadow opacities), just
    /// reassigned from an outline-only overlay to a filled `Capsule` — full rounding on all four
    /// corners reads as a glow affordance rather than attached menu-bar chrome, unlike `NotchShape`'s
    /// square-top/rounded-bottom treatment (meaningless at 4pt tall). Static, never pulsing — the
    /// built-in's own fullscreen glow only fades, it never pulses either.
    private var fullscreenSliver: some View {
        Capsule()
            .fill(Color.black)
            .overlay(
                Capsule().stroke(Tokens.Color.accent.opacity(0.45), lineWidth: 1)
            )
            .shadow(color: Tokens.Color.accent.opacity(0.35), radius: 3)
            .frame(width: notchLocalFrame.width, height: SyntheticPillLayout.fullscreenSliverHeight)
            .transition(.opacity)
    }

    /// Phase 6 Plan 03 (D-06): the notch-locator glow is per-display too — a fullscreen window on
    /// the OTHER screen must not draw THIS screen's glow. A single computed property backs both
    /// consuming sites below (the `if` and the `.animation` trigger) so they can never disagree.
    private var isFrontmostFullscreenHere: Bool { fullscreen.isFrontmostFullscreen(on: displayID) }

    private var physicalBody: some View {
        VStack(spacing: 0) {
            pill
                .frame(height: notchLocalFrame.height)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if isFrontmostFullscreenHere {
                // topCornerRadius: 0, NOT `pill`'s 6 — see 260801-7h2-regressions round 3.
                // `NotchShape.path(in:)` draws its top corners CONCAVE (the "ear" flowing into the
                // physical camera housing), which keeps the LEFT/RIGHT vertical edges inset from
                // the shape's own frame by `topCornerRadius` (the `addLine` calls hold x constant
                // at `rect.minX + topCornerRadius`/`rect.maxX - topCornerRadius`, never at
                // `rect.minX`/`rect.maxX`). With `topCornerRadius: 6` and `glowLineOutset: 1.5`,
                // those edges land 4.5pt INSIDE the notch cutout — on pixels that physically never
                // render — so only the bottom edge (unaffected, keyed off `bottomCornerRadius`
                // relative to `rect.maxY`) was ever visible once the fade-in settled. The top edge
                // itself is never visible either way (physical screen edge, y<=0), so zeroing its
                // radius costs nothing cosmetically while moving the vertical edges out to the
                // shape's own frame bounds — verified with an offscreen ImageRenderer harness
                // (scratchpad/glow_geometry_probe.swift) showing the stroke lands squarely outside
                // a rendered stand-in for the cutout only after this change.
                NotchShape(topCornerRadius: 0, bottomCornerRadius: 14)
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
        .animation(.easeInOut(duration: 0.25), value: isFrontmostFullscreenHere)
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
            if (timer.isRunning || (nowPlaying.displayEar && !fullscreen.isAmbientSuppressed(on: displayID))) && !model.isOpen {
                NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
                    .fill(Color.black)
                    .overlay(alignment: .leading) {
                        // The timer readout always wins the right wing. Only when
                        // no timer is running and music is playing does the wing
                        // instead show the animated sound-wave equalizer.
                        //
                        // 260801-7h2-regressions round 5: anchored via `.padding(.leading, ...)`
                        // computed from `notchLocalFrame.maxX` (the notch cutout's own right edge),
                        // not `.overlay(alignment: .trailing)` on the full pill — the latter anchors
                        // to the PILL's own outer/right edge (the far side of the right ear), which
                        // for short content (the sound-wave, ~18pt) left a lopsided ~42pt gap next
                        // to the notch and only Spacing.lg (16pt) at the true outer edge. Padding by
                        // an absolute magnitude places the content's leading edge at exactly that x
                        // regardless of the pill's total width, so both the timer digits and the
                        // sound-wave "hug" the notch with the same small, deliberate gap — the timer
                        // readout inherits this for free rather than as a special case.
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
                            .padding(.leading, notchLocalFrame.maxX + Self.wingNotchGap)
                        } else if nowPlaying.displayEar && !fullscreen.isAmbientSuppressed(on: displayID) {
                            SoundWaveView()
                                .padding(.leading, notchLocalFrame.maxX + Self.wingNotchGap)
                                .opacity(nowPlaying.isPausedInGrace ? 0.55 : 1)
                        }
                    }
                    .overlay(alignment: .leading) {
                        if nowPlaying.displayEar && !fullscreen.isAmbientSuppressed(on: displayID) {
                            NowPlayingEarView(nowPlaying: nowPlaying, notchMinX: notchLocalFrame.minX)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The drawn pill on a notchless screen (D-01..D-04). Unlike `pill`, this
    /// is shown whenever the panel is collapsed — never gated on timer/ear
    /// content (D-03: the black bar with a dim center dot is the "app is
    /// alive" affordance, not a conditional readout). Width is
    /// content-driven (`SyntheticPillLayout.pillWidth`) and every readout
    /// scales with `NotchGeometry.readoutScale(pillHeight:)`.
    private var syntheticPill: some View {
        Group {
            if !model.isOpen {
                let scale = NotchGeometry.readoutScale(pillHeight: notchLocalFrame.height)
                let showsTimer = timer.isRunning
                let earVisible = nowPlaying.displayEar && !fullscreen.isAmbientSuppressed(on: displayID)
                let center = SyntheticPillLayout.centerText(timer: timer, calendar: calendar, nowPlaying: nowPlaying, earVisible: earVisible)
                let showsCenter = center != nil
                let width = SyntheticPillLayout.pillWidth(
                    idleWidth: notchLocalFrame.width,
                    scale: scale,
                    showsArtwork: earVisible,
                    showsWave: earVisible,
                    showsCenter: showsCenter,
                    showsTimer: showsTimer
                )
                // `let _ =` (not a bare statement): a Void-returning call is not itself a `View`,
                // and this sits inside a `@ViewBuilder` `if` branch — the standard escape hatch
                // for a side effect mid-body (SwiftUI's own documented pattern for this exact
                // situation, e.g. `let _ = print(...)`).
                let _ = pillDiagLogger.notice("""
                    pillState display=\(displayID.map(String.init) ?? "none", privacy: .public) mode=synthetic \
                    width=\(width, privacy: .public) showsArtwork=\(earVisible, privacy: .public) \
                    showsWave=\(earVisible, privacy: .public) showsCenter=\(showsCenter, privacy: .public) \
                    showsTimer=\(showsTimer, privacy: .public)
                    """)
                NotchShape(topCornerRadius: 0, bottomCornerRadius: SyntheticPillLayout.bottomCornerRadius)
                    .fill(Color.black)
                    .overlay {
                        if !earVisible && !showsCenter && !showsTimer {
                            // D-03: never hidden, never translucent — a dim resting
                            // dot rather than a resting sound-wave, since a wave
                            // implies audio that isn't playing.
                            Circle()
                                .fill(Tokens.Color.textFaint)
                                .frame(width: SyntheticPillLayout.idleMarkSize * scale, height: SyntheticPillLayout.idleMarkSize * scale)
                                .opacity(0.7)
                        } else {
                            // Two always-present Spacers (not a uniform HStack
                            // spacing) so the gap appears only BETWEEN shown
                            // sections — a uniform `spacing:` would double-count
                            // against `SyntheticPillLayout.contentWidth`'s single
                            // gap-per-boundary math and overflow the pill.
                            HStack(spacing: 0) {
                                if earVisible {
                                    HStack(spacing: SyntheticPillLayout.clusterGap * scale) {
                                        ArtworkTile(
                                            artwork: nowPlaying.artwork,
                                            size: SyntheticPillLayout.artworkSize * scale,
                                            cornerRadius: 5 * scale
                                        )
                                        SoundWaveView(scale: scale)
                                    }
                                    .opacity(nowPlaying.isPausedInGrace ? 0.55 : 1)
                                }
                                Spacer(minLength: earVisible && (showsCenter || showsTimer) ? SyntheticPillLayout.sectionGap * scale : 0)
                                if let center {
                                    ScrollingTrackText(
                                        text: center,
                                        isFrozen: nowPlaying.isPausedInGrace && !timer.isRunning,
                                        pointSize: Tokens.Font.bodyMDSize * scale
                                    )
                                    .frame(width: SyntheticPillLayout.centerViewportWidth * scale)
                                    .foregroundStyle(Tokens.Color.text)
                                }
                                Spacer(minLength: showsCenter && showsTimer ? SyntheticPillLayout.sectionGap * scale : 0)
                                if showsTimer {
                                    HStack(spacing: 4 * scale) {
                                        Circle()
                                            .fill(Tokens.timerColor(for: timer.tokenState))
                                            .frame(width: 6 * scale, height: 6 * scale)
                                        Text(formatted(timer.remaining))
                                            .font(.system(size: 12 * scale, weight: .medium).monospaced())
                                            .foregroundStyle(Tokens.Color.text)
                                            .fixedSize()
                                    }
                                }
                            }
                            .padding(.horizontal, SyntheticPillLayout.edgePadding * scale)
                        }
                    }
                    .frame(width: width)
                    .animation(NotchLayout.morphAnimation, value: width)
                    // The pill's own live-drawn global bounds — during a `morphAnimation`
                    // tween this can differ from `width` above, which is only the animation target.
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { newValue in
                        pillDiagPillBounds = newValue
                        pillDiagLogger.notice("pillGeom window=\(NSStringFromRect(pillDiagWindowFrame), privacy: .public) pill=\(NSStringFromRect(newValue), privacy: .public)")
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The bar window's own live-drawn bounds — this frame fills its entire content view.
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { newValue in
            pillDiagWindowFrame = newValue
            pillDiagLogger.notice("pillGeom window=\(NSStringFromRect(newValue), privacy: .public) pill=\(NSStringFromRect(pillDiagPillBounds), privacy: .public)")
        }
    }

    private func formatted(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The left ear's content: a fixed 20x20 artwork square (or its no-artwork
/// fallback), inset from the notch cutout's own left edge (`notchMinX`) by
/// `NotchBarView.wingNotchGap` (12pt) — mirroring the timer/sound-wave wing's
/// same near-notch gap on the opposite ear so the pill reads as balanced.
/// Laid out within the symmetric 84pt `NotchPanelController.barEar` ear
/// (D-03, unchanged) but no longer fills it with track-identity text.
///
/// **260801-7h2-regressions round 5:** was inset `Tokens.Spacing.lg` (16pt) from the pill's
/// OUTER left edge (the wing's own far edge, away from the notch) — anchored to the wrong
/// reference frame, which the user reported as looking lopsided next to the sound-wave/timer
/// wing's identical outer-edge anchoring on the right. Re-anchored to the notch cutout's edge
/// instead: `notchMinX - wingNotchGap - artworkSize` places the artwork's own trailing edge
/// exactly `wingNotchGap` short of the notch, regardless of how wide the left ear itself is.
///
/// **SUPERSEDED (2026-07-27, quick task 260727-sf0):** this ear originally
/// also carried a scrolling "Title — Artist" text row alongside the artwork,
/// with the layout arithmetic (leading pad, tile, gap, clipped text viewport,
/// trailing pad) that implied. The track-identity text row was removed; the
/// ear now carries the artwork tile alone.
private struct NowPlayingEarView: View {
    let nowPlaying: NowPlayingProvider
    /// The notch cutout's own local left edge (`notchLocalFrame.minX`) — passed down so this
    /// view can anchor its own padding to the notch rather than to the pill's outer edge.
    let notchMinX: CGFloat

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
        .padding(.leading, notchMinX - NotchBarView.wingNotchGap - Self.artworkSize)
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

    /// D-04: scales the wave's height only — bar width/spacing stay fixed so
    /// the bars remain crisp on the synthetic pill. Defaults to 1 so the
    /// physical wing's existing call site is unaffected.
    var scale: CGFloat = 1

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
            .frame(height: Self.maxHeight * scale)
        }
        .frame(height: Self.maxHeight * scale)
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
        let minHeight = Self.minHeight * scale
        let span = (Self.maxHeight - Self.minHeight) * scale
        guard !reduceMotion else { return minHeight + level * span }
        // Per-bar travelling shape in 0.4…1.0, scaled by the live level — so amplitude follows the
        // music and silence (level 0) is a flat, still row.
        let shape = (sin(time * 6 + Double(index) * 0.9) + 1) / 2 * 0.6 + 0.4
        return minHeight + level * span * CGFloat(shape)
    }
}
