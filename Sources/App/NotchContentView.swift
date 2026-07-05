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

    func hoverBegan() { dwell.hoverBegan() }

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
    let notchSize: CGSize
    let timer: TimerViewModel
    let hud: HUDViewModel

    @State private var flashOpacity: Double = 0

    private var collapsedSize: CGSize { notchSize }

    private var expandedSize: CGSize {
        CGSize(
            width: collapsedSize.width * NotchLayout.expandedWidthMultiplier,
            height: NotchLayout.expandedHeight
        )
    }

    /// Collapsed drawn shape size while the Ambient HUD is showing: same
    /// width (the notch NEVER widens, D-03), taller by `hudBumpHeight` so the
    /// bump grows downward below the camera row, exactly like the open/close
    /// morph already varies the drawn shape height within the constant outer
    /// frame.
    private var collapsedShapeSize: CGSize {
        guard hud.isShowingHUD else { return collapsedSize }
        return CGSize(width: collapsedSize.width, height: collapsedSize.height + NotchLayout.hudBumpHeight)
    }

    /// Bottom rounding for the drawn shape while collapsed. The Ambient HUD
    /// bump uses a smaller radius so its sides stay more vertical and the bump
    /// reads flush with the notch width (the default 14 tapered the bump in,
    /// making it look narrower than the notch); the idle notch keeps 14 to
    /// match the physical camera housing's rounding.
    private var collapsedBottomCornerRadius: CGFloat {
        hud.isShowingHUD ? 8 : 14
    }

    var body: some View {
        let shapeSize = model.isOpen ? expandedSize : collapsedShapeSize
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
        // `NotchShape` inside morphs visually.
        ZStack(alignment: .top) {
            NotchShape(topCornerRadius: 6, bottomCornerRadius: model.isOpen ? 24 : collapsedBottomCornerRadius)
                .fill(Color.black)
                .frame(width: shapeSize.width, height: shapeSize.height)
                .overlay(alignment: .top) {
                    // Collapsed content is a single arbiter (Pitfall 4): the
                    // Ambient HUD bump OR the three-zone timer strip, never
                    // both. The camera row itself is always the same height
                    // (`collapsedSize.height`) regardless of which is
                    // showing; the HUD row is an ADDITIONAL strip below it,
                    // matching the shape's downward-only growth.
                    VStack(spacing: 0) {
                        // Three-zone collapsed strip (DESIGN.md "Collapsed
                        // notch"): left half reserved for Phase 5 Now
                        // Playing (empty for now), the centered camera
                        // housing zone is left deliberately contentless, and
                        // the right half hosts the running timer's readout
                        // — hidden while the HUD is taking over. Never
                        // widens the fixed notch shape — content lives
                        // inside the existing halves.
                        // The camera row itself is deliberately contentless: the
                        // running-timer readout that used to sit in the right
                        // half of this strip drew over the invisible camera
                        // cutout, so it now lives in `EarTimerView` (the visible
                        // ear right of the notch). Left half stays reserved for
                        // Phase 5 Now Playing.
                        Color.clear
                            .frame(height: collapsedSize.height)

                        if hud.isShowingHUD {
                            HUDView(hud: hud)
                                .frame(height: NotchLayout.hudBumpHeight)
                        }
                    }
                    .opacity(model.isOpen ? 0 : 1)
                }

            // A brief neutral/indigo flash on timer completion (D-11) — NEVER
            // amber (that's reserved for the Claude "needs you" attention
            // signal) and never a system notification.
            NotchShape(topCornerRadius: 6, bottomCornerRadius: model.isOpen ? 24 : collapsedBottomCornerRadius)
                .fill(Tokens.Color.accent)
                .frame(width: shapeSize.width, height: shapeSize.height)
                .opacity(flashOpacity)
                .allowsHitTesting(false)

            // Laid out at a CONSTANT expanded size (never `shapeSize`) so its
            // VStack/HStack is always measured at its final geometry and never
            // reflows mid-morph — that reflow was the "wobble" (title +
            // recorder pill visibly sliding into place at a different rate
            // than everything else). The whole panel instead fades in/out as
            // ONE unit and is masked to a shape sized to the currently
            // morphing box (`shapeSize`) so it never paints outside the still
            // growing/shrinking black notch.
            ExpandedPanelView(timer: timer)
                .frame(width: expandedSize.width, height: expandedSize.height, alignment: .topLeading)
                .mask(alignment: .top) {
                    NotchShape(topCornerRadius: 6, bottomCornerRadius: model.isOpen ? 24 : collapsedBottomCornerRadius)
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
