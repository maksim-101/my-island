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

    // DIAGNOSTIC ONLY (plan 04-02 checkpoint round 5/6): correlating hover-state
    // transitions with the Grant Access click-miss theory ("brief flickering,
    // then nothing happens" — the panel may be collapsing right as the click
    // lands). Logs to the round-6 file-based `DebugLog` (round 5 found our
    // own NSLog content was redacted as `<private>` by unified logging) so
    // it can be cross-referenced against `applyFrame` calls in
    // `NotchPanelController` and the click-probe log lines.
    private static func logTransition(_ name: String, wasOpen: Bool, isOpenNow: Bool) {
        DebugLog.write("[NotchViewModel] \(name) wasOpen=\(wasOpen) isOpenNow=\(isOpenNow)")
    }

    func hoverBegan() {
        DebugLog.write("[NotchViewModel] hoverBegan() isOpen=\(isOpen)")
        dwell.hoverBegan()
    }

    func dwellElapsed() {
        let wasOpen = isOpen
        dwell.dwellElapsed()
        Self.logTransition("dwellElapsed()", wasOpen: wasOpen, isOpenNow: isOpen)
        if isOpen != wasOpen { onOpenChange?(isOpen) }
    }

    func hoverEnded() {
        let wasOpen = isOpen
        dwell.hoverEnded()
        Self.logTransition("hoverEnded()", wasOpen: wasOpen, isOpenNow: isOpen)
        if isOpen != wasOpen { onOpenChange?(isOpen) }
    }

    func toggle() {
        let wasOpen = isOpen
        dwell.toggle()
        Self.logTransition("toggle()", wasOpen: wasOpen, isOpenNow: isOpen)
        if isOpen != wasOpen { onOpenChange?(isOpen) }
    }
}

@MainActor
struct NotchContentView: View {
    let model: NotchViewModel
    let notchSize: CGSize
    let timer: TimerViewModel
    let calendar: CalendarProvider

    @State private var flashOpacity: Double = 0

    private var collapsedSize: CGSize { notchSize }

    private var expandedSize: CGSize {
        CGSize(
            width: collapsedSize.width * NotchLayout.expandedWidthMultiplier,
            height: NotchLayout.expandedHeight
        )
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
        // `NotchShape` inside morphs visually.
        ZStack(alignment: .top) {
            // The collapsed notch is just the black shape now — the running
            // timer readout lives in the ear pill (NotchBarView) and the
            // Ambient HUD is a detached glass pill below the notch
            // (HUDPillView), so nothing is drawn over the camera cutout here.
            NotchShape(topCornerRadius: 6, bottomCornerRadius: model.isOpen ? 24 : 14)
                .fill(Color.black)
                .frame(width: shapeSize.width, height: shapeSize.height)

            // A brief neutral/indigo flash on timer completion (D-11) — NEVER
            // amber (that's reserved for the Claude "needs you" attention
            // signal) and never a system notification.
            NotchShape(topCornerRadius: 6, bottomCornerRadius: model.isOpen ? 24 : 14)
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
            ExpandedPanelView(timer: timer, calendar: calendar)
                .frame(width: expandedSize.width, height: expandedSize.height, alignment: .topLeading)
                .mask(alignment: .top) {
                    NotchShape(topCornerRadius: 6, bottomCornerRadius: model.isOpen ? 24 : 14)
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
