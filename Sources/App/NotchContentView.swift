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

    @State private var hoverTask: Task<Void, Never>?

    private static let dwellDelay: Duration = .seconds(0.25)
    private static let collapseGrace: Duration = .milliseconds(100)

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
            NotchShape(topCornerRadius: 6, bottomCornerRadius: model.isOpen ? 24 : 14)
                .fill(Color.black)
                .frame(width: shapeSize.width, height: shapeSize.height)
                .overlay {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                        .opacity(model.isOpen ? 0 : 1)
                }
                .onHover { handleHover($0) }

            // Laid out at a CONSTANT expanded size (never `shapeSize`) so its
            // VStack/HStack is always measured at its final geometry and never
            // reflows mid-morph — that reflow was the "wobble" (title +
            // recorder pill visibly sliding into place at a different rate
            // than everything else). The whole panel instead fades in/out as
            // ONE unit and is masked to a shape sized to the currently
            // morphing box (`shapeSize`) so it never paints outside the still
            // growing/shrinking black notch.
            ExpandedPanelView()
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
    }

    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()
        if hovering {
            model.hoverBegan()
            hoverTask = Task {
                try? await Task.sleep(for: Self.dwellDelay)
                guard !Task.isCancelled else { return }
                withAnimation(NotchLayout.morphAnimation) {
                    model.dwellElapsed()
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: Self.collapseGrace)
                guard !Task.isCancelled else { return }
                withAnimation(NotchLayout.morphAnimation) {
                    model.hoverEnded()
                }
            }
        }
    }
}
