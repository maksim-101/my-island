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
        let size = model.isOpen ? expandedSize : collapsedSize
        NotchShape(topCornerRadius: 6, bottomCornerRadius: model.isOpen ? 24 : 14)
            .fill(Color.black)
            .frame(width: size.width, height: size.height)
            .overlay {
                ZStack {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                        .opacity(model.isOpen ? 0 : 1)

                    ExpandedPanelView()
                        .opacity(model.isOpen ? 1 : 0)
                }
                // Content fades in slightly after the box starts growing
                // (delay on expand only), so text never appears before the
                // box exists (DEFECT B). Fades out immediately on collapse,
                // in step with the box shrinking back down.
                .animation(
                    NotchLayout.morphAnimation.delay(model.isOpen ? NotchLayout.expandContentDelay : 0),
                    value: model.isOpen
                )
            }
            .onHover { handleHover($0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
