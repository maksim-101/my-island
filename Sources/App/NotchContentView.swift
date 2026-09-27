import SwiftUI
import AppKit
import MyIslandCore

@MainActor
@Observable
final class NotchViewModel {
    private var dwell = HoverDwell()

    /// Notified synchronously whenever `isOpen` actually changes, regardless
    /// of which caller (hover dwell or the global-hotkey `toggle()`) drove the
    /// change. `NotchPanelController` uses this to keep the AppKit window
    /// frame in sync with the SwiftUI content state.
    var onOpenChange: ((Bool) -> Void)?

    var isOpen: Bool {
        if case .open = dwell.state { return true }
        return false
    }

    func hoverBegan() {
        dwell.hoverBegan()
    }

    func dwellElapsed() {
        let wasOpen = isOpen
        dwell.dwellElapsed()
        if isOpen != wasOpen { onOpenChange?(isOpen) }
    }

    func hoverEnded() {
        let wasOpen = isOpen
        dwell.hoverEnded()
        if isOpen != wasOpen { onOpenChange?(isOpen) }
    }

    func toggle() {
        let wasOpen = isOpen
        dwell.toggle()
        if isOpen != wasOpen { onOpenChange?(isOpen) }
    }
}

@MainActor
struct NotchContentView: View {
    let model: NotchViewModel
    /// D-06 Wave 1 (07-02): the fluid clock driving the collapsed pill's outline — `FluidOutlineShape`
    /// always draws `motion.params` live, never an interpolated/animated snapshot (RESEARCH.md
    /// Pitfall 2). Replaces the old fixed `notchSize: CGSize`.
    let motion: FluidMotion
    let timer: TimerViewModel
    let calendar: CalendarProvider
    let nowPlaying: NowPlayingProvider
    /// Threaded through to `WingItemsView` (07-02 Task 2) for its own music-visible /
    /// fullscreen-suppression gate — the identical `FullscreenObserver`/`displayID` pairing
    /// `NotchPanelController` already reads everywhere else.
    let fullscreen: FullscreenObserver
    let displayID: CGDirectDisplayID?
    /// 07-05 Task 3 (T-07-01): threaded so a LINKED meeting drop (`joinURL != nil`) can draw here,
    /// in the interactive panel, so its Join button can take clicks — the HUD level drop and a
    /// link-less meeting drop stay in `FluidOverlayView`'s always-click-through window instead.
    let hud: HUDViewModel
    // Phase 6 SHELL-06: only the physical camera-cutout gets concave top
    // "ears" (topCornerRadius 6) for the (unchanged, pre-fluid) expanded-panel
    // mask below — a synthetic screen has no housing for those ears to flow
    // into, so its expanded mask has square top corners.
    let isPhysical: Bool

    /// 07-02 Task 3 (D-07, 07-01's `material_decision: option`): read live so switching in
    /// Settings needs no panel rebuild. The MacBook's collapsed pill stays black in every option
    /// (`fillView` below) — this only ever changes a synthetic display's collapsed surface.
    @AppStorage(NotchPanelController.surfaceMaterialKey) private var surfaceMaterial = NotchPanelController.surfaceMaterialDefault

    /// D-06 Wave 1: the collapsed footprint is the fluid outline's own bounding box (`2·half`
    /// wide), plus room for the sticky belly's live pull — mirrors
    /// `NotchPanelController.collapsedSurfaceFrame(for:)`'s window sizing exactly, so the mask
    /// used below never clips the pill mid-nudge.
    private var collapsedSize: CGSize {
        CGSize(width: motion.params.half * 2, height: motion.params.d + motion.params.sag + 6)
    }

    private var expandedSize: CGSize {
        CGSize(width: NotchLayout.expandedWidth, height: NotchLayout.expandedHeight)
    }

    /// 07-04 Task 1 (FLUID-01, agreement §1/§5): whether this display's collapsed surface is
    /// currently the fullscreen bulge — mirrors `NotchPanelController`'s own
    /// `isFullscreenBulge(for:)` gate exactly (a synthetic display whose frontmost window is
    /// fullscreen). Gates `WingItemsView` to empty: the bulge shows no artwork, wave or
    /// clock-face, only the outline timer line `FluidOverlayView` draws.
    private var isBulge: Bool {
        !isPhysical && fullscreen.isFrontmostFullscreen(on: displayID)
    }

    /// D-07 (07-02 Task 3): black everywhere by default, and always on the MacBook regardless of
    /// the Settings choice — glass only ever replaces a SYNTHETIC display's collapsed fill.
    /// `GlassEffectContainer` wraps the single glass surface per 07-01's `glass_container: yes`
    /// finding (required once more than one glass surface can be visible at once; harmless — a
    /// documented no-op — with only one).
    @ViewBuilder
    private var fillView: some View {
        if !isPhysical, surfaceMaterial == "glass" {
            GlassEffectContainer {
                Color.clear
                    .glassEffect(.regular.tint(Color.black.opacity(0.12)), in: FluidOutlineShape(params: motion.params))
            }
        } else {
            FluidOutlineShape(params: motion.params)
                .fill(Color.black)
        }
    }

    var body: some View {
        let shapeSize = model.isOpen ? expandedSize : collapsedSize
        // The OUTER frame is a CONSTANT size (always expandedSize, regardless
        // of isOpen) — this is load-bearing. `NSHostingView` calls
        // `updateAnimatedWindowSize(_:)` whenever its SwiftUI content's
        // reported size CHANGES, and that method resizes the AppKit window
        // itself. `NotchPanelController.applyFrame` is already the sole
        // window-resizer (manual `setFrame`); if the hosting view's content
        // size also changes (as it did when this frame used
        // `maxWidth/maxHeight: .infinity`), the two resize paths fight and
        // the window enters an invalid state, aborting with an uncaught
        // NSException. Keeping the outer frame constant means the hosting
        // view's reported content size never changes, so
        // `updateAnimatedWindowSize` has nothing to animate — only the
        // fluid outline inside morphs visually (driven by `motion`'s own
        // clock, never by this view's animation transaction).
        ZStack(alignment: .top) {
            // D-06 Wave 1 (07-02): the collapsed fill is the fluid pill silhouette — drawn on
            // BOTH displays now (D-01), not gated on `isPhysical` any more (the MacBook and Dell
            // pills are both fluid-family outlines; only their rest `FluidParams` differ). Hidden
            // the instant the panel opens — the expanded band gets its own fluid geometry in
            // plan 08, this view's `mask` below stays the interim rounded-rect approximation.
            if !model.isOpen {
                fillView
                    .frame(width: shapeSize.width, height: shapeSize.height)

                // 07-02 Task 2 (D-02/agreement §2): the 16pt wing items, drawn over the fill in
                // the SAME frame so their own local center lines up with the pill's `cx`. Empty
                // while the fullscreen bulge is showing (07-04 Task 1) — only the outline timer
                // line and, from plan 05, the meeting alert, ever draw on the bulge.
                WingItemsView(timer: timer, nowPlaying: nowPlaying, fullscreen: fullscreen, displayID: displayID, isPhysical: isPhysical, isOpen: model.isOpen, isBulge: isBulge)
                    .frame(width: shapeSize.width, height: shapeSize.height)

                // 07-05 Task 3 (T-07-01): only a LINKED meeting drop ever lands here — the HUD and
                // a link-less meeting drop always draw in `FluidOverlayView`'s click-through
                // window instead (see that view's own gate).
                if let meeting = hud.meeting, let joinURL = meeting.joinURL {
                    AlertDropView(motion: motion, kind: .meeting(title: meeting.title, lead: meeting.lead, joinURL: joinURL, onJoin: { hud.endSoon() }), isPhysical: isPhysical)
                        .frame(width: shapeSize.width, height: shapeSize.height)
                }
            }

            // Laid out at a CONSTANT expanded size (never `shapeSize`) so its
            // VStack/HStack is always measured at its final geometry and never
            // reflows mid-morph — that reflow was the "wobble" (title +
            // recorder pill visibly sliding into place at a different rate
            // than everything else). The whole panel instead fades in/out as
            // ONE unit and is masked to a shape sized to the currently
            // morphing box (`shapeSize`) so it never paints outside the still
            // growing/shrinking black notch.
            ExpandedPanelView(timer: timer, calendar: calendar, nowPlaying: nowPlaying)
                .frame(width: expandedSize.width, height: expandedSize.height, alignment: .topLeading)
                .mask(alignment: .top) {
                    NotchShape(topCornerRadius: isPhysical ? 6 : 0, bottomCornerRadius: model.isOpen ? 24 : 14)
                        .frame(width: shapeSize.width, height: shapeSize.height)
                }
                .opacity(model.isOpen ? 1 : 0)
                // Collapsed content still occupies the full expanded footprint
                // (to stay constant-sized), so hit-testing must be disabled
                // while closed or it would swallow hover over the invisible
                // area beyond the collapsed notch.
                .allowsHitTesting(model.isOpen)
                // Content trails the box growth slightly on expand (so text
                // never appears before the box exists), and fades out in step
                // with the box shrinking back down on collapse.
                .animation(
                    NotchLayout.morphAnimation.delay(model.isOpen ? NotchLayout.expandContentDelay : 0),
                    value: model.isOpen
                )
        }
        .frame(width: expandedSize.width, height: expandedSize.height, alignment: .top)
        // Hover is intentionally NOT detected here via SwiftUI `.onHover`.
        // `NotchPanelController`'s `HoverTrackingView` (an AppKit
        // `NSTrackingArea` on the window's container view) drives
        // `model.hoverBegan()`/`dwellElapsed()`/`hoverEnded()` instead — the
        // recorder inside `ExpandedPanelView` does not reliably honor
        // `.allowsHitTesting(false)` for its own hit-testing, which silently
        // swallowed `.onHover` over the left half of the collapsed notch
        // (SHELL-11).
    }
}
