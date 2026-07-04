import AppKit
import SwiftUI
import OSLog
import MyIslandCore

@MainActor
final class NotchPanelController: NSObject {
    private var panels: [NotchPanel] = []
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "NotchPanelController")

    override init() {
        super.init()

        for screen in NSScreen.screens {
            guard let notchFrame = screen.notchFrame else {
                logger.info("No notch on this screen — dormant, no panel created (SHELL-05/D-11)")
                continue
            }

            let model = NotchViewModel()
            let panel = Self.makePanel(notchFrame: notchFrame, screen: screen, model: model)
            panels.append(panel)
            panel.orderFrontRegardless()
        }

        logger.info("Initialized with \(self.panels.count, privacy: .public) notch panel(s)")
    }

    private static func makePanel(notchFrame: NSRect, screen: NSScreen, model: NotchViewModel) -> NotchPanel {
        let width = notchFrame.width * NotchLayout.expandedWidthMultiplier
        let height = NotchLayout.expandedHeight
        let contentRect = NSRect(x: 0, y: 0, width: width, height: height)
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .utilityWindow]

        let panel = NotchPanel(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
        panel.viewModel = model

        let hostingView = PassthroughHostingView(rootView: NotchContentView(model: model, notchSize: notchFrame.size))
        hostingView.interactiveFrame = { [weak hostingView, weak model] in
            guard let hostingView, let model else { return .zero }
            let bounds = hostingView.bounds
            guard !model.isOpen else { return bounds }
            return CGRect(
                x: (bounds.width - notchFrame.width) / 2,
                y: 0,
                width: notchFrame.width,
                height: notchFrame.height
            )
        }
        panel.contentView = hostingView

        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false

        panel.setFrameOrigin(NSPoint(
            x: notchFrame.midX - panel.frame.width / 2,
            y: screen.frame.maxY - panel.frame.height
        ))

        return panel
    }

    func toggle() {
        withAnimation(NotchLayout.morphAnimation) {
            for panel in panels {
                panel.viewModel?.toggle()
            }
        }
    }
}

/// Each screen's panel owns its own `NotchViewModel` (IN-02) — hovering or
/// toggling one screen's notch must not open/close another screen's.
private final class NotchPanel: NSPanel {
    weak var viewModel: NotchViewModel?

    // Becomes key only while expanded, so KeyboardShortcuts.Recorder can
    // capture a keystroke (CR-02); flips back to false once collapsed so the
    // ambient/non-activating hover behavior is preserved (no focus theft).
    override var canBecomeKey: Bool { viewModel?.isOpen ?? false }
    override var canBecomeMain: Bool { viewModel?.isOpen ?? false }
}

/// Restricts hit-testing to the currently rendered notch shape (CR-01) so
/// the panel — which is always sized at its expanded dimensions — does not
/// swallow clicks meant for the menu bar or desktop underneath while
/// collapsed. `NSTrackingArea`-based hover detection is unaffected, since
/// tracking areas fire independently of the hit-test chain.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var interactiveFrame: () -> CGRect = { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard interactiveFrame().contains(point) else { return nil }
        return super.hitTest(point)
    }
}
