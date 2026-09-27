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
    /// 07-08 (PANEL-02 prerequisite): the SAME `ClipboardViewModel` instance
    /// `NotchPanelController` now owns once — replaces `ExpandedPanelView`'s retired local
    /// `@State private var clipboard`, so history survives every panel rebuild.
    let clipboard: ClipboardViewModel
    // Phase 6 SHELL-06: only the physical camera-cutout gets concave top
    // "ears" for the (retired) pre-fluid expanded-panel mask — kept as a field for the band's own
    // content-top choice below (the physical notch's band content starts lower than a synthetic
    // display's, `FluidShapeGeometry.bandContentTopPhysical`/`bandContentTopSynthetic`).
    let isPhysical: Bool

    /// 07-02 Task 3 (D-07, 07-01's `material_decision: option`): read live so switching in
    /// Settings needs no panel rebuild. The MacBook's collapsed pill stays black in every option
    /// (`fillView` below) — this only ever changes a synthetic display's collapsed surface.
    @AppStorage(NotchPanelController.surfaceMaterialKey) private var surfaceMaterial = NotchPanelController.surfaceMaterialDefault

    /// 07-08 (D-06 Wave 2): the band's own content-top — physical clears the measured 32pt camera
    /// housing/33pt menu bar (07-15 gap closure re-confirmed this against the hardware numbers,
    /// not the sketch's stale 37pt assumption); synthetic sits right under the menu bar.
    private var contentTop: CGFloat {
        isPhysical ? FluidShapeGeometry.bandContentTopPhysical : FluidShapeGeometry.bandContentTopSynthetic
    }

    /// Interim until plan 14 (`NotchPanelController.modulesAwaitingDataSource`): the band's own
    /// enabled-module list. Plan 11 will switch this to the persisted Settings list; today it is
    /// always every module minus the ones still awaiting their data source.
    private var enabledModules: [BandModule] {
        NotchPanelController.bandModules(from: BandModule.allCases)
    }

    /// The band's own outline parameters for the CURRENT enabled-module count — the single source
    /// both this view's constant hosting frame (`openSize`) and `NotchPanelController.openFrame`
    /// read, so window sizing and content layout can never disagree about how wide/deep the open
    /// band is.
    private var bandLayout: BandLayout {
        BandLayout(moduleCount: enabledModules.count, contentTop: contentTop, cx: openSize.width / 2)
    }

    /// D-06 Wave 1: the collapsed footprint is the fluid outline's own bounding box (`2·half`
    /// wide), plus room for the sticky belly's live pull — mirrors
    /// `NotchPanelController.collapsedSurfaceFrame(for:)`'s window sizing exactly, so the mask
    /// used below never clips the pill mid-nudge. No longer read for the outer hosting frame
    /// (`openSize` below is now constant regardless of `model.isOpen` — see that property's own
    /// comment) but still the true collapsed-rest bounding box other call sites may want.
    private var collapsedSize: CGSize {
        CGSize(width: motion.params.half * 2, height: motion.params.d + motion.params.sag + 6)
    }

    /// 07-08 (D-06 Wave 2): the CONSTANT hosting frame — the band's own bounding box plus droplet
    /// room, `NotchPanelController.openFrameSize`'s single source. Load-bearing for the SAME reason
    /// the old fixed `expandedSize` was (see `NotchPanelController.makePanel`'s hosting-view
    /// comment): `NSHostingView.updateAnimatedWindowSize(_:)` fires whenever this view's reported
    /// SwiftUI content size changes, and `NotchPanelController.applyFrame` is already the sole
    /// window-resizer — a constant frame here means the two resize paths never fight. The single
    /// `FluidOutlineShape(params: motion.params)` fill below draws whatever the LIVE, animating
    /// outline currently is (collapsed pill through the open band) inside this fixed canvas; the
    /// canvas size itself never needs to track `model.isOpen`.
    private var openSize: CGSize {
        NotchPanelController.openFrameSize(moduleCount: enabledModules.count, contentTop: contentTop)
    }

    /// Ported from index.html:701 `const fade = st.open ? Math.max(0, 1 - P.bandA.x * 3) : 1` —
    /// collapsed to one formula since `bandAlpha` already rests at 0 while closed, so the `else`
    /// branch is redundant. `WingItemsView`'s own `isOpen` gate below is deliberately passed
    /// `false` (never mutated by this view's Boolean `model.isOpen`): that gate gives a binary
    /// opacity cut at the instant `isOpen` flips, which would pop the wings out a full pour cycle
    /// before `bandAlpha` itself has risen — this continuous multiplier is what the sketch's own
    /// fade actually specifies, and it already reaches 0 well before `bandAlpha` finishes rising
    /// (at `bandAlpha` ≈ 0.33), so the wings are fully gone long before the band settles either way.
    private var wingFade: CGFloat {
        max(0, 1 - (motion.channels[.bandAlpha] ?? 0) * 3)
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
        // ONE surface for both states (D-06 Wave 2): the outer frame is a CONSTANT `openSize`
        // (never switches on `model.isOpen`) for the identical `NSHostingView.updateAnimatedWindowSize`
        // reason the old fixed `expandedSize` frame carried — see `openSize`'s own comment.
        // `FluidOutlineShape(params: motion.params)` draws whatever the LIVE, animating outline
        // currently is — collapsed pill through the fully open band — inside this fixed canvas.
        ZStack(alignment: .top) {
            fillView
                .frame(width: openSize.width, height: openSize.height)

            // 07-02 Task 2 (D-02/agreement §2): the 16pt wing items — now ALWAYS rendered (no
            // longer gated on `!model.isOpen`) so they can fade continuously via `wingFade` instead
            // of popping out the instant the band starts pouring. `isOpen: false` here is
            // deliberate — see `wingFade`'s own doc comment for why the internal binary gate is
            // routed around rather than driven from `model.isOpen`.
            WingItemsView(timer: timer, nowPlaying: nowPlaying, fullscreen: fullscreen, displayID: displayID, isPhysical: isPhysical, isOpen: false, isBulge: isBulge)
                .frame(width: openSize.width, height: openSize.height)
                .opacity(wingFade)

            // 07-05 Task 3 (T-07-01): only a LINKED meeting drop ever lands here, and only while
            // collapsed — `NotchPanelController.onOpenChange` already calls `hud.dismissNow()` the
            // instant the band starts opening (sketch's own `openBand`), so this never needs to
            // coexist with the band's own content.
            if !model.isOpen, let meeting = hud.meeting, let joinURL = meeting.joinURL {
                AlertDropView(motion: motion, kind: .meeting(title: meeting.title, lead: meeting.lead, joinURL: joinURL, onJoin: { hud.endSoon() }), isPhysical: isPhysical)
                    .frame(width: openSize.width, height: openSize.height)
            }

            // D-06 Wave 2 (PANEL-04): the band's row of module summaries — present at all times,
            // pure `bandAlpha` opacity (0 while collapsed, since that channel rests at 0) rather
            // than an `if model.isOpen` add/remove, so it fades in step with the pour/drain
            // exactly like the wings above. Hit-testing gated on the discrete `model.isOpen`
            // (never partially interactive mid-morph).
            BandView(
                modules: enabledModules,
                layout: bandLayout,
                hotIndex: nil,
                pinnedIndex: nil,
                timer: timer,
                nowPlaying: nowPlaying,
                calendar: calendar,
                clipboard: clipboard,
                onTapCell: { _ in }
            )
            .frame(width: bandLayout.cellsWidth, height: 50)
            .position(x: bandLayout.cellsX + bandLayout.cellsWidth / 2, y: contentTop - 6 * (1 - bandAlpha) + 25)
            .opacity(bandAlpha)
            .allowsHitTesting(model.isOpen)
        }
        .frame(width: openSize.width, height: openSize.height, alignment: .top)
        // Hover is intentionally NOT detected here via SwiftUI `.onHover`.
        // `NotchPanelController`'s `HoverTrackingView` (an AppKit
        // `NSTrackingArea` on the window's container view) drives
        // `model.hoverBegan()`/`dwellElapsed()`/`hoverEnded()` instead — SwiftUI's own hover
        // detection has repeatedly proven unreliable inside this app's non-activating `NSPanel`
        // (SHELL-11).
    }

    /// `motion.channels[.bandAlpha]` clamped non-negative — the band's own pour/drain opacity,
    /// read live off the spring clock every tick (RESEARCH.md Pitfall 2: never SwiftUI-animated).
    private var bandAlpha: CGFloat {
        max(0, motion.channels[.bandAlpha] ?? 0)
    }
}
