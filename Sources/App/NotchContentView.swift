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
    // Phase 6 SHELL-06: only the physical camera-cutout gets concave top
    // "ears" (topCornerRadius 6) for the (unchanged, pre-fluid) expanded-panel
    // mask below — a synthetic screen has no housing for those ears to flow
    // into, so its expanded mask has square top corners.
    let isPhysical: Bool

    @State private var flashOpacity: Double = 0

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
                FluidOutlineShape(params: motion.params)
                    .fill(Color.black)
                    .frame(width: shapeSize.width, height: shapeSize.height)

                // A brief neutral/indigo flash on timer completion (D-11) — NEVER
                // amber (that's reserved for the Claude "needs you" attention
                // signal) and never a system notification.
                FluidOutlineShape(params: motion.params)
                    .fill(Tokens.Color.accent)
                    .frame(width: shapeSize.width, height: shapeSize.height)
                    .opacity(flashOpacity)
                    .allowsHitTesting(false)
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
        .onChange(of: timer.flashPulse) {
            flashOpacity = 1
            withAnimation(.easeOut(duration: 0.5)) {
                flashOpacity = 0
            }
        }
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
