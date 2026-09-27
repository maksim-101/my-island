import SwiftUI
import MyIslandCore

/// The click-through overlay's content (07-02 Task 1): rim + glow drawn in a window that is
/// ALWAYS `ignoresMouseEvents = true` (`NotchPanelController.makeOverlayPanel`), so no halo pixel
/// can ever catch a click regardless of which click-through mechanism the interactive panel below
/// uses. Ordered in front of the interactive panel — later plans draw the drop's neck and the
/// pulse from here too. Hidden while the panel is open (no outline concept for the expanded band
/// until plan 08).
struct FluidOverlayView: View {
    let motion: FluidMotion
    let model: NotchViewModel
    /// 07-02 Task 3 (D-07): whether this window's own display can ever render glass — always
    /// `false` on the MacBook, mirroring `NotchContentView.fillView`'s `!isPhysical` gate exactly
    /// so the two views can never disagree about which material is showing.
    let isPhysical: Bool
    /// 07-04 Task 2 (FEEL-02, PANEL-07 amended): the same `TimerViewModel` instance
    /// `NotchPanelController` threads everywhere else — this view reads `isRunning`/`isPaused`/
    /// `progressFraction`/`finishedAt`/`finishedTokenState` to drive the bulge's outline timer
    /// line and the three-ring finished pulse.
    let timer: TimerViewModel
    /// Threaded through for the SAME `isFullscreenBulge` computation `NotchContentView`/
    /// `WingItemsView` already do — the outline timer line only ever draws on the bulge; the
    /// desktop pill and MacBook pill keep their wing clock-face instead (Task 1).
    let fullscreen: FullscreenObserver
    let displayID: CGDirectDisplayID?
    /// 07-05 Task 1 (FLUID-02/PANEL-07): the same shared arbiter `NotchPanelController` already
    /// threads everywhere else — this view reads `isShowingHUD`/`glyph`/`level` to draw the HUD
    /// drop here (the click-through window); a linked meeting drop instead lives in the
    /// interactive panel (Task 3) so its Join button can take clicks.
    let hud: HUDViewModel

    /// Read live (like `NotchContentView`'s own copy) so switching in Settings drops/restores the
    /// glow with no panel rebuild.
    @AppStorage(NotchPanelController.surfaceMaterialKey) private var surfaceMaterial = NotchPanelController.surfaceMaterialDefault

    /// The overlay keeps the rim but drops the glow for glass (07-02 Task 3, D-07) — the glass
    /// material already carries its own specular highlight; stacking the accent glow on top read
    /// as muddy.
    private var isGlass: Bool { !isPhysical && surfaceMaterial == "glass" }

    /// Mirrors `NotchContentView.isBulge`/`NotchPanelController.isFullscreenBulge(for:)` exactly.
    private var isBulge: Bool { !isPhysical && fullscreen.isFrontmostFullscreen(on: displayID) }

    /// Agreement §5: only the bulge's own outline ever carries the timer line — while collapsed,
    /// running or JUST finished (the line reaches 100% right as the pulse starts).
    private var showsTimerLine: Bool { isBulge && (timer.isRunning || timer.finishedAt != nil) }

    /// The colour the timer line (and, while finished, the clock-face) draws in — `tokenState`
    /// reads nil once `engine.mode` clears at completion, so `finishedTokenState` (captured right
    /// before) is the only source left that still knows which colour just finished.
    private var lineTokenState: Tokens.TimerState? {
        timer.finishedAt != nil ? timer.finishedTokenState : timer.tokenState
    }

    var body: some View {
        if !model.isOpen {
            let glow = max(0, motion.channels[.glow] ?? 0.2)
            ZStack {
                // The glow: the closed outline filled and blurred, with the outline's own
                // (unblurred) interior punched out so only the halo bleeding past the fill's edge
                // is visible — the fill itself already reads as solid black from the interactive
                // panel underneath. Dropped entirely for glass (D-07, Task 3).
                if !isGlass {
                    FluidOutlineShape(params: motion.params, closed: true)
                        .fill(Tokens.Color.accent)
                        .blur(radius: 5)
                        .opacity(glow)
                        .overlay {
                            FluidOutlineShape(params: motion.params, closed: true)
                                .fill(.black)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                }

                // The rim: a thin open-path stroke along the same outline — kept for every material.
                FluidOutlineShape(params: motion.params, closed: false)
                    .stroke(Tokens.Color.accent, lineWidth: 0.9)
                    .opacity(0.32 + max(0, glow - 0.2))

                // 07-04 Task 2 (FLUID-01/FEEL-02, agreement §5): the bulge's own outline IS the
                // timer — a line in the timer's colour runs from the outline's left end and
                // reaches the right end at 100%, dims to 45% while paused, and fades out while the
                // band is open (`bandAlpha` — unset before plan 08, so this is full-strength
                // today). `motion.channels[.timerProgress]` is driven toward the live target by
                // `updateTimerLine()` below; this view only ever READS the spring's current value,
                // never steps it directly (RESEARCH.md Pitfall 2).
                if showsTimerLine {
                    let channel = max(0, min(1, motion.channels[.timerProgress] ?? 0))
                    FluidOutlineShape(params: motion.params, closed: false)
                        .trim(from: 0, to: channel)
                        .stroke(Tokens.timerColor(for: lineTokenState), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .opacity((timer.isPaused ? 0.45 : 0.9) * max(0, 1 - (motion.channels[.bandAlpha] ?? 0) * 3))
                }

                // 07-04 Task 2 (PANEL-07 amended, agreement §6): the finished-timer pulse — three
                // rings of the current collapsed outline expanding outward in the finished colour
                // while the glow tints to match, ~3.2s in all (`FluidPulse.duration`), then gone.
                // Drawn on whichever collapsed surface is showing (pill OR bulge) — unlike the
                // timer line above, this is NOT gated on `isBulge`. `TimelineView(.animation)`
                // only exists while `finishedAt` is set, so this costs nothing the other 99% of
                // the time an island sits collapsed and idle.
                if let finishedAt = timer.finishedAt {
                    TimelineView(.animation) { context in
                        let elapsed = context.date.timeIntervalSince(finishedAt)
                        let pulseColor = Tokens.timerColor(for: timer.finishedTokenState)
                        ZStack {
                            FluidOutlineShape(params: motion.params, closed: true)
                                .fill(pulseColor)
                                .blur(radius: 5)
                                .opacity(FluidPulse.glowBeat(elapsed: elapsed))
                                .overlay {
                                    FluidOutlineShape(params: motion.params, closed: true)
                                        .fill(.black)
                                        .blendMode(.destinationOut)
                                }
                                .compositingGroup()

                            ForEach(0..<3, id: \.self) { n in
                                if let ring = FluidPulse.ring(n: n, elapsed: elapsed, depth: motion.params.d) {
                                    FluidOutlineShape(params: motion.params, closed: true)
                                        .stroke(pulseColor, lineWidth: ring.lineWidth)
                                        .opacity(ring.opacity)
                                        .scaleEffect(x: ring.sx, y: ring.sy, anchor: .top)
                                }
                            }
                        }
                    }
                    .allowsHitTesting(false)
                }

                // 07-05 (T-07-01): the HUD level drop and a LINK-LESS meeting drop both stay
                // fully click-through, so both draw here. A linked meeting drop (Join needs
                // clicks) draws in the interactive panel instead (`NotchContentView`, Task 3).
                if hud.isShowingHUD {
                    if let meeting = hud.meeting {
                        if meeting.joinURL == nil {
                            AlertDropView(motion: motion, kind: .meeting(title: meeting.title, lead: meeting.lead, joinURL: nil, onJoin: {}), isPhysical: isPhysical)
                        }
                    } else {
                        AlertDropView(motion: motion, kind: .level(glyph: hud.glyph, level: hud.level), isPhysical: isPhysical)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
            .onChange(of: timer.remaining) { updateTimerLine() }
            .onChange(of: timer.finishedAt) { updateTimerLine() }
            .onChange(of: timer.isRunning) { updateTimerLine() }
            .onChange(of: isBulge) { updateTimerLine() }
            .onAppear { updateTimerLine() }
        }
    }

    /// Ported from index.html:566-567 `P.tprog.to(...)`: toward the live progress (or, once
    /// finished, toward 1) at response 1.1/damping 1, or toward 1 at response 0.5 while ending —
    /// toward 0, same response, whenever the bulge isn't showing a timer at all. The spring itself
    /// (`FluidMotion`'s own clock) does the interpolating; this only ever sets its TARGET.
    private func updateTimerLine() {
        let finished = timer.finishedAt != nil
        let target: CGFloat = showsTimerLine ? (finished ? 1 : CGFloat(timer.progressFraction)) : 0
        motion.setChannel(.timerProgress, to: target, response: finished ? 0.5 : 1.1, damping: 1)
    }
}
