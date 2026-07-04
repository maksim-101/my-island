import SwiftUI
import AppKit
import MyIslandCore

@MainActor
@Observable
final class NotchViewModel {
    private var dwell = HoverDwell()

    var isOpen: Bool {
        if case .open = dwell.state { return true }
        return false
    }

    func hoverBegan() { dwell.hoverBegan() }
    func dwellElapsed() { dwell.dwellElapsed() }
    func hoverEnded() { dwell.hoverEnded() }
    func toggle() { dwell.toggle() }
}

@MainActor
struct NotchContentView: View {
    let model: NotchViewModel

    @State private var hoverTask: Task<Void, Never>?

    private static let dwellDelay: Duration = .seconds(0.25)
    private static let collapseGrace: Duration = .milliseconds(100)
    private static let morph: Animation = .interactiveSpring(response: 0.38, dampingFraction: 0.8)

    private var collapsedSize: CGSize {
        if let notchFrame = NSScreen.main?.notchFrame {
            return CGSize(width: notchFrame.width, height: notchFrame.height)
        }
        return CGSize(width: 200, height: 32)
    }

    private var expandedSize: CGSize {
        CGSize(width: collapsedSize.width * 3.5, height: 200)
    }

    var body: some View {
        let size = model.isOpen ? expandedSize : collapsedSize
        VStack(spacing: 0) {
            NotchShape(topCornerRadius: 6, bottomCornerRadius: model.isOpen ? 24 : 14)
                .fill(Color.black)
                .frame(width: size.width, height: size.height)
                .overlay {
                    if model.isOpen {
                        ExpandedPanelView()
                    } else {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .onHover { handleHover($0) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()
        if hovering {
            model.hoverBegan()
            hoverTask = Task {
                try? await Task.sleep(for: Self.dwellDelay)
                guard !Task.isCancelled else { return }
                withAnimation(Self.morph) {
                    model.dwellElapsed()
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: Self.collapseGrace)
                guard !Task.isCancelled else { return }
                withAnimation(Self.morph) {
                    model.hoverEnded()
                }
            }
        }
    }
}
